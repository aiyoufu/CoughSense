import { hilog } from '@kit.PerformanceAnalysisKit';
import { AcousticEvent, AcousticEventType, AudioQualityFlag } from '../detection/DetectionTypes';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Human]';

interface FrameFeature {
  startSample: number;
  rms: number;
  zcr: number;
  lowRatio: number;
  midRatio: number;
  highRatio: number;
  centroid: number;
  flatness: number;
  periodicity: number;
  flux: number;
  clippedRatio: number;
}

export interface DetectorDecision {
  event: AcousticEvent | null;
  reason: string;
}

const SAMPLE_RATE = 16000;
const FRAME_SIZE = 320;
const FFT_SIZE = 512;
// 收尾确认 3 帧（60ms）：事件结束后要等信号落回门限以下才判类，这是计数延迟的固定部分；
// 5 帧（100ms）在混响/尾音长的房间里容易把事件拖长甚至顶到 55 帧上限。单次咳嗽内的
// 双峰间隙由 200ms 冷却兜底（间隙落在冷却内不会重复计数），所以 3 帧不会导致拆分误计。
const END_HANG_FRAMES = 3;
const MAX_EVENT_FRAMES = 55;
const MIN_TRIGGER_RMS = 0.010; // ≈ -40 dBFS，避免环境底噪当咳嗽
const FLOOR_REL_THR = 4.0; // ≈ +12 dB over floor
const PRE_QUIET_FRAMES = 3;
const PRE_QUIET_RATIO = 0.50;
const BUSY_TAU_MS = 2000;
const BUSY_LIMIT = 0.28;
const FRAME_MS = 20;
const COOLDOWN_SAMPLES = 3200; // 200ms after hang, 不吞掉连发清嗓
const WARMUP_SAMPLES = 24000; // 1.5s 底噪学习，不计次
const INV16 = 1 / 32768;
const VERSION = 'human-acoustic-v7';

/**
 * v7：修秒级计数延迟。v6 拉到 55 帧上限的事件（混响尾音/说话）按 TOO_LONG 丢弃时
 * 把 busy 置满，忙碌比 1.0 按 2s 时间常数衰减到 0.28 以下需要约 2.5s——这期间的
 * 真咳嗽/清嗓全按 SKIP_BUSY 吞掉，体感就是“咳完几秒才记上”（阵发连咳吃亏最大）。
 * 改为只加 0.35 个时间常数的温和抑制（约 0.45s），持续说话会靠后续响帧自然补满 busy，
 * 不影响说话抑制；单次长尾误伤只盲约 0.45s。另收尾确认 5 帧→3 帧，每事件省约 40ms。
 * v6：v5 在平稳底噪（风扇/空调/临街，RMS 与触发阈值相当）下 floor 被冻住，
 * hang 门限长期低于底噪，事件拉到 55 帧按 TOO_LONG 丢弃并置满 busy——
 * 表现为咳嗽/清嗓完全没反应。v6 增加大声侧慢跟随（约 8s），并把清嗓
 * zcr 上限 0.10 放宽到 0.13（底噪 hiss 会抬升 zcr）。
 * v5：v4 默认判咳嗽 + 触发过低，导致无事件时咳嗽计数狂涨、清嗓被记成咳嗽、真咳嗽被忙碌门吞掉。
 * 唤醒抬到约 -40 dBFS；只用频谱轮廓定类；对不上咳嗽/清嗓轮廓的事件直接丢弃。
 */
export class HumanSoundDetector {
  private leftover: Int16Array = new Int16Array(FRAME_SIZE);
  private leftoverLen: number = 0;
  private floorRms: number = 0.001;
  private previousBands: Float64Array = new Float64Array(3);
  private activeFrames: Array<FrameFeature> = [];
  private belowFrames: number = 0;
  private active: boolean = false;
  private idleRms: Float64Array = new Float64Array(PRE_QUIET_FRAMES);
  private idlePos: number = 0;
  private busyMs: number = 0;
  private lastSkipLogSample: number = -1;
  private cooldownUntil: number = 0;
  private firstSample: number = -1;
  private workRe: Float64Array = new Float64Array(FFT_SIZE);
  private workIm: Float64Array = new Float64Array(FFT_SIZE);
  private hann: Float64Array = new Float64Array(FRAME_SIZE);
  private fftReverse: Uint32Array = new Uint32Array(FFT_SIZE);
  private fftCos: Float64Array = new Float64Array(FFT_SIZE / 2);
  private fftSin: Float64Array = new Float64Array(FFT_SIZE / 2);

  constructor() {
    const bits = Math.round(Math.log2(FFT_SIZE));
    for (let i = 0; i < FFT_SIZE; i++) {
      let x = i;
      let r = 0;
      for (let bit = 0; bit < bits; bit++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      this.fftReverse[i] = r;
    }
    for (let i = 0; i < FFT_SIZE / 2; i++) {
      const angle = -2 * Math.PI * i / FFT_SIZE;
      this.fftCos[i] = Math.cos(angle);
      this.fftSin[i] = Math.sin(angle);
    }
    for (let i = 0; i < FRAME_SIZE; i++) {
      this.hann[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (FRAME_SIZE - 1));
    }
  }

  reset(): void {
    this.leftoverLen = 0;
    this.floorRms = 0.001;
    this.previousBands = new Float64Array(3);
    this.activeFrames = [];
    this.belowFrames = 0;
    this.active = false;
    this.idleRms = new Float64Array(PRE_QUIET_FRAMES);
    this.idlePos = 0;
    this.busyMs = 0;
    this.lastSkipLogSample = -1;
    this.cooldownUntil = 0;
    this.firstSample = -1;
  }

  push(buffer: ArrayBuffer, startSample: number): Array<DetectorDecision> {
    const input = new Int16Array(buffer);
    if (input.length === 0) {
      return [];
    }
    const out: Array<DetectorDecision> = [];
    let abs = startSample - this.leftoverLen;
    let off = 0;
    if (this.leftoverLen > 0) {
      const need = FRAME_SIZE - this.leftoverLen;
      const take = input.length < need ? input.length : need;
      for (let i = 0; i < take; i++) {
        this.leftover[this.leftoverLen + i] = input[i];
      }
      this.leftoverLen += take;
      off = take;
      if (this.leftoverLen < FRAME_SIZE) {
        return out;
      }
      const decision = this.consumeFrame(this.leftover, 0, abs);
      if (decision !== null) {
        out.push(decision);
      }
      abs += FRAME_SIZE;
      this.leftoverLen = 0;
    }
    while (off + FRAME_SIZE <= input.length) {
      const decision = this.consumeFrame(input, off, abs);
      if (decision !== null) {
        out.push(decision);
      }
      off += FRAME_SIZE;
      abs += FRAME_SIZE;
    }
    this.leftoverLen = input.length - off;
    for (let i = 0; i < this.leftoverLen; i++) {
      this.leftover[i] = input[off + i];
    }
    return out;
  }

  private threshold(): number {
    return Math.max(MIN_TRIGGER_RMS, this.floorRms * FLOOR_REL_THR);
  }

  private preMean(): number {
    let sum = 0;
    for (let i = 0; i < this.idleRms.length; i++) {
      sum += this.idleRms[i];
    }
    return sum / this.idleRms.length;
  }

  private rmsAt(src: Int16Array, offset: number): number {
    let sum = 0;
    const end = offset + FRAME_SIZE;
    for (let i = offset; i < end; i++) {
      const v = src[i] * INV16;
      sum += v * v;
    }
    return Math.sqrt(sum / FRAME_SIZE);
  }

  private consumeFrame(src: Int16Array, offset: number, startSample: number): DetectorDecision | null {
    const rms = this.rmsAt(src, offset);
    if (!this.active) {
      if (!this.wakeFromIdle(rms, startSample)) {
        return null;
      }
      const feature = this.analyzeFrame(src, offset, startSample);
      this.active = true;
      this.activeFrames = [feature];
      this.belowFrames = 0;
      return null;
    }
    const feature = this.analyzeFrame(src, offset, startSample);
    return this.processActive(feature);
  }

  private wakeFromIdle(rms: number, startSample: number): boolean {
    if (this.firstSample < 0) {
      this.firstSample = startSample;
    }
    const warming = startSample - this.firstSample < WARMUP_SAMPLES;
    const thr = this.threshold();
    if (rms < thr) {
      const quiet = rms < this.floorRms * 2.2;
      const alpha = quiet ? 0.04 : 0.002;
      this.floorRms = this.floorRms * (1 - alpha) + rms * alpha;
    } else {
      // 大声侧也要慢速跟随（约 8 秒时间常数）：风扇/空调/临街等平稳底噪
      // 一旦超过阈值，floor 会被永远冻住，hang 门限（thr*0.72）长期低于底噪，
      // 事件等不到 5 个 hang 帧、被迫拉到 55 帧按 TOO_LONG 丢弃，
      // 还顺手置满 busy 让后续全盲——表现为"咳嗽/清嗓完全没反应"。
      // 单次咳嗽/清嗓不足 1 秒，慢跟随几乎不受影响。
      const alphaSlow = 1 - Math.exp(-FRAME_MS / 8000);
      this.floorRms = this.floorRms * (1 - alphaSlow) + rms * alphaSlow;
    }
    const decay = Math.exp(-FRAME_MS / BUSY_TAU_MS);
    const loud = rms > this.floorRms * 3.0;
    if (!warming) {
      this.busyMs = this.busyMs * decay + (loud ? FRAME_MS : 0);
    }
    const busyRatio = this.busyMs / BUSY_TAU_MS;
    if (rms < thr || warming || startSample < this.cooldownUntil) {
      this.idleRms[this.idlePos] = rms;
      this.idlePos = (this.idlePos + 1) % PRE_QUIET_FRAMES;
      return false;
    }
    const preQuiet = this.preMean() <= thr * PRE_QUIET_RATIO;
    if (busyRatio > BUSY_LIMIT) {
      this.logSkip(startSample, 'SKIP_BUSY', String(Math.round(busyRatio * 100) / 100));
      this.idleRms[this.idlePos] = rms;
      this.idlePos = (this.idlePos + 1) % PRE_QUIET_FRAMES;
      return false;
    }
    if (!preQuiet) {
      this.logSkip(startSample, 'SKIP_ONSET', String(Math.round(this.preMean() * 10000) / 10000));
      this.idleRms[this.idlePos] = rms;
      this.idlePos = (this.idlePos + 1) % PRE_QUIET_FRAMES;
      return false;
    }
    return true;
  }

  private processActive(frame: FrameFeature): DetectorDecision | null {
    this.activeFrames.push(frame);
    const thr = this.threshold();
    if (frame.rms < thr * 0.72) {
      this.belowFrames++;
    } else {
      this.belowFrames = 0;
    }
    if (this.belowFrames < END_HANG_FRAMES && this.activeFrames.length < MAX_EVENT_FRAMES) {
      return null;
    }
    const hitMax = this.activeFrames.length >= MAX_EVENT_FRAMES;
    const lastRms = this.activeFrames[this.activeFrames.length - 1].rms;
    for (let i = 0; i < PRE_QUIET_FRAMES; i++) {
      this.idleRms[i] = lastRms;
    }
    if (hitMax) {
      // 温和抑制约 0.45s（2s*ln(0.35/0.28)）：原来置满要盲约 2.5s，真事件全被吞；
      // 持续说话的响帧会在 idle 里快速把 busy 补回去，抑制效果不受影响
      this.busyMs = BUSY_TAU_MS * 0.35;
    }
    const trim = this.belowFrames >= END_HANG_FRAMES ? END_HANG_FRAMES - 1 : 0;
    const count = Math.max(1, this.activeFrames.length - trim);
    const eventFrames = this.activeFrames.slice(0, count);
    const lastStart = this.activeFrames[this.activeFrames.length - 1].startSample;
    this.cooldownUntil = lastStart + COOLDOWN_SAMPLES;
    this.active = false;
    this.activeFrames = [];
    this.belowFrames = 0;
    return this.classify(eventFrames);
  }

  private classify(frames: Array<FrameFeature>): DetectorDecision {
    const durationMs = frames.length * FRAME_MS;
    let peak = 0;
    let peakIndex = 0;
    let mean = 0;
    let zcr = 0;
    let low = 0;
    let mid = 0;
    let high = 0;
    let centroid = 0;
    let flatness = 0;
    let periodicity = 0;
    let flux = 0;
    let clipped = 0;
    let voicedFrames = 0;
    for (let i = 0; i < frames.length; i++) {
      const f = frames[i];
      mean += f.rms;
      zcr += f.zcr;
      low += f.lowRatio;
      mid += f.midRatio;
      high += f.highRatio;
      centroid += f.centroid;
      flatness += f.flatness;
      periodicity += f.periodicity;
      flux += f.flux;
      clipped += f.clippedRatio;
      if (f.zcr <= 0.045 && f.lowRatio >= 0.20) {
        voicedFrames++;
      }
      if (f.rms > peak) {
        peak = f.rms;
        peakIndex = i;
      }
    }
    const n = frames.length;
    mean /= n;
    zcr /= n;
    low /= n;
    mid /= n;
    high /= n;
    centroid /= n;
    flatness /= n;
    periodicity /= n;
    flux /= n;
    clipped /= n;
    const voicedFraction = voicedFrames / n;
    const snrDb = 20 * Math.log10(Math.max(peak, 1e-9) / Math.max(this.floorRms, 1e-9));
    const crest = peak / Math.max(mean, 1e-9);
    const firstThird = this.meanRms(frames, 0, Math.max(1, Math.floor(n / 3)));
    const lastThird = this.meanRms(frames, Math.max(0, Math.floor(n * 2 / 3)), n);
    const decay = firstThird / Math.max(lastThird, 1e-9);
    const spectralChange = this.spectralChange(frames);
    const lowMid = low + mid;

    let flags = AudioQualityFlag.NONE;
    if (clipped > 0.02) flags |= AudioQualityFlag.CLIPPED;
    if (snrDb < 10) flags |= AudioQualityFlag.LOW_SNR;
    if (durationMs < 80) flags |= AudioQualityFlag.TOO_SHORT;
    if (durationMs > 1000) flags |= AudioQualityFlag.TOO_LONG;
    if (flatness < 0.04 && zcr < 0.035 && high < 0.14) flags |= AudioQualityFlag.TONAL;
    if (crest > 5.8 ||
      (durationMs <= 110 && peakIndex <= 1 && decay > 2.8 && (crest > 2.3 || zcr > 0.14))) {
      flags |= AudioQualityFlag.IMPACT;
    }
    const stableVoiced = voicedFraction > 0.75 && flux < 0.055 &&
      spectralChange < 0.07 && crest < 1.32 && decay < 1.25;
    if ((durationMs >= 780 && voicedFraction > 0.86 && flux < 0.08 &&
      flatness < 0.10 && spectralChange < 0.06) ||
      (durationMs >= 280 && stableVoiced)) {
      flags |= AudioQualityFlag.SPEECH_LIKE;
    }
    const hardQualityFlags = AudioQualityFlag.CLIPPED | AudioQualityFlag.LOW_SNR |
      AudioQualityFlag.TOO_SHORT | AudioQualityFlag.TOO_LONG | AudioQualityFlag.TONAL |
      AudioQualityFlag.IMPACT | AudioQualityFlag.SPEECH_LIKE;
    if ((flags & hardQualityFlags) !== 0) {
      const reason = this.flagReason(flags);
      hilog.info(DOMAIN, TAG,
        'REJECT %{public}s dur=%{public}d snr=%{public}s crest=%{public}s cen=%{public}d',
        reason, durationMs, String(Math.round(snrDb * 10) / 10),
        String(Math.round(crest * 100) / 100), Math.round(centroid));
      return { event: null, reason: reason };
    }

    // 不用“过阈值后的起音时间”定类：阈值往往卡在峰值，riseMs 会把清嗓也看成咳嗽。
    const broadband = high >= 0.07 && zcr >= 0.028 && centroid >= 700 && centroid <= 4800;
    const noisyBurst = flatness >= 0.11 && zcr >= 0.04 && voicedFraction < 0.30 &&
      centroid >= 600 && centroid <= 5000 && high >= 0.05 && decay >= 1.12;
    const coughMatch = durationMs >= 90 && durationMs <= 720 && crest >= 1.12 && crest <= 4.8 &&
      low <= 0.58 && (broadband || noisyBurst);

    const throatMatch = durationMs >= 120 && durationMs <= 900 &&
      centroid >= 120 && centroid <= 1250 && high <= 0.20 && lowMid >= 0.60 &&
      // zcr 上限 0.13：底噪 hiss 会把清嗓事件 zcr 从约 0.08 抬到 0.10 以上，
      // 0.10 一刀切会把稍远/稍吵环境下的真清嗓判 no-match；
      // 敲击类仍由 centroid/lowMid/high 三重门拦截
      zcr >= 0.008 && zcr <= 0.13 && crest >= 1.05 && crest <= 3.8 &&
      (voicedFraction >= 0.12 || low >= 0.22 || (centroid <= 900 && high <= 0.10));

    let haveType = false;
    let bestType: AcousticEventType = 'cough';
    let best = 0;
    let second = 0;
    if (coughMatch && !throatMatch) {
      haveType = true;
      bestType = 'cough';
      best = broadband ? 0.86 : 0.72;
      second = 0.20;
    } else if (throatMatch && !coughMatch) {
      haveType = true;
      bestType = 'throat_clear';
      best = 0.84;
      second = 0.20;
    } else if (coughMatch && throatMatch) {
      if (centroid <= 1100 && high <= 0.14 && (voicedFraction >= 0.15 || low >= 0.28)) {
        haveType = true;
        bestType = 'throat_clear';
        best = 0.78;
        second = 0.40;
      } else if (high >= 0.10 && zcr >= 0.035 && voicedFraction < 0.35) {
        haveType = true;
        bestType = 'cough';
        best = 0.78;
        second = 0.40;
      }
    }
    if (!haveType) {
      hilog.info(DOMAIN, TAG,
        'REJECT no-match dur=%{public}d high=%{public}s zcr=%{public}s cen=%{public}d voiced=%{public}s',
        durationMs, String(this.fmt(high)), String(this.fmt(zcr)),
        Math.round(centroid), String(this.fmt(voicedFraction)));
      return { event: null, reason: 'no-match' };
    }

    const startSample = frames[0].startSample;
    const endSample = frames[frames.length - 1].startSample + FRAME_SIZE;
    const peakDb = 20 * Math.log10(Math.max(peak, 1e-9));
    const event: AcousticEvent = {
      type: bestType,
      startSample: startSample,
      endSample: endSample,
      durationMs: Math.round((endSample - startSample) * 1000 / SAMPLE_RATE),
      peakDb: Math.round(peakDb * 10) / 10,
      classConfidence: Math.min(0.99, Math.round(best * 1000) / 1000),
      targetConfidence: Math.min(0.99, Math.round((best + (1 - second)) * 500) / 1000),
      qualityFlags: flags,
      algorithmVersion: VERSION
    };
    hilog.info(DOMAIN, TAG,
      'ACCEPT %{public}s dur=%{public}d high=%{public}s zcr=%{public}s cen=%{public}d snr=%{public}s',
      bestType, event.durationMs, String(this.fmt(high)), String(this.fmt(zcr)),
      Math.round(centroid), String(Math.round(snrDb * 10) / 10));
    return { event: event, reason: bestType };
  }

  private fmt(v: number): number {
    return Math.round(v * 1000) / 1000;
  }

  private analyzeFrame(src: Int16Array, offset: number, startSample: number): FrameFeature {
    let sum = 0;
    let crossings = 0;
    let clipped = 0;
    let previous = src[offset];
    const end = offset + FRAME_SIZE;
    for (let i = offset; i < end; i++) {
      const sample = src[i];
      const value = sample * INV16;
      sum += value * value;
      if (sample >= 32600 || sample <= -32600) clipped++;
      if (i > offset && ((previous >= 0 && sample < 0) || (previous < 0 && sample >= 0))) {
        crossings++;
      }
      previous = sample;
    }
    const rms = Math.sqrt(sum / FRAME_SIZE);
    const re = this.workRe;
    const im = this.workIm;
    for (let i = 0; i < FFT_SIZE; i++) {
      im[i] = 0;
      re[i] = i < FRAME_SIZE ? src[offset + i] * INV16 * this.hann[i] : 0;
    }
    this.fft(re, im);
    let total = 0;
    let low = 0;
    let mid = 0;
    let high = 0;
    let weighted = 0;
    let logSum = 0;
    let bins = 0;
    for (let k = 2; k < FFT_SIZE / 2; k += 2) {
      const energy = re[k] * re[k] + im[k] * im[k] + 1e-12;
      const hz = k * SAMPLE_RATE / FFT_SIZE;
      total += energy;
      weighted += energy * hz;
      logSum += Math.log(energy);
      bins++;
      if (hz < 500) low += energy;
      else if (hz < 2000) mid += energy;
      else high += energy;
    }
    const safeTotal = Math.max(total, 1e-12);
    const lowRatio = low / safeTotal;
    const midRatio = mid / safeTotal;
    const highRatio = high / safeTotal;
    const delta0 = lowRatio - this.previousBands[0];
    const delta1 = midRatio - this.previousBands[1];
    const delta2 = highRatio - this.previousBands[2];
    const flux = (delta0 > 0 ? delta0 : 0) + (delta1 > 0 ? delta1 : 0) + (delta2 > 0 ? delta2 : 0);
    this.previousBands[0] = lowRatio;
    this.previousBands[1] = midRatio;
    this.previousBands[2] = highRatio;
    const arithmetic = safeTotal / Math.max(1, bins);
    const flatness = Math.exp(logSum / Math.max(1, bins)) / Math.max(arithmetic, 1e-12);
    const zcr = crossings / FRAME_SIZE;
    const periodicity = zcr <= 0.04 && lowRatio >= 0.30 ? 0.45 : (zcr <= 0.08 ? 0.20 : 0);
    return {
      startSample: startSample,
      rms: rms,
      zcr: zcr,
      lowRatio: lowRatio,
      midRatio: midRatio,
      highRatio: highRatio,
      centroid: weighted / safeTotal,
      flatness: flatness,
      periodicity: periodicity,
      flux: flux,
      clippedRatio: clipped / FRAME_SIZE
    };
  }

  private spectralChange(frames: Array<FrameFeature>): number {
    if (frames.length < 2) return 0;
    let change = 0;
    for (let i = 1; i < frames.length; i++) {
      change += Math.abs(frames[i].lowRatio - frames[i - 1].lowRatio);
      change += Math.abs(frames[i].midRatio - frames[i - 1].midRatio);
      change += Math.abs(frames[i].highRatio - frames[i - 1].highRatio);
    }
    return change / (frames.length - 1);
  }

  private meanRms(frames: Array<FrameFeature>, start: number, end: number): number {
    let sum = 0;
    let count = 0;
    for (let i = start; i < end; i++) {
      sum += frames[i].rms;
      count++;
    }
    return count > 0 ? sum / count : 0;
  }

  private logSkip(startSample: number, tag: string, detail: string): void {
    if (this.lastSkipLogSample >= 0 && startSample - this.lastSkipLogSample < SAMPLE_RATE) {
      return;
    }
    this.lastSkipLogSample = startSample;
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s', tag, detail);
  }

  private flagReason(flags: number): string {
    if ((flags & AudioQualityFlag.CLIPPED) !== 0) return 'clipped';
    if ((flags & AudioQualityFlag.LOW_SNR) !== 0) return 'low_snr';
    if ((flags & AudioQualityFlag.TOO_SHORT) !== 0) return 'too_short';
    if ((flags & AudioQualityFlag.TOO_LONG) !== 0) return 'too_long';
    if ((flags & AudioQualityFlag.TONAL) !== 0) return 'tonal';
    if ((flags & AudioQualityFlag.IMPACT) !== 0) return 'impact';
    if ((flags & AudioQualityFlag.SPEECH_LIKE) !== 0) return 'speech_like';
    return 'quality';
  }

  private fft(re: Float64Array, im: Float64Array): void {
    const n = FFT_SIZE;
    for (let i = 0; i < n; i++) {
      const j = this.fftReverse[i];
      if (j > i) {
        let temp = re[i];
        re[i] = re[j];
        re[j] = temp;
        temp = im[i];
        im[i] = im[j];
        im[j] = temp;
      }
    }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1;
      const step = n / size;
      for (let base = 0; base < n; base += size) {
        for (let j = 0, k = 0; j < half; j++, k += step) {
          const left = base + j;
          const right = left + half;
          const wr = this.fftCos[k];
          const wi = this.fftSin[k];
          const tr = re[right] * wr - im[right] * wi;
          const ti = im[right] * wr + re[right] * wi;
          re[right] = re[left] - tr;
          im[right] = im[left] - ti;
          re[left] += tr;
          im[left] += ti;
        }
      }
    }
  }
}
