import { common } from '@kit.AbilityKit';
import { MonitorController } from '../monitor/MonitorController';
import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';
import { FontSize, FontSizeHero, FontWeight, LetterSpacing, LineHeight, Space } from '../theme/Tokens';
import { SafeArea } from '../theme/SafeArea';
import { DbManager, EventWithContext } from '../data/DbManager';

// 参考图取色(Braun 渲染图 1:1,设备固定色,不随主题翻转):
// 黑屏近黑 #1e1e21、键面浅灰 #e2e1dd、描边纯黑 2vp、键托凹面渐变、
// 录制红点 #d6675e、状态灰 #9a9a97、高亮白 #e8e7e3
const DISPLAY_BG: string = '#1e1e21';
const DISPLAY_FG: string = '#f2f1ec';
const DISPLAY_DIM: string = '#9a9a97';
const DISPLAY_FAINT: string = '#6f6f70';
// 记录键（Smartisan OS 录音机官方图标：旋压铝盘 + 烘焙红芯，tools/extract-record-key.mjs 提取）。
// 尺寸按盘径比例派生，改 REC_SIZE 即整体缩放（S=80 / M=100 / L=128 三档）。
const REC_SIZE: number = 100; // 盘外径（M 档）
const REC_CORE_SQ: number = 30; // 录制方芯边长（须覆盖贴图烘焙红点 0.29 盘径）
const REC_CORE_SQ_R: number = 8; // 方芯圆角
const REC_RED: string = '#f54e00'; // 波形红线 / 状态点，与统计·设置选中态同色（palette.brand）
// 渐变停止组：ArkTS linearGradient/radialGradient 的 colors 要求 [ResourceColor, number] 元组，
// 不能声明成 (string | number)[][]，否则 CompileArkTS 报 No overload matches this call。
type RecGradient = Array<[ResourceColor, number]>;
// 贴图来源：官方 Smartisan 录音机图标（坚果R2 系统图标提取包，透明底 PNG），
// 铝盘与闲置红点均烘焙在图内；录制态 ■ 由 ArkUI 叠加（盖住红点），便于 ●/■ 切换。
// 状态罩：悬停提亮 / 按压压暗
const HOVER_TINT: string = '#59ffffff';
const PRESS_TINT: string = '#1a000000';
// 录制 ■ 芯：与贴图红点同族正红（顶部微亮、边缘压深）；按压收暗一档
const CORE_REC: RecGradient =
  [['#e04538', 0], ['#c92a1e', 0.55], ['#8e1f15', 1]];
const CORE_REC_PRESSED: RecGradient =
  [['#c23b30', 0], ['#a32318', 0.55], ['#6e1610', 1]];
// 点阵：Canvas 自适应绘制的博朗设备开孔（扫地机 grille 同款密点）。
// 列数 = floor(画布实宽 / 间距)，任何屏幕都不会超屏；之前 Row 固定 32 列会撑到 470vp 超出屏幕。
// 颜色取 palette.textTertiary（浅 #807d72 / 深 #8a877d暖灰），深浅主题都柔和。
const GRILLE_DOT: number = 4; // 点径
const GRILLE_PITCH: number = 11; // 点间距（点径 4 + 缝 7，密而不连）
const GRILLE_ROWS_N: number = 6; // 行数
const STRIP_H: number = (GRILLE_ROWS_N - 1) * GRILLE_PITCH + GRILLE_DOT; // 48
const STATUS_DOT_BLINK_MS: number = 900; // 监测中状态点半周期（亮/灭各 900ms，约 2s 一周期，贴近真实录音指示灯）
const WAVE_MAX_BARS: number = 160;
const WAVE_BAR_W: number = 2;
const WAVE_BAR_PITCH: number = 4;
const WAVE_PLAYHEAD_GAP: number = 4; // 红色标线距最后一根白色条的额外间距
const WAVE_INSET_X: number = 16; // 红线 / 基准线距左缘，避免贴边

/** 参考图为 12h「04.35 PM」格式（点分隔 + AM/PM），全页统一此式 */
function fmtClock(d: Date): string {
  const pad = (n: number): string => n.toString().padStart(2, '0');
  let h: number = d.getHours() % 12;
  if (h === 0) {
    h = 12;
  }
  const ap: string = d.getHours() < 12 ? 'AM' : 'PM';
  return `${pad(h)}.${pad(d.getMinutes())} ${ap}`;
}

/**
 * 首页：屏幕即机身（参考 Braun 录音机渲染图）。无假机身卡片，
 * 页面底色铺满全屏（含状态栏/指示条区域），黑屏 / 键组以 layoutWeight
 * 60 / 20 分配，中间点阵条带固定 STRIP_H（6 行密点、自适应列数）且上下各留 lg 边距，
 * 与黑屏 / 按键拉开呼吸距离。
 *
 * - 黑屏：状态行（时间 + 紧邻的红点状态（监测中间歇闪烁），右侧天气 + 记录用药💊 / 统计 / 设置图标）
 *   + 弹性波形区（横向中间基准线；检出事件才画条，条留在原位不滚动）
 *   + 左下大计时 + 瘦计数行；高度已压矮（73→60），底部内边距加大；
 * - 条带：6 行密点阵（直径 4vp、间距 11vp，扫地机开孔密度），
 *   Canvas 按实宽自适应列数、居中，永不超屏，暖灰配色；
 * - 键组：Smartisan 风记录键（悬浮车削铝盘 / 居中红芯，纯 ArkUI 声明式），
 *   闲置 ● / 录制中 ■；默认 / 悬停 / 按压 / 禁用四态视觉反馈。
 * 统计 / 设置由 Index 以 Navigation 压栈方式打开，本页只负责回调通知。
 * 记录用药为本地动作（写入数据库 + Toast 提示），不需要回调。
 * 默认不加条；检出咳嗽/清嗓才画条并留在画面上，高度跟峰值。
 */
@Component
export struct HomeView {
  @Watch('onRunningChanged') @Link running: boolean;
  @Watch('onCountsChanged') @Link todayCoughs: number;
  @Watch('onCountsChanged') @Link todayThroatClears: number;
  @Link todayBouts: number;
  @Watch('onWaveTick') @Link waveSeq: number;
  @Link wavePeakDb: number;
  @Prop weather: string = '';
  @StorageLink('topSafeArea') topSafeArea: number = 0;
  @StorageLink('bottomSafeArea') bottomSafeArea: number = 0;
  ctrl: MonitorController | null = null;
  onStats: () => void = () => {};
  onSettings: () => void = () => {};
  @State elapsed: number = 0;
  @State sessionStart: string = '';
  @State palette: ColorPalette = ThemeManager.instance.current();
  @State fingerRec: boolean = false;
  @State hoverRec: boolean = false;
  @State recEnabled: boolean = true;
  @State fingerMed: boolean = false;
  @State fingerStats: boolean = false;
  @State fingerSettings: boolean = false;
  @State statusDotOn: boolean = true;
  private unsubscribe: (() => void) | null = null;
  private timerId: number = -1;
  private blinkTimerId: number = -1;
  private lastWaveSeq: number = 0;
  private liveBars: Array<number> = [];
  private waveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private waveReady: boolean = false;
  private grilleCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private grilleReady: boolean = false;

  aboutToAppear(): void {
    this.unsubscribe = ThemeManager.instance.subscribe((p: ColorPalette) => {
      this.palette = p;
      this.drawGrille();
    });
    if (this.running) {
      this.startTimer();
    }
    setTimeout(() => {
      this.refreshWave();
    }, 0);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
    this.stopTimer();
  }

  private onRunningChanged(): void {
    if (this.running) {
      this.startTimer();
    } else {
      this.stopTimer();
    }
    this.drawWave();
  }

  private onCountsChanged(): void {
    if (this.todayCoughs === 0 && this.todayThroatClears === 0) {
      this.liveBars = [];
      this.drawWave();
    }
  }

  private startTimer(): void {
    this.stopTimer();
    this.sessionStart = fmtClock(new Date());
    this.statusDotOn = true;
    this.timerId = setInterval(() => {
      this.elapsed += 1;
    }, 1000);
    this.blinkTimerId = setInterval(() => {
      this.statusDotOn = !this.statusDotOn;
    }, STATUS_DOT_BLINK_MS);
    this.drawWave();
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.blinkTimerId !== -1) {
      clearInterval(this.blinkTimerId);
      this.blinkTimerId = -1;
    }
    this.elapsed = 0;
    this.sessionStart = '';
    this.statusDotOn = true;
  }

  private dbToBar(db: number): number {
    if (db >= 0) {
      return 1;
    }
    if (db <= -60) {
      return 0.2;
    }
    return 0.2 + 0.8 * ((db + 60) / 60);
  }

  private onWaveTick(): void {
    if (this.waveSeq === this.lastWaveSeq) {
      return;
    }
    this.lastWaveSeq = this.waveSeq;
    if (this.waveSeq <= 0) {
      return;
    }
    this.liveBars.push(this.dbToBar(this.wavePeakDb));
    if (this.liveBars.length > WAVE_MAX_BARS) {
      this.liveBars.shift();
    }
    this.drawWave();
  }

  private async refreshWave(): Promise<void> {
    try {
      const start = new Date().setHours(0, 0, 0, 0);
      const events: Array<EventWithContext> =
        await DbManager.getInstance().eventsWithContext(WAVE_MAX_BARS, start);
      const ordered = events.slice().reverse();
      this.liveBars = ordered.map((e: EventWithContext) => this.dbToBar(e.peakDb));
    } catch (e) {
      this.liveBars = [];
    }
    this.drawWave();
  }

  private elapsedText(): string {
    const h: number = Math.floor(this.elapsed / 3600);
    const m: number = Math.floor((this.elapsed % 3600) / 60);
    const s: number = this.elapsed % 60;
    const pad = (n: number): string => n.toString().padStart(2, '0');
    return `${pad(h)}:${pad(m)}:${pad(s)}`;
  }

  private weatherShort(): string {
    if (this.weather === '') {
      return '';
    }
    const parts = this.weather.split(' ');
    return parts.length > 0 ? parts[0] : this.weather;
  }

  private clockShort(): string {
    if (this.running && this.sessionStart !== '') {
      return this.sessionStart;
    }
    return fmtClock(new Date());
  }

  private drawWave(): void {
    if (!this.waveReady) {
      return;
    }
    const ctx = this.waveCtx;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const mid = Math.floor(h / 2);
    const inset = WAVE_INSET_X;
    // 横向中间基准线：左右留白，条在上下对称生长
    ctx.fillStyle = DISPLAY_DIM;
    ctx.fillRect(inset, mid, Math.max(0, w - inset * 2), 1);
    const maxN = Math.max(1, Math.floor((w - inset * 2) / WAVE_BAR_PITCH));
    const src = this.liveBars;
    const bars = src.length > maxN ? src.slice(src.length - maxN) : src;
    const maxH = h * 0.82;
    let x = inset;
    ctx.fillStyle = DISPLAY_FG;
    for (let i = 0; i < bars.length; i++) {
      const bh = Math.max(2, bars[i] * maxH);
      ctx.fillRect(x, mid - bh / 2, WAVE_BAR_W, bh);
      x += WAVE_BAR_PITCH;
    }
    if (this.running) {
      const playX = bars.length > 0 ? x + WAVE_PLAYHEAD_GAP : inset;
      const lineH = h * 0.46;
      ctx.fillStyle = REC_RED;
      ctx.fillRect(playX, mid - lineH / 2, 2, lineH);
      ctx.beginPath();
      ctx.arc(playX + 1, mid - lineH / 2, 3.5, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  private drawGrille(): void {
    if (!this.grilleReady) {
      return;
    }
    const ctx = this.grilleCtx;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    // 列数按实宽自适应：铺满又不超屏，任何机型都是居中的密点阵
    const d = GRILLE_DOT;
    const pitch = GRILLE_PITCH;
    const rows = GRILLE_ROWS_N;
    const cols = Math.max(1, Math.floor(w / pitch));
    const totalW = (cols - 1) * pitch + d;
    const totalH = (rows - 1) * pitch + d;
    const sx = (w - totalW) / 2;
    const sy = (h - totalH) / 2;
    ctx.fillStyle = this.palette.textTertiary;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        ctx.beginPath();
        ctx.arc(sx + c * pitch + d / 2, sy + r * pitch + d / 2, d / 2, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  private async quickMed(): Promise<void> {
    const db = DbManager.getInstance();
    const medsStr = await db.getSetting('meds');
    let drug = '用药';
    try {
      if (medsStr !== null) {
        const arr = JSON.parse(medsStr) as Array<string>;
        if (arr.length > 0) {
          drug = arr[0];
        }
      }
    } catch (e) { /* 默认 */ }
    await db.insertMedication(Date.now(), drug, '');
    const time = new Date().toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit' });
    this.getUIContext().getPromptAction().showToast({
      message: `已记录 ${time} ${drug}`,
      duration: 5000
    });
  }

  private toggleListen(): void {
    if (this.ctrl === null) {
      return;
    }
    if (this.running) {
      this.ctrl.stop();
    } else {
      this.ctrl.start(this.getUIContext().getHostContext() as common.UIAbilityContext);
    }
  }

  @Builder
  grille() {
    // 博朗设备开孔（扫地机 grille 同款）：Canvas 自适应密点，列数随实宽增减，
    // 360vp 屏约 32 列 × 6 行 ≈ 190 孔，居中，永不超屏。
    // 上下各留 lg 边距，与黑屏 / 按键拉开距离。
    Canvas(this.grilleCtx)
      .width('100%')
      .height(STRIP_H)
      .margin({ top: Space.lg, bottom: Space.lg })
      .onReady(() => {
        this.grilleReady = true;
        this.drawGrille();
      })
      .onAreaChange((_old: Area, _cur: Area) => {
        this.drawGrille();
      })
      .onClick(() => {
        this.drawWave();
      })
      .focusable(true)
      .accessibilityText('波形区')
  }

  @Builder
  recStopCell() {
    // Smartisan 风记录键：官方录音机图标贴图（旋压铝盘 + 烘焙红点）；
    // 闲置 ● 为贴图自带红点，录制 ■ 由 ArkUI 叠加盖住红点。
    // 层序（Stack 自下而上）：铝盘 Image(圆形载体带投影) → 悬停提亮罩 → 按压压暗罩
    //   → 录制 ■ 芯(仅录制中)。
    // 四态：默认悬浮投影；悬停微放大提亮；按压下沉 2vp 收投影；禁用淡化失影。
    Column({ space: Space.md }) {
      Stack() {
        Row() // 铝盘：官方图标贴图；投影挂圆形载体（圆角跟随盘形，杜绝方形阴影）
          .width(REC_SIZE)
          .height(REC_SIZE)
          .borderRadius(REC_SIZE / 2)
          .shadow(this.recEnabled ? (this.fingerRec ? {
            radius: 6,
            color: '#28000000',
            offsetX: 0,
            offsetY: 2
          } : (this.hoverRec ? {
            radius: 20,
            color: '#4d000000',
            offsetX: 0,
            offsetY: 9
          } : {
            radius: 14,
            color: '#3a000000',
            offsetX: 0,
            offsetY: 7
          })) : {
            radius: 0,
            color: Color.Transparent,
            offsetX: 0,
            offsetY: 0
          })
          .hitTestBehavior(HitTestMode.None)
        Image($r('app.media.record_key'))
          .width(REC_SIZE)
          .height(REC_SIZE)
          .interpolation(ImageInterpolation.High)
          .draggable(false)
          .hitTestBehavior(HitTestMode.None)
        Row() // 悬停提亮罩
          .width(REC_SIZE)
          .height(REC_SIZE)
          .borderRadius(REC_SIZE / 2)
          .backgroundColor(this.hoverRec && !this.fingerRec && this.recEnabled ? HOVER_TINT : Color.Transparent)
          .hitTestBehavior(HitTestMode.None)
        Row() // 按压压暗罩
          .width(REC_SIZE)
          .height(REC_SIZE)
          .borderRadius(REC_SIZE / 2)
          .backgroundColor(this.fingerRec && this.recEnabled ? PRESS_TINT : Color.Transparent)
          .hitTestBehavior(HitTestMode.None)
        if (this.running) {
          Row() // ■ 录制态方芯（盖住贴图烘焙红点）
            .width(REC_CORE_SQ)
            .height(REC_CORE_SQ)
            .borderRadius(REC_CORE_SQ_R)
            .radialGradient({
              center: ['45%', '35%'],
              radius: REC_CORE_SQ * 0.75,
              colors: this.fingerRec ? CORE_REC_PRESSED : CORE_REC
            })
            .shadow({ radius: 4, color: '#388c150e', offsetX: 0, offsetY: 1 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(REC_SIZE)
      .height(REC_SIZE)
      .alignContent(Alignment.Center)
      .scale({
        x: this.hoverRec && !this.fingerRec && this.recEnabled ? 1.02 : 1,
        y: this.hoverRec && !this.fingerRec && this.recEnabled ? 1.02 : 1
      })
      .translate({ y: this.fingerRec ? 2 : 0 })
      .animation({ duration: 140, curve: Curve.EaseOut })
      .enabled(this.recEnabled)
      .opacity(this.recEnabled ? 1 : 0.45)
      .onClick(() => {
        this.toggleListen();
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.fingerRec = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.fingerRec = false;
        }
      })
      .onHover((hover: boolean) => {
        this.hoverRec = hover;
      })
      .focusable(true)
      .accessibilityText(this.running ? '停止记录' : '开始记录')
      Text(this.running ? '停止记录' : '开始记录')
        .fontSize(FontSize.button)
        .fontWeight(FontWeight.regular)
        .letterSpacing(2)
        .lineHeight(LineHeight.bodySm)
        .fontColor(this.recEnabled ? this.palette.textSecondary : this.palette.textTertiary)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .layoutWeight(2)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // 键组：仅承载 Smartisan 风记录键，直接坐页面底色，无任何外壳装饰
  @Builder
  controlDeck() {
    Column() {
      this.recStopCell()
    }
    .width('100%')
    .layoutWeight(20)
  }

  @Builder
  displayBlock() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(this.clockShort())
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.regular)
          .letterSpacing(0.8)
          .lineHeight(LineHeight.caption)
          .fontColor(DISPLAY_DIM)
        Row({ space: Space.xs }) {
          Text('●')
            .fontSize(FontSize.caption)
            .lineHeight(LineHeight.caption)
            .fontColor(this.running ? REC_RED : DISPLAY_FAINT)
            .opacity(this.running && !this.statusDotOn ? 0 : 1)
          Text(this.running ? '监测中' : '未监测')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.regular)
            .letterSpacing(0.8)
            .lineHeight(LineHeight.caption)
            .fontColor(DISPLAY_DIM)
        }
        .alignItems(VerticalAlign.Center)
        Blank()
        if (this.weatherShort() !== '') {
          Text(this.weatherShort())
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.regular)
            .lineHeight(LineHeight.caption)
            .fontColor(DISPLAY_DIM)
        }
        // 右上角图标入口：记录用药💊 / 统计 / 设置
        Text('💊')
          .fontSize(FontSize.titleMd)
          .opacity(this.fingerMed ? 0.6 : 1)
          .padding({ top: Space.xs, bottom: Space.xs, left: Space.xs, right: Space.xs })
          .onClick(() => {
            this.quickMed();
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.fingerMed = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.fingerMed = false;
            }
          })
          .focusable(true)
          .accessibilityText('记录用药')
        SymbolGlyph($r('sys.symbol.histogram'))
          .fontSize(FontSize.titleMd)
          .fontColor([this.fingerStats ? DISPLAY_FG : DISPLAY_DIM])
          .padding({ top: Space.xs, bottom: Space.xs, left: Space.sm, right: Space.xs })
          .onClick(() => {
            this.onStats();
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.fingerStats = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.fingerStats = false;
            }
          })
          .focusable(true)
          .accessibilityText('统计')
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(FontSize.titleMd)
          .fontColor([this.fingerSettings ? DISPLAY_FG : DISPLAY_DIM])
          .padding({ top: Space.xs, bottom: Space.xs, left: Space.xs, right: Space.sm })
          .onClick(() => {
            this.onSettings();
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.fingerSettings = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.fingerSettings = false;
            }
          })
          .focusable(true)
          .accessibilityText('设置')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Stack() {
        Canvas(this.waveCtx)
          .width('100%')
          .height('100%')
          .onReady(() => {
            this.waveReady = true;
            this.drawWave();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Center)
      .onAreaChange((_old: Area, _cur: Area) => {
        this.drawWave();
      })

      // 参考图：大号计时为细字径比例无衬线（非等宽），亮白
      Text(this.running ? this.elapsedText() : '00:00:00')
        .fontSize(FontSizeHero.display)
        .fontWeight(FontWeight.light)
        .letterSpacing(LetterSpacing.displayLg)
        .lineHeight(LineHeight.hero)
        .fontColor(this.running ? DISPLAY_FG : DISPLAY_FAINT)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: Space.sm })

      Row({ space: Space.sm }) {
        Text(`咳 ${this.todayCoughs}`)
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.regular)
          .lineHeight(LineHeight.caption)
          .fontColor(DISPLAY_DIM)
        Text(`清嗓 ${this.todayThroatClears}`)
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.regular)
          .lineHeight(LineHeight.caption)
          .fontColor('#3aa981')
        Text(`阵发 ${this.todayBouts}`)
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.regular)
          .lineHeight(LineHeight.caption)
          .fontColor(DISPLAY_DIM)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(60)
    .padding({
      left: Space.lg,
      right: Space.lg,
      top: Space.lg,
      bottom: Space.xl
    })
    .borderRadius(8)
    .backgroundColor(DISPLAY_BG)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: Space.lg }) {
      this.displayBlock()
      this.grille()
      this.controlDeck()
    }
    .width('100%')
    .height('100%')
    .padding({
      top: SafeArea.topInset(this.topSafeArea) + Space.sm,
      bottom: SafeArea.barBottomMargin(this.bottomSafeArea) + Space.sm,
      left: Space.md,
      right: Space.md
    })
    .backgroundColor(this.palette.bgBase)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
