import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ThroatApp[Spec]';
const DOMAIN = 0x0001;

export interface SpecParams {
  enabled: boolean;
  hfMin: number;   // 高频(>2kHz)能量占比下限
  zcrMin: number;  // 过零率下限
}

export interface SpecResult {
  hfRatio: number;
  zcr: number;
  lowRatio: number;
  centroidHz: number;
  pass: boolean;
  reason: string;
}

const FFT_SIZE = 512;
const HF_BIN = 64; // 16000/512 ≈ 31.25Hz/bin，bin64 ≈ 2000Hz
const LOW_BIN = 10; // ≈ 312Hz 以下视为 rumble / 浊音基频
const HOP = 256;
// 咳嗽轮廓（宽频噪声脉冲）--原判据，hfMin/zcrMin 可在设置页调
const MAX_LOW_RATIO = 0.52;
const MIN_CENTROID_HZ = 500;
const MAX_CENTROID_HZ = 5500;
// 清嗓轮廓（鼻炎/咽炎/鼻液倒流临床声学）：
// 声带闭合加压后突然放开的低频浊音，基频 100-250Hz、能量集中 100-1000Hz；
// 16kHz 采样下浊音过零率约 0.012-0.03，且高频占比远低于咳嗽。
// zcr 下限 0.012 同时滤掉 90Hz 以下的嗡嗡声/空调低频轰鸣
const THROAT_CEN_MIN_HZ = 120;
const THROAT_CEN_MAX_HZ = 1100;
const THROAT_LOW_MIN = 0.18;
const THROAT_LOW_MAX = 0.98; // 实测真清嗓 lowRatio 达 0.76-0.98（近场体传导），仅拒近乎纯低频 rumble
const THROAT_ZCR_MIN = 0.012;
const THROAT_ZCR_MAX = 0.06; // 实测真清嗓 zcr 达 0.053；敲击/点击的结构传声常 ≥0.07
const THROAT_HF_MAX = 0.40;

/**
 * 频谱二次过滤闸门（双轮廓）：
 * 维护最近 2 秒原始样本环，事件关闭时取事件时长样本计算
 * 过零率(ZCR)、高频能量占比、低频占比与频谱质心。
 * 咳嗽轮廓 = 宽频噪声脉冲（hf/zcr 达标、质心 500-5500Hz）；
 * 清嗓轮廓 = 低频浊音（质心 120-1100Hz、低频占比充足、高频滚降）。
 * 任一轮廓匹配即通过，持续说话由包络忙碌门另行拦截。
 * 清嗓轮廓已按实测误报收紧（zcr 下限抬高滤低频嗡嗡声、高频上限下调）；
 * 咳嗽轮廓阈值仍可在设置页调。
 */
export class SpectrumGate {
  private ring: Int16Array;
  private ringPos: number = 0;
  private absSamples: number = 0;
  private sampleRate: number;
  private params: SpecParams;
  private rev: Uint32Array;
  private cosTable: Float64Array;
  private sinTable: Float64Array;

  constructor(sampleRate: number, params: SpecParams) {
    this.sampleRate = sampleRate;
    this.params = params;
    this.ring = new Int16Array(sampleRate * 2);
    const bits = Math.round(Math.log2(FFT_SIZE));
    this.rev = new Uint32Array(FFT_SIZE);
    for (let i = 0; i < FFT_SIZE; i++) {
      let x = i;
      let r = 0;
      for (let b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      this.rev[i] = r;
    }
    this.cosTable = new Float64Array(FFT_SIZE / 2);
    this.sinTable = new Float64Array(FFT_SIZE / 2);
    for (let i = 0; i < FFT_SIZE / 2; i++) {
      this.cosTable[i] = Math.cos(-2 * Math.PI * i / FFT_SIZE);
      this.sinTable[i] = Math.sin(-2 * Math.PI * i / FFT_SIZE);
    }
  }

  setParams(p: SpecParams): void {
    this.params = p;
  }

  getParams(): SpecParams {
    return this.params;
  }

  push(buffer: ArrayBuffer): void {
    const view = new Int16Array(buffer);
    for (let i = 0; i < view.length; i++) {
      this.ring[this.ringPos] = view[i];
      this.ringPos = (this.ringPos + 1) % this.ring.length;
    }
    this.absSamples += view.length;
  }

  /**
   * 未启用返回 null（调用方跳过频谱门）。
   * 启用但样本不足或形态不像清嗓/咳嗽 → pass=false，不再当通过。
   */
  evaluate(durationMs: number): SpecResult | null {
    if (!this.params.enabled) {
      return null;
    }
    let spanMs = durationMs + 40;
    if (spanMs < 120) {
      spanMs = 120;
    }
    if (spanMs > 900) {
      spanMs = 900;
    }
    let span = Math.floor(this.sampleRate * spanMs / 1000);
    const avail = Math.min(this.absSamples, this.ring.length);
    if (span > avail) {
      span = avail;
    }
    if (span < FFT_SIZE) {
      return this.fail('short');
    }
    const startAbs = this.absSamples - span;

    let crossings = 0;
    let prev = this.ring[startAbs % this.ring.length] / 32768;
    for (let i = 1; i < span; i++) {
      const cur = this.ring[(startAbs + i) % this.ring.length] / 32768;
      if ((prev >= 0 && cur < 0) || (prev < 0 && cur >= 0)) {
        crossings++;
      }
      prev = cur;
    }
    const zcr = crossings / span;

    const re = new Float64Array(FFT_SIZE);
    const im = new Float64Array(FFT_SIZE);
    let hfSum = 0;
    let lowSum = 0;
    let wSum = 0;
    let cenNum = 0;
    let windows = 0;
    const hzPerBin: number = this.sampleRate / FFT_SIZE;
    for (let off = 0; off + FFT_SIZE <= span; off += HOP) {
      for (let k = 0; k < FFT_SIZE; k++) {
        const w = 0.5 - 0.5 * Math.cos(2 * Math.PI * k / (FFT_SIZE - 1));
        re[k] = this.ring[(startAbs + off + k) % this.ring.length] / 32768 * w;
        im[k] = 0;
      }
      this.fftInPlace(re, im);
      let total = 0;
      let hf = 0;
      let low = 0;
      let cnum = 0;
      for (let k = 1; k < FFT_SIZE / 2; k++) {
        const e = re[k] * re[k] + im[k] * im[k];
        total += e;
        cnum += k * e;
        if (k >= HF_BIN) {
          hf += e;
        }
        if (k < LOW_BIN) {
          low += e;
        }
      }
      if (total > 1e-9) {
        hfSum += hf;
        lowSum += low;
        wSum += total;
        cenNum += cnum;
        windows++;
      }
    }
    if (windows === 0 || wSum === 0) {
      return this.fail('empty');
    }
    const hfRatio = hfSum / wSum;
    const lowRatio = lowSum / wSum;
    const centroidHz = (cenNum / wSum) * hzPerBin;
    // 咳嗽轮廓：宽频噪声脉冲
    const cough: boolean = hfRatio >= this.params.hfMin && zcr >= this.params.zcrMin
      && lowRatio <= MAX_LOW_RATIO && centroidHz >= MIN_CENTROID_HZ && centroidHz <= MAX_CENTROID_HZ;
    // 清嗓轮廓：低频浊音（鼻液倒流/咽炎的典型声学表现）；
    // lowRatio 上限滤掉晃动/手持的结构传声（能量过度集中于 <312Hz）
    const throat: boolean = centroidHz >= THROAT_CEN_MIN_HZ && centroidHz <= THROAT_CEN_MAX_HZ
      && lowRatio >= THROAT_LOW_MIN && lowRatio <= THROAT_LOW_MAX
      && zcr >= THROAT_ZCR_MIN && zcr <= THROAT_ZCR_MAX && hfRatio <= THROAT_HF_MAX;
    const pass: boolean = cough || throat;
    const reason: string = pass ? (cough ? 'ok' : 'throat') : 'no-match';
    const res: SpecResult = {
      hfRatio: Math.round(hfRatio * 1000) / 1000,
      zcr: Math.round(zcr * 1000) / 1000,
      lowRatio: Math.round(lowRatio * 1000) / 1000,
      centroidHz: Math.round(centroidHz),
      pass: pass,
      reason: reason
    };
    hilog.info(DOMAIN, TAG,
      'SPEC hf=%{public}s zcr=%{public}s low=%{public}s cen=%{public}d pass=%{public}s %{public}s',
      String(res.hfRatio), String(res.zcr), String(res.lowRatio), res.centroidHz,
      String(pass), reason);
    return res;
  }

  private fail(reason: string): SpecResult {
    const res: SpecResult = {
      hfRatio: 0,
      zcr: 0,
      lowRatio: 0,
      centroidHz: 0,
      pass: false,
      reason: reason
    };
    return res;
  }

  private fftInPlace(re: Float64Array, im: Float64Array): void {
    const n = FFT_SIZE;
    for (let i = 0; i < n; i++) {
      const j = this.rev[i];
      if (j > i) {
        let t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1;
      const tableStep = n / size;
      for (let i = 0; i < n; i += size) {
        for (let j = i, k = 0; j < i + half; j++, k += tableStep) {
          const wr = this.cosTable[k];
          const wi = this.sinTable[k];
          const l = j + half;
          const tr = re[l] * wr - im[l] * wi;
          const ti = im[l] * wr + re[l] * wi;
          re[l] = re[j] - tr;
          im[l] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
        }
      }
    }
  }
}
