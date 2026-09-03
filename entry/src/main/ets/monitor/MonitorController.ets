import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AudioCaptureManager } from '../audio/AudioCaptureManager';
import { ContinuousTaskHelper } from '../task/ContinuousTaskHelper';
import { ThroatDetector, DetectorParams } from '../detector/ThroatDetector';
import { SpectrumGate, SpecParams } from '../detector/SpectrumGate';
import { HumanSoundDetector, DetectorDecision } from '../detector/HumanSoundDetector';
import { AcousticEvent } from '../detection/DetectionTypes';
import { DbManager, EventRow, TodayCounts } from '../data/DbManager';
import { WeatherService, WeatherInfo } from '../weather/WeatherService';
import { ClipRecorder } from '../clip/ClipRecorder';
import { FeatureFlags } from '../config/AppConfig';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Monitor]';
// 临床（鼻炎/咽炎/鼻液倒流）：单次清嗓 150-800ms，连发间隔可短至 300ms 左右，
// 冷却期只用于屏蔽同一事件的衰减尾音，不能吞掉连发计数。
// v3：实测安静环境下误计（撞击/磕碰/环境声），阈值上调 3dB、最短时长 80→100ms
const DEFAULT_DAY: DetectorParams = { thrDb: -33, minMs: 80, maxMs: 800, cdMs: 350 };
const DEFAULT_NIGHT: DetectorParams = { thrDb: -39, minMs: 80, maxMs: 800, cdMs: 350 };
const DEFAULT_SPEC: SpecParams = { enabled: true, hfMin: 0.06, zcrMin: 0.035 };

export interface ScheduleRange {
  s: string; // "HH:mm"
  e: string; // "HH:mm"
}

export interface UiHooks {
  onStatus: (s: string) => void;
  onEventLine: (line: string) => void;
  onTodayCounts: (coughs: number, throatClears: number, bouts: number) => void;
  onEventAccepted: (peakDb: number) => void;
  onWeather: (info: WeatherInfo | null) => void;
  onRunningChanged: (running: boolean) => void;
  onStartFailed: (msg: string) => void;
}

function hhmmToMin(s: string): number {
  const parts = s.split(':');
  if (parts.length !== 2) {
    return -1;
  }
  const h = Number.parseInt(parts[0], 10);
  const m = Number.parseInt(parts[1], 10);
  if (Number.isNaN(h) || Number.isNaN(m) || h < 0 || h > 23 || m < 0 || m > 59) {
    return -1;
  }
  return h * 60 + m;
}

/**
 * 监听编排器。生命周期铁律：先挂长时任务再开录音；先停录音再撤长时任务。
 * 时段调度：应用进程存活期间按 schedules 自动启停（跨零点窗口已处理）。
 * 注意系统限制：后台无法启动录音，自动开始仅在 App 处于前台/进程活跃时生效。
 */
export class MonitorController {
  private db: DbManager = DbManager.getInstance();
  private weather: WeatherService = new WeatherService();
  private clips: ClipRecorder | null = null;
  private mgr: AudioCaptureManager | null = null;
  private taskHelper: ContinuousTaskHelper | null = null;
  private detector: ThroatDetector = new ThroatDetector(DEFAULT_DAY);
  private specGate: SpectrumGate = new SpectrumGate(16000, DEFAULT_SPEC);
  private humanDetector: HumanSoundDetector = new HumanSoundDetector();
  private currentBoutId: number = 0;
  private nextBoutId: number = 1;
  private lastAcceptedEndSample: number = -1;
  private paramsDay: DetectorParams = DEFAULT_DAY;
  private paramsNight: DetectorParams = DEFAULT_NIGHT;
  private schedules: Array<ScheduleRange> = [];
  private sessionId: number = 0;
  private runningState: boolean = false;
  private starting: boolean = false;
  private weatherTimerId: number = -1;
  private minuteTimerId: number = -1;
  private todayPeaks: number = 0;
  private todayCoughs: number = 0;
  private todayThroatClears: number = 0;
  private todayBouts: number = 0;
  private ui: UiHooks;
  private clipEnabled: boolean = FeatureFlags.CLIP_ENABLED;
  private ctxCache: common.UIAbilityContext | null = null;

  constructor(ui: UiHooks) {
    this.ui = ui;
    MonitorController.activeInstance = this;
  }

  isRunning(): boolean {
    return this.runningState;
  }

  private static activeInstance: MonitorController | null = null;

  /**
   * UIAbility 销毁（如用户划掉任务）时兜底：关闭未结束的会话、撤长时任务，
   * 避免僵尸会话和"有通知无录音"触发系统管控
   */
  static async emergencyTeardown(): Promise<void> {
    const c = MonitorController.activeInstance;
    if (c !== null && c.runningState) {
      hilog.warn(DOMAIN, TAG, 'emergency teardown on ability destroy');
      await c.teardown('crash');
    }
  }

  isClipEnabled(): boolean {
    return this.clipEnabled;
  }

  // ---------- 对外：设置读写 ----------
  async getParams(): Promise<Array<DetectorParams>> {
    const ver = await this.db.getSetting('params_ver');
    if (ver !== '4') {
      // 迁移：v1 咳嗽模型；v2 清嗓临床模型但误报多；v3 压误报但实测把真清嗓
      // （rise 20ms/crest 1.41/99ms）也拒了；v4 按实测真事件分布放宽门限
      await this.db.setSetting('params_day', JSON.stringify(DEFAULT_DAY));
      await this.db.setSetting('params_night', JSON.stringify(DEFAULT_NIGHT));
      await this.db.setSetting('params_ver', '4');
      hilog.info(DOMAIN, TAG, 'detector params migrated to v4 (measured-recalibrated)');
      return [DEFAULT_DAY, DEFAULT_NIGHT];
    }
    const dayStr = await this.db.getSetting('params_day');
    const nightStr = await this.db.getSetting('params_night');
    let day = DEFAULT_DAY;
    let night = DEFAULT_NIGHT;
    try {
      if (dayStr !== null) {
        day = JSON.parse(dayStr) as DetectorParams;
      }
      if (nightStr !== null) {
        night = JSON.parse(nightStr) as DetectorParams;
      }
    } catch (e) { /* 用默认 */ }
    return [day, night];
  }

  async saveParams(day: DetectorParams, night: DetectorParams): Promise<void> {
    this.paramsDay = day;
    this.paramsNight = night;
    await this.db.setSetting('params_day', JSON.stringify(day));
    await this.db.setSetting('params_night', JSON.stringify(night));
    await this.db.setSetting('params_ver', '4');
    this.detector.setParams(this.activeParams());
  }

  async getSpecParams(): Promise<SpecParams> {
    const enabledStr = await this.db.getSetting('spec_enabled');
    const hfStr = await this.db.getSetting('spec_hf');
    const zcrStr = await this.db.getSetting('spec_zcr');
    const p: SpecParams = {
      enabled: enabledStr !== null ? enabledStr === '1' : true,
      hfMin: hfStr !== null ? Number.parseFloat(hfStr) : DEFAULT_SPEC.hfMin,
      zcrMin: zcrStr !== null ? Number.parseFloat(zcrStr) : DEFAULT_SPEC.zcrMin
    };
    if (Number.isNaN(p.hfMin)) {
      p.hfMin = DEFAULT_SPEC.hfMin;
    }
    // 0.04 是旧默认值：实测刮擦/敲击声以 hf 贴线 0.04 边缘通过咳嗽轮廓，
    // 存库的旧默认一并升级到新默认；用户显式改过的其他值不受影响
    if (p.hfMin === 0.04) {
      p.hfMin = DEFAULT_SPEC.hfMin;
    }
    if (Number.isNaN(p.zcrMin)) {
      p.zcrMin = DEFAULT_SPEC.zcrMin;
    }
    return p;
  }

  async saveSpecParams(p: SpecParams): Promise<void> {
    this.specGate.setParams(p);
    await this.db.setSetting('spec_enabled', p.enabled ? '1' : '0');
    await this.db.setSetting('spec_hf', String(p.hfMin));
    await this.db.setSetting('spec_zcr', String(p.zcrMin));
  }

  async getSchedules(): Promise<Array<ScheduleRange>> {
    const str = await this.db.getSetting('schedules');
    if (str === null) {
      return [];
    }
    try {
      return JSON.parse(str) as Array<ScheduleRange>;
    } catch (e) {
      return [];
    }
  }

  async saveSchedules(list: Array<ScheduleRange>): Promise<void> {
    this.schedules = list;
    await this.db.setSetting('schedules', JSON.stringify(list));
  }

  async setClipEnabled(v: boolean): Promise<void> {
    this.clipEnabled = v;
    await this.db.setSetting('clip_switch', v ? '1' : '0');
  }

  /**
   * 页面加载时调用：配置了监测时段且当前在窗口内 → 自动开始；
   * 未配时段但开了"启动即开始监测" → 直接开始
   */
  async maybeAutoStart(context: common.UIAbilityContext): Promise<void> {
    if (this.runningState || this.starting) {
      return;
    }
    this.ctxCache = context;
    const autostart = await this.db.getSetting('autostart');
    const inWin = await this.inAnyWindowNow();
    if ((inWin && this.schedules.length > 0) || autostart === '1') {
      hilog.info(DOMAIN, TAG, 'auto start (inWindow=%{public}s)', String(inWin));
      await this.start(context);
    }
  }

  // ---------- 启停 ----------
  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.runningState || this.starting) {
      return;
    }
    this.starting = true;
    this.ctxCache = context;
    try {
      this.ui.onStatus('初始化数据库…');
      await this.db.init(context);

      this.ui.onStatus('读取配置…');
      await this.loadSettings();

      this.ui.onStatus('检查权限…');
      const atManager = abilityAccessCtrl.createAtManager();
      let micGranted = false;
      try {
        const bundleInfo = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        const state = atManager.checkAccessTokenSync(
          bundleInfo.appInfo.accessTokenId, 'ohos.permission.MICROPHONE');
        micGranted = state === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      } catch (e) {
        micGranted = false;
      }
      if (!micGranted) {
        // 仅首次（或被拒后）弹窗；已授权时静默通过，保证时段自动启停不被阻塞
        this.ui.onStatus('申请权限…');
        const result = await atManager.requestPermissionsFromUser(context,
          ['ohos.permission.MICROPHONE', 'ohos.permission.APPROXIMATELY_LOCATION']);
        // 第0个是麦克风：被拒则无法工作；定位被拒只影响天气，不阻断
        if (result.authResults.length === 0 || result.authResults[0] !== 0) {
          const msg = '麦克风权限被拒绝，无法开始监测。请到系统设置中为本应用开启麦克风权限后重试';
          this.ui.onStatus(msg);
          this.ui.onStartFailed(msg);
          return;
        }
      }

      this.ui.onStatus('挂载长时任务…');
      this.taskHelper = new ContinuousTaskHelper(context);
      await this.taskHelper.start();

      this.sessionId = await this.db.startSession(Date.now());

      this.ui.onStatus('启动录音…');
      this.humanDetector.reset();
      this.currentBoutId = 0;
      this.nextBoutId = 1;
      this.lastAcceptedEndSample = -1;
      this.mgr = await this.buildCapturer();
      await this.mgr.start();

      this.runningState = true;
      this.ui.onRunningChanged(true);
      this.ui.onStatus(`监测中 · ${this.isNightNow() ? '夜间' : '白天'}参数 · 可锁屏`);
      hilog.info(DOMAIN, TAG, 'started, session=%{public}d', this.sessionId);

      this.startTimers();
      this.refreshWeather(true); // 会话开始：重新定位
      // 恢复今日已有计数（跨会话累计）
      this.db.todayCounts().then((c: TodayCounts) => {
        this.todayPeaks = c.peaks;
        this.todayCoughs = c.coughs;
        this.todayThroatClears = c.throatClears;
        this.todayBouts = c.bouts;
        this.ui.onTodayCounts(this.todayCoughs, this.todayThroatClears, this.todayBouts);
      }).catch(() => {});
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', err.message);
      const msg = `启动失败：${err.message}`;
      this.ui.onStatus(msg);
      this.ui.onStartFailed(msg);
      await this.teardown('crash');
    } finally {
      this.starting = false;
    }
  }

  async stop(): Promise<void> {
    if (!this.runningState && this.mgr === null) {
      return;
    }
    this.ui.onStatus('停止中…');
    await this.teardown('normal');
    this.ui.onStatus('已停止');
  }

  /** 清空并重置全部数据：先停监听，再清库、删录音片段、重置内存计数 */
  async clearAllData(): Promise<void> {
    if (this.runningState || this.mgr !== null) {
      await this.stop();
    }
    await this.db.clearAllData();
    this.deleteClipFiles();
    this.todayPeaks = 0;
    this.todayCoughs = 0;
    this.todayThroatClears = 0;
    this.todayBouts = 0;
    this.ui.onTodayCounts(0, 0, 0);
    AppStorage.setOrCreate('dataEpoch', Date.now());
    hilog.info(DOMAIN, TAG, 'all data cleared and reset');
  }

  private deleteClipFiles(): void {
    if (this.ctxCache === null) {
      return;
    }
    const dir = `${this.ctxCache.filesDir}/clips`;
    try {
      const names = fs.listFileSync(dir);
      for (const name of names) {
        fs.unlinkSync(`${dir}/${name}`);
      }
      hilog.info(DOMAIN, TAG, 'deleted %{public}d clip files', names.length);
    } catch (e) { /* 目录不存在等情况忽略 */ }
  }

  // ---------- 内部 ----------
  private buildCapturer(): Promise<AudioCaptureManager> {
    return AudioCaptureManager.create(16000, null,
      (buffer: ArrayBuffer, startSample: number) => {
        const decisions = this.humanDetector.push(buffer, startSample);
        for (const decision of decisions) {
          this.onDetectorDecision(decision);
        }
      },
      () => {
        this.onInterrupted();
      });
  }

  private async loadSettings(): Promise<void> {
    this.clipEnabled = false;
    this.clips = null;
    this.paramsDay = (await this.getParams())[0];
    this.paramsNight = (await this.getParams())[1];
    this.schedules = await this.getSchedules();
  }

  private isNightNow(): boolean {
    const h = new Date().getHours();
    return h >= 22 || h < 7;
  }

  private activeParams(): DetectorParams {
    return this.isNightNow() ? this.paramsNight : this.paramsDay;
  }

  private nowMinutes(): number {
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }

  private async inAnyWindowNow(): Promise<boolean> {
    if (this.schedules.length === 0) {
      return false;
    }
    const n = this.nowMinutes();
    for (const r of this.schedules) {
      const s = hhmmToMin(r.s);
      const e = hhmmToMin(r.e);
      if (s < 0 || e < 0) {
        continue;
      }
      if (s <= e) {
        if (n >= s && n < e) {
          return true;
        }
      } else if (n >= s || n < e) { // 跨零点
        return true;
      }
    }
    return false;
  }

  /** 每分钟：切换昼夜参数；按时段自动启停 */
  private evaluateMinute(): void {
    this.detector.setParams(this.activeParams());
    if (this.schedules.length === 0 || this.starting || this.ctxCache === null) {
      return;
    }
    this.inAnyWindowNow().then((inWin: boolean) => {
      if (inWin && !this.runningState) {
        hilog.info(DOMAIN, TAG, 'schedule window opened -> auto start');
        this.start(this.ctxCache as common.UIAbilityContext);
      } else if (!inWin && this.runningState) {
        hilog.info(DOMAIN, TAG, 'schedule window closed -> auto stop');
        this.stop();
      }
    }).catch(() => {});
  }

  private startTimers(): void {
    this.weatherTimerId = setInterval(() => {
      this.refreshWeather(false); // 非重新定位，省电
    }, 3600000);
    this.minuteTimerId = setInterval(() => {
      this.evaluateMinute();
    }, 60000);
  }

  private clearTimers(): void {
    if (this.weatherTimerId !== -1) { clearInterval(this.weatherTimerId); this.weatherTimerId = -1; }
    if (this.minuteTimerId !== -1) { clearInterval(this.minuteTimerId); this.minuteTimerId = -1; }
  }

  private refreshWeather(relocate: boolean): void {
    this.weather.refresh(this.db, relocate).then((info: WeatherInfo | null) => {
      this.ui.onWeather(info);
    }).catch(() => {});
  }

  private onDetectorDecision(decision: DetectorDecision): void {
    if (decision.event === null) {
      hilog.info(DOMAIN, TAG, 'ACOUSTIC_REJECT %{public}s', decision.reason);
      return;
    }
    this.acceptEvent(decision.event);
  }

  private acceptEvent(ev: AcousticEvent): void {
    const gapSamples = this.lastAcceptedEndSample < 0 ? Number.MAX_SAFE_INTEGER :
      ev.startSample - this.lastAcceptedEndSample;
    const isNewBout = gapSamples > 16000 * 5;
    if (isNewBout) {
      this.currentBoutId = this.nextBoutId;
      this.nextBoutId++;
      this.todayBouts++;
    }
    this.lastAcceptedEndSample = Math.max(this.lastAcceptedEndSample, ev.endSample);
    this.todayPeaks++;
    if (ev.type === 'cough') {
      this.todayCoughs++;
    } else {
      this.todayThroatClears++;
    }
    this.ui.onTodayCounts(this.todayCoughs, this.todayThroatClears, this.todayBouts);
    // 同步直推波形：必须在 enqueueEvent（异步批量落库）之前调用，保证 UI 与计数同一帧更新
    this.ui.onEventAccepted(ev.peakDb);
    const ts = Date.now() - Math.round((ev.endSample - ev.startSample) * 1000 / 16000);
    const t = new Date(ts);
    const hh = String(t.getHours()).padStart(2, '0');
    const mm = String(t.getMinutes()).padStart(2, '0');
    const ss = String(t.getSeconds()).padStart(2, '0');
    const label = ev.type === 'cough' ? '咳嗽' : '清嗓';
    this.ui.onEventLine(`${hh}:${mm}:${ss}  ${label}  ${ev.durationMs}ms  ${Math.round(ev.classConfidence * 100)}%`);
    hilog.info(DOMAIN, TAG, 'ACOUSTIC_ACCEPT %{public}s %{public}dms confidence=%{public}s',
      ev.type, ev.durationMs, String(ev.classConfidence));
    const row: EventRow = {
      id: 0,
      ts: ts,
      durationMs: ev.durationMs,
      peakDb: ev.peakDb,
      sessionId: this.sessionId,
      boutId: this.currentBoutId,
      isBoutStart: isNewBout,
      score: ev.classConfidence,
      eventType: ev.type,
      targetConfidence: ev.targetConfidence,
      qualityFlags: ev.qualityFlags,
      algorithmVersion: ev.algorithmVersion
    };
    this.db.enqueueEvent(row);
  }

  /** 录音意外中断（来电、他 App 抢占等）：标记会话中断并自动重启新会话 */
  private onInterrupted(): void {
    if (!this.runningState) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'interrupted, restarting capture');
    this.db.closeSession(this.sessionId, Date.now(), 'interrupt').then(async () => {
      if (this.mgr !== null) {
        await this.mgr.stop();
        this.mgr = null;
      }
      this.sessionId = await this.db.startSession(Date.now());
      this.humanDetector.reset();
      this.currentBoutId = 0;
      this.nextBoutId = 1;
      this.lastAcceptedEndSample = -1;
      this.mgr = await this.buildCapturer();
      await this.mgr.start();
      this.ui.onStatus('录音曾被中断，已自动重启监测');
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'restart after interrupt failed: %{public}s', e.message);
      this.runningState = false;
      this.ui.onRunningChanged(false);
      this.ui.onStatus('录音中断后重启失败，请手动重新开始');
      this.teardown('crash');
    });
  }

  private async teardown(reason: string): Promise<void> {
    this.clearTimers();
    try {
      await this.db.flushEvents();
    } catch (e) { /* 忽略 */ }
    if (this.mgr !== null && this.mgr.isRunning()) {
      try {
        await this.mgr.stop();
      } catch (e) { /* 忽略 */ }
    }
    this.mgr = null;
    await this.db.closeSession(this.sessionId, Date.now(), reason);
    this.sessionId = 0;
    if (this.taskHelper !== null) {
      try {
        await this.taskHelper.stop();
      } catch (e) { /* 忽略 */ }
    }
    this.taskHelper = null;
    this.runningState = false;
    this.ui.onRunningChanged(false);
  }
}
