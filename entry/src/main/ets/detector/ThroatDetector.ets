import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Detect]';

export interface DetectorParams {
  thrDb: number;
  minMs: number;
  maxMs: number;
  cdMs: number;
}

export interface ThroatEvent {
  ts: number;
  durMs: number;
  peakDb: number;
  boutId: number;
  isNewBout: boolean;
}

const HANG_MS = 80;
const BOUT_GAP_MS = 5000;
const REL_DB = 12;
// 清嗓起音（鼻炎/咽炎/鼻液倒流）：声门挤压渐强，约 50-150ms 爬坡。
// 起音判据 = 触发块必须从「此前约 60ms 的低电平」抬升起来（preQuiet），
// 持续说话/电视由忙碌门 + preQuiet 双重拦截
const PRE_QUIET_RATIO = 0.5; // 前 3 个子块均值 ≤ 阈值一半才算新起音
const PRE_QUIET_BLOCKS = 3;  // 60ms 前置安静窗
const BUSY_TAU_MS = 2000;
const BUSY_LIMIT = 0.28;
const FLOOR_TAU_MS = 1600;
const FLOOR_LOUD_TAU_MS = 10000;
const WARMUP_MS = 2000; // floor 初值远低于环境，开机前 2 秒不累计 busy，避免误判全忙
const MIN_CREST = 1.3; // 实测真清嗓 crest=1.41（软起音峰均比低）；<1.3 视为持续声
const MAX_CREST = 4.5; // 撞击/削波的峰均比极高，清嗓包络峰均比通常 < 2.5
const MIN_RISE_MS = 20; // 实测真清嗓也可 20ms 到峰；撞击主要靠 crest 上限+频谱门拦
const MAX_RISE_MS = 300; // 清嗓峰值出现晚于咳嗽的爆破，放宽到 300ms

function dbToLin(db: number): number {
  return Math.pow(10, db / 20);
}

/**
 * 清嗓检测（鼻炎/咽炎/鼻液倒流方向）：临床声学表现是
 * 「安静背景下的低频浊音短脉冲」--声带闭合加压后突然放开，
 * 起音渐强(50-150ms)、时长 150-800ms、常阵发性连发。
 * 判据：相对底噪抬升 + 前置安静（真起音）+ 峰值不能来得太快（排撞击）
 * + 短包络回落；持续说话/电视用忙碌门挡掉。
 */
export class ThroatDetector {
  private p: DetectorParams;
  private active: boolean = false;
  private startT: number = 0;
  private peakLin: number = 0;
  private peakT: number = 0;
  private sumRms: number = 0;
  private nBlocks: number = 0;
  private hang: number = 0;
  private cooldownUntil: number = 0;
  private curBoutId: number = 0;
  private nextBoutId: number = 1;
  private lastBoutEndTs: number = 0;
  private floorLin: number = 1e-4;
  private hist: Float64Array = new Float64Array(PRE_QUIET_BLOCKS); // 前置安静窗：最近子块 RMS
  private histPos: number = 0;
  private busyMs: number = 0;
  private firstT: number = -1;

  constructor(params: DetectorParams) {
    this.p = params;
  }

  setParams(params: DetectorParams): void {
    this.p = params;
  }

  reset(): void {
    this.active = false;
    this.peakLin = 0;
    this.peakT = 0;
    this.sumRms = 0;
    this.nBlocks = 0;
    this.hang = 0;
    this.cooldownUntil = 0;
    this.curBoutId = 0;
    this.lastBoutEndTs = 0;
    this.hist = new Float64Array(PRE_QUIET_BLOCKS);
    this.histPos = 0;
    this.busyMs = 0;
    this.firstT = -1;
  }

  process(rmsLinear: number, nowMs: number, blockMs: number): ThroatEvent | null {
    const rms: number = rmsLinear > 0 ? rmsLinear : 1e-9;
    if (this.firstT < 0) {
      this.firstT = nowMs;
    }
    this.updateFloor(rms, blockMs);
    let ev: ThroatEvent | null = null;
    if (this.active) {
      ev = this.processActive(rms, nowMs, blockMs);
    } else {
      this.processIdle(rms, nowMs, blockMs);
    }
    this.hist[this.histPos] = rms;
    this.histPos = (this.histPos + 1) % PRE_QUIET_BLOCKS;
    return ev;
  }

  /** 触发块之前 PRE_QUIET_BLOCKS 个子块（约 60ms）的均值，用于前置安静判定 */
  private preMean(): number {
    let s: number = 0;
    for (let i = 0; i < this.hist.length; i++) {
      s += this.hist[i];
    }
    return s / this.hist.length;
  }

  private updateFloor(rms: number, blockMs: number): void {
    if (this.active) {
      return;
    }
    const quiet: boolean = rms < this.floorLin * 4;
    const tau: number = quiet ? FLOOR_TAU_MS : FLOOR_LOUD_TAU_MS;
    const a: number = Math.min(1, blockMs / tau);
    this.floorLin = this.floorLin * (1 - a) + rms * a;
    if (this.floorLin < 1e-6) {
      this.floorLin = 1e-6;
    }
  }

  private processIdle(rms: number, nowMs: number, blockMs: number): void {
    const warm: boolean = nowMs - this.firstT < WARMUP_MS;
    const decay: number = Math.exp(-blockMs / BUSY_TAU_MS);
    const loud: boolean = rms > this.floorLin * 3;
    if (!warm) {
      this.busyMs = this.busyMs * decay + (loud ? blockMs : 0);
    }
    const busyRatio: number = this.busyMs / BUSY_TAU_MS;
    const absThr: number = dbToLin(this.p.thrDb);
    const relThr: number = this.floorLin * dbToLin(REL_DB);
    const thr: number = absThr > relThr ? absThr : relThr;
    if (rms < thr) {
      return;
    }
    if (nowMs < this.cooldownUntil) {
      // 临床：鼻液倒流典型表现为阵发性连发清嗓，冷却期只屏蔽衰减尾音，不再顺延，
      // 否则持续清嗓只记第一次
      return;
    }
    if (busyRatio > BUSY_LIMIT) {
      hilog.info(DOMAIN, TAG, 'REJECT_BUSY ratio=%{public}s', String(Math.round(busyRatio * 100) / 100));
      return;
    }
    // 前置安静：触发块前约 60ms 必须明显低于阈值，才是「新起音」；
    // 否则是持续声的延续（忙碌门漏网的间歇说话/电视），不触发
    const preQuiet: boolean = this.preMean() <= thr * PRE_QUIET_RATIO;
    const aboveFloor: boolean = rms >= this.floorLin * dbToLin(REL_DB);
    if (!preQuiet || !aboveFloor) {
      const preDb: number = 20 * Math.log10(Math.max(this.preMean(), 1e-9));
      const thrDbNow: number = 20 * Math.log10(Math.max(thr, 1e-9));
      hilog.info(DOMAIN, TAG,
        'REJECT_ONSET pre=%{public}sdB thr=%{public}sdB quiet=%{public}s above=%{public}s',
        String(Math.round(preDb * 10) / 10), String(Math.round(thrDbNow * 10) / 10),
        String(preQuiet), String(aboveFloor));
      return;
    }
    this.active = true;
    this.startT = nowMs - blockMs;
    this.peakLin = rms;
    this.peakT = nowMs;
    this.sumRms = rms;
    this.nBlocks = 1;
    this.hang = 0;
  }

  private processActive(rms: number, nowMs: number, blockMs: number): ThroatEvent | null {
    this.sumRms += rms;
    this.nBlocks++;
    if (rms > this.peakLin) {
      this.peakLin = rms;
      this.peakT = nowMs;
    }
    const absThr: number = dbToLin(this.p.thrDb);
    const relThr: number = this.floorLin * dbToLin(REL_DB);
    const thr: number = absThr > relThr ? absThr : relThr;
    if (rms < thr) {
      this.hang += blockMs;
    } else {
      this.hang = 0;
    }
    if (this.hang >= HANG_MS) {
      return this.close(nowMs);
    }
    return null;
  }

  private close(nowMs: number): ThroatEvent | null {
    this.active = false;
    const dur: number = nowMs - this.startT;
    this.cooldownUntil = nowMs + this.p.cdMs;
    const minMs: number = this.p.minMs < 80 ? 80 : this.p.minMs;
    if (dur < minMs || dur > this.p.maxMs) {
      hilog.info(DOMAIN, TAG, 'REJECT_DUR %{public}dms', Math.round(dur));
      return null;
    }
    const riseMs: number = this.peakT - this.startT;
    if (riseMs < MIN_RISE_MS) {
      hilog.info(DOMAIN, TAG, 'REJECT_IMPACT rise=%{public}dms', Math.round(riseMs));
      return null;
    }
    if (riseMs > MAX_RISE_MS) {
      hilog.info(DOMAIN, TAG, 'REJECT_RISE %{public}dms', Math.round(riseMs));
      return null;
    }
    const mean: number = this.nBlocks > 0 ? this.sumRms / this.nBlocks : this.peakLin;
    const crest: number = mean > 1e-9 ? this.peakLin / mean : 1;
    if (crest < MIN_CREST || crest > MAX_CREST) {
      hilog.info(DOMAIN, TAG, 'REJECT_SHAPE crest=%{public}s', String(Math.round(crest * 100) / 100));
      return null;
    }
    const ts: number = Date.now();
    let boutId: number;
    let isNewBout: boolean;
    if (this.lastBoutEndTs > 0 && ts - this.lastBoutEndTs <= BOUT_GAP_MS) {
      boutId = this.curBoutId;
      isNewBout = false;
    } else {
      boutId = this.nextBoutId;
      this.nextBoutId++;
      this.curBoutId = boutId;
      isNewBout = true;
    }
    this.lastBoutEndTs = ts;
    const peakDb: number = 20 * Math.log10(Math.max(this.peakLin, 1e-9));
    const ev: ThroatEvent = {
      ts: ts,
      durMs: Math.round(dur),
      peakDb: Math.round(peakDb * 10) / 10,
      boutId: boutId,
      isNewBout: isNewBout
    };
    return ev;
  }
}
