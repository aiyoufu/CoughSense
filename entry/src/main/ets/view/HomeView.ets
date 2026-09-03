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
const DISPLAY_DOT: string = '#4a4a4c';
// 记录键（目标：淡紫盘 + 白细环 + 珊瑚红芯，三元素纯扁平，无渐变无阴影；
// 状态只变红芯形状，环盘岿然不动）。
const REC_BTN_SIZE: number = 104; // 淡紫盘外径
const REC_RED: string = '#f54e00'; // 波形红线 / 状态点，与统计·设置选中态同色（palette.brand）
const REC_DISC: string = '#e9e2f1'; // 淡紫盘
const REC_DISC_P: string = '#d9cde6'; // 按下盘压暗
const REC_RING: string = '#ffffff'; // 白细环
const REC_RING_D: number = 76; // 环外径（约盘 0.73）
const REC_RING_W: number = 2; // 环笔画
const REC_CORE: string = '#f54e00'; // 主色块：与统计·设置选中态同橙（palette.brand）
const REC_CORE_P: string = '#c24300'; // 按下芯压暗
const REC_CORE_D: number = 30; // 红芯直径（约盘 0.29）
const REC_CORE_SQ_R: number = 7; // 录制态方芯圆角
const KEY_FACE: string = '#e2e1dd';
const KEY_FACE_PRESSED: string = '#d5d4cf';
const KEY_LINE: string = '#151517';
// 点阵：Canvas 自适应绘制的博朗设备开孔（扫地机 grille 同款密点）。
// 列数 = floor(画布实宽 / 间距)，任何屏幕都不会超屏；之前 Row 固定 32 列会撑到 470vp 超出屏幕。
// 颜色取 palette.textTertiary（浅 #807d72 / 深 #8a877d暖灰），深浅主题都柔和。
const GRILLE_DOT: number = 4; // 点径
const GRILLE_PITCH: number = 11; // 点间距（点径 4 + 缝 7，密而不连）
const GRILLE_ROWS_N: number = 6; // 行数
const STRIP_H: number = (GRILLE_ROWS_N - 1) * GRILLE_PITCH + GRILLE_DOT; // 48

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
 * - 黑屏：状态行（时间 + 紧邻的红点状态，右侧天气 + 记录用药💊 / 统计 / 设置图标）
 *   + 弹性波形区（虚线基线贯穿，监测中叠加半高红线与顶端红点）
 *   + 左下大计时 + 瘦计数行；高度已压矮（73→60），底部内边距加大；
 * - 条带：6 行密点阵（直径 4vp、间距 11vp，扫地机开孔密度），
 *   Canvas 按实宽自适应列数、居中，永不超屏，暖灰配色，点击刷新波形；
 * - 键组：淡紫盘 + 白细环 + 珊瑚红芯（闲置 ● / 录制中 ■），直接坐页面底色。
 * 统计 / 设置由 Index 以 Navigation 压栈方式打开，本页只负责回调通知。
 * 记录用药为本地动作（写入数据库 + Toast 提示），不需要回调。
 * 波形只画数据库里的真实事件，无事件就是虚线基线，不造假波形。
 */
@Component
export struct HomeView {
  @Watch('onRunningChanged') @Link running: boolean;
  @Watch('onCountsChanged') @Link todayCoughs: number;
  @Watch('onCountsChanged') @Link todayThroatClears: number;
  @Link todayBouts: number;
  @Prop weather: string = '';
  @StorageLink('topSafeArea') topSafeArea: number = 0;
  @StorageLink('bottomSafeArea') bottomSafeArea: number = 0;
  ctrl: MonitorController | null = null;
  onStats: () => void = () => {};
  onSettings: () => void = () => {};
  @State elapsed: number = 0;
  @State sessionStart: string = '';
  @State waveBars: Array<number> = [];
  @State palette: ColorPalette = ThemeManager.instance.current();
  @State fingerRec: boolean = false;
  @State fingerMed: boolean = false;
  @State fingerStats: boolean = false;
  @State fingerSettings: boolean = false;
  private unsubscribe: (() => void) | null = null;
  private timerId: number = -1;
  private waveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private waveReady: boolean = false;
  private grilleCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private grilleReady: boolean = false;

  aboutToAppear(): void {
    this.unsubscribe = ThemeManager.instance.subscribe((p) => {
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
    this.refreshWave();
  }

  private onCountsChanged(): void {
    this.refreshWave();
  }

  private startTimer(): void {
    this.stopTimer();
    this.sessionStart = fmtClock(new Date());
    this.timerId = setInterval(() => {
      this.elapsed += 1;
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.elapsed = 0;
    this.sessionStart = '';
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

  private async refreshWave(): Promise<void> {
    try {
      const start = new Date().setHours(0, 0, 0, 0);
      const events: Array<EventWithContext> =
        await DbManager.getInstance().eventsWithContext(48, start);
      const ordered = events.slice().reverse();
      this.waveBars = ordered.map((e) => {
        const db = e.peakDb;
        if (db >= 0) {
          return 1;
        }
        if (db <= -60) {
          return 0.15;
        }
        return 0.15 + (1 - 0.15) * ((db + 60) / 60);
      });
    } catch (e) {
      this.waveBars = [];
    }
    this.drawWave();
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
    const mid = h / 2;
    // 虚线基线贯穿整幅（参考图：无事件时也是一条虚线）
    ctx.fillStyle = DISPLAY_DOT;
    let dx = 2;
    while (dx < w - 2) {
      ctx.fillRect(dx, mid - 1, 2, 2);
      dx += 6;
    }
    // 真实事件波形：每个事件展开成一簇高低错落的细亮白条（参考图波形簇），事件间留空隙
    const bars = this.waveBars.slice(0, 40);
    ctx.fillStyle = DISPLAY_FG;
    const shape: Array<number> = [0.4, 0.72, 1.0, 0.55, 0.85, 0.35];
    let x = 4;
    for (let i = 0; i < bars.length; i++) {
      const amp = bars[i] * h * 0.6;
      for (let j = 0; j < shape.length; j++) {
        if (x > w - 10) {
          break;
        }
        const jitter = 0.7 + 0.3 * Math.abs(Math.sin(i * 3.7 + j * 1.9));
        const bh = Math.max(6, amp * shape[j] * jitter);
        ctx.fillRect(x, mid - bh / 2, 2, bh);
        x += 4;
      }
      if (x > w - 10) {
        break;
      }
      x += 6;
    }
    // 录音红线 + 顶端红点（红线约画布一半高、以虚线基线为中心，红点压在顶端）
    if (this.running) {
      const playX = bars.length > 0 ? Math.min(x + 10, w - 8) : Math.round(w * 0.62);
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
        this.refreshWave();
      })
      .focusable(true)
      .accessibilityText('刷新波形')
  }

  @Builder
  recStopCell() {
    // 目标（淡紫盘 + 白细环 + 珊瑚红芯）：三元素纯扁平，无渐变无阴影无 LED；
    // 状态只变红芯：闲置 ●（开始记录）/ 录制中 ■（停止记录），环与盘不动；
    // 按下盘芯同压暗 + 整键缩 0.96。状态另有顶部监测点与下方文案冗余。
    Column({ space: Space.md }) {
      Stack() {
        Row() // 淡紫盘
          .width(REC_BTN_SIZE)
          .height(REC_BTN_SIZE)
          .borderRadius(REC_BTN_SIZE / 2)
          .backgroundColor(this.fingerRec ? REC_DISC_P : REC_DISC)
          .hitTestBehavior(HitTestMode.None)
        Row() // 白细环
          .width(REC_RING_D)
          .height(REC_RING_D)
          .borderRadius(REC_RING_D / 2)
          .backgroundColor(Color.Transparent)
          .border({ width: REC_RING_W, color: REC_RING })
          .hitTestBehavior(HitTestMode.None)
        if (this.running) {
          Row() // ■ 红芯方
            .width(REC_CORE_D)
            .height(REC_CORE_D)
            .borderRadius(REC_CORE_SQ_R)
            .backgroundColor(this.fingerRec ? REC_CORE_P : REC_CORE)
            .hitTestBehavior(HitTestMode.None)
        } else {
          Row() // ● 红芯圆
            .width(REC_CORE_D)
            .height(REC_CORE_D)
            .borderRadius(REC_CORE_D / 2)
            .backgroundColor(this.fingerRec ? REC_CORE_P : REC_CORE)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(REC_BTN_SIZE)
      .height(REC_BTN_SIZE)
      .scale({ x: this.fingerRec ? 0.96 : 1, y: this.fingerRec ? 0.96 : 1 })
      .animation({ duration: 120, curve: Curve.EaseOut })
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
      .focusable(true)
      .accessibilityText(this.running ? '停止记录' : '开始记录')
      Text(this.running ? '停止记录' : '开始记录')
        .fontSize(FontSize.button)
        .fontWeight(FontWeight.regular)
        .letterSpacing(2)
        .lineHeight(LineHeight.bodySm)
        .fontColor(KEY_LINE)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .layoutWeight(2)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // 键组：仅承载淡紫记录键，直接坐页面底色，无任何外壳装饰
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
        if (this.waveBars.length === 0) {
          Text('暂无事件波形')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.regular)
            .lineHeight(LineHeight.caption)
            .fontColor(DISPLAY_FAINT)
        }
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
