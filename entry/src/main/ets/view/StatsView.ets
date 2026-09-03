import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';
import { DbManager } from '../data/DbManager';
import { StatsService, ReportSummary, BucketStat } from '../stats/StatsService';
import { FontSize, FontWeight, LetterSpacing, LineHeight, Radius, Space } from '../theme/Tokens';
import { SafeArea } from '../theme/SafeArea';
import { ImmersiveBarBg } from '../components/ImmersiveBarBg';

interface BarItem {
  label: string;
  coughs: number;
  throatClears: number;
}

interface AnalysisBucket {
  label: string;
  peaks: number;
  ratio: number;
  isMax: boolean;
}

interface AnalysisItem {
  title: string;
  buckets: Array<AnalysisBucket>;
}

interface MetricCell {
  label: string;
  value: string;
  unit: string;
}

const EMPTY_SUMMARY: ReportSummary = {
  days: 7,
  totalPeaks: 0,
  totalCoughs: 0,
  totalThroatClears: 0,
  totalBouts: 0,
  avgBoutsPerDay: 0,
  listenedMinutes: 0,
  bestHourText: '无数据',
  generatedAt: 0
};

/**
 * 统计页（紧凑版）：概览 2×2 网格 + 趋势图分段切换 + 诱因分析分段切换。
 * 三张卡片收纳原有全部信息，页面长度约减半。
 */
@Component
export struct StatsView {
  @StorageLink('topSafeArea') topSafeArea: number = 0;
  @StorageLink('bottomSafeArea') bottomSafeArea: number = 0;
  private db: DbManager = DbManager.getInstance();
  private stats: StatsService = new StatsService();
  private ctxChart: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @State hourBars: Array<BarItem> = [];
  @State dayBars: Array<BarItem> = [];
  @State chartMode: number = 0; // 0=今日分时 1=近14天
  @State report: ReportSummary | null = null;
  @State reportMsg: string = '';
  @State analysisItems: Array<AnalysisItem> = [];
  @State analysisIndex: number = 0;
  @State palette: ColorPalette = ThemeManager.instance.current();
  @State topFrosted: boolean = false;
  @Prop @Watch('onPageActive') pageActive: boolean = false;
  onBack: () => void = () => {};
  @StorageLink('dataEpoch') @Watch('onDataEpoch') dataEpoch: number = 0;
  private unsubscribe: (() => void) | null = null;
  private chartReady: boolean = false;
  private scrollVP: number = 0;

  /** 固定顶栏总高:状态栏避让 + 44vp 导航行 */
  private barHeight(): number {
    return SafeArea.topInset(this.topSafeArea) + 44;
  }

  private onScrollDelta(y: number): void {
    this.scrollVP = Math.max(0, this.scrollVP + y);
    const f: boolean = this.scrollVP > 8;
    if (f !== this.topFrosted) {
      this.topFrosted = f;
    }
  }

  aboutToAppear(): void {
    this.unsubscribe = ThemeManager.instance.subscribe((p) => {
      this.palette = p;
      this.redrawChart();
    });
    setTimeout(() => {
      this.refresh();
    }, 0);
  }

  private onPageActive(): void {
    if (this.pageActive) {
      this.refresh();
    }
  }

  private onDataEpoch(): void {
    this.showEmpty();
    this.refresh();
  }

  private showEmpty(): void {
    this.hourBars = [];
    this.dayBars = [];
    this.report = EMPTY_SUMMARY;
    this.reportMsg = '';
    this.analysisItems = [];
    this.redrawChart();
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  private refresh(): void {
    if (!this.db.isReady()) {
      this.report = null;
      this.reportMsg = '先在首页开始一次监测,之后回来查看统计';
      this.analysisItems = [];
      return;
    }
    this.reportMsg = '';
    const todayStart = new Date().setHours(0, 0, 0, 0);
    Promise.all([
      this.stats.hourly(todayStart),
      this.stats.daily(14),
      this.stats.report(7),
      this.stats.triggerAnalysis(14)
    ]).then((results) => {
      const rows = results[0];
      const hourArr: Array<BarItem> = [];
      for (let h = 0; h < 24; h++) {
        let coughs = 0;
        let throatClears = 0;
        for (const r of rows) {
          if (r.hour === h) {
            coughs = r.coughs;
            throatClears = r.throatClears;
          }
        }
        hourArr.push({ label: h % 3 === 0 ? `${h}时` : '', coughs: coughs, throatClears: throatClears });
      }
      const byDay = new Map<string, BarItem>();
      for (const r of results[1]) {
        byDay.set(r.day, {
          label: r.day,
          coughs: r.coughs,
          throatClears: r.throatClears
        });
      }
      const dayArr: Array<BarItem> = [];
      for (let i = 13; i >= 0; i--) {
        const d = new Date(Date.now() - i * 86400000);
        const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
        const hit = byDay.get(key);
        dayArr.push({
          label: i % 2 === 0 ? `${d.getMonth() + 1}/${d.getDate()}` : '',
          coughs: hit !== undefined ? hit.coughs : 0,
          throatClears: hit !== undefined ? hit.throatClears : 0
        });
      }
      const items: Array<AnalysisItem> = [];
      results[3].forEach((buckets: BucketStat[], title: string) => {
        let max = 0;
        for (const b of buckets) {
          max = b.peaks > max ? b.peaks : max;
        }
        const out: Array<AnalysisBucket> = [];
        for (const b of buckets) {
          out.push({
            label: b.label,
            peaks: b.peaks,
            ratio: max > 0 ? b.peaks / max : 0,
            isMax: max > 0 && b.peaks === max
          });
        }
        items.push({ title: title, buckets: out });
      });
      this.hourBars = hourArr;
      this.dayBars = dayArr;
      this.report = results[2];
      this.analysisItems = items;
      this.redrawChart();
    }).catch(() => {
      this.report = null;
      this.reportMsg = '加载失败';
      this.analysisItems = [];
    });
  }

  private summary(): ReportSummary {
    if (this.report === null) {
      return EMPTY_SUMMARY;
    }
    return this.report;
  }

  private generatedDateText(): string {
    const r = this.report;
    if (r === null || r.generatedAt <= 0) {
      return '';
    }
    return new Date(r.generatedAt).toLocaleDateString('zh-CN');
  }

  private hasData(bars: Array<BarItem>): boolean {
    for (const b of bars) {
      if (b.coughs > 0 || b.throatClears > 0) {
        return true;
      }
    }
    return false;
  }

  private currentBars(): Array<BarItem> {
    return this.chartMode === 0 ? this.hourBars : this.dayBars;
  }

  private chartEmptyText(): string {
    return this.chartMode === 0 ? '今日还没有记录' : '近 14 天还没有记录';
  }

  private selectedBuckets(): Array<AnalysisBucket> {
    if (this.analysisIndex >= this.analysisItems.length) {
      return [];
    }
    return this.analysisItems[this.analysisIndex].buckets;
  }

  private dimLabel(title: string): string {
    return title.substring(1); // '按时段' -> '时段'
  }

  private redrawChart(): void {
    if (this.chartReady) {
      this.drawOn(this.ctxChart, this.currentBars());
    }
  }

  private drawOn(ctx: CanvasRenderingContext2D, bars: Array<BarItem>): void {
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0 || bars.length === 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const padB = 16;
    const padT = 12;
    const bh = h - padB - padT;
    const n = bars.length;
    const gap = Math.min(4, w / n * 0.25);
    const bw = (w - gap * (n + 1)) / n;
    let max = 1;
    for (const b of bars) {
      max = b.coughs > max ? b.coughs : max;
      max = b.throatClears > max ? b.throatClears : max;
    }
    ctx.strokeStyle = this.palette.divider;
    ctx.beginPath();
    ctx.moveTo(0, h - padB + 0.5);
    ctx.lineTo(w, h - padB + 0.5);
    ctx.stroke();
    ctx.font = '9px sans-serif';
    ctx.textAlign = 'center';
    for (let i = 0; i < n; i++) {
      const x = gap + i * (bw + gap);
      if (bars[i].coughs > 0) {
        const ph = Math.max(2, bars[i].coughs / max * bh);
        ctx.fillStyle = this.palette.canvasBarPeak;
        ctx.fillRect(x, h - padB - ph, bw * 0.48, ph);
      }
      if (bars[i].throatClears > 0) {
        const th = Math.max(2, bars[i].throatClears / max * bh);
        ctx.fillStyle = this.palette.canvasBarBout;
        ctx.fillRect(x + bw * 0.52, h - padB - th, bw * 0.48, th);
      }
      if (bars[i].label !== '') {
        ctx.fillStyle = this.palette.canvasAxis;
        ctx.fillText(bars[i].label, x + bw / 2, h - 4);
      }
    }
  }

  @Builder
  backButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([this.palette.textPrimary])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .type(ButtonType.Circle)
    .width(36)
    .height(36)
    .backgroundColor(this.palette.bgSurface)
    .border({ width: 1, color: this.palette.divider })
    .onClick(() => {
      this.onBack();
    })
    .accessibilityText('返回')
  }

  @Builder
  metricCell($$: MetricCell) {
    Column({ space: Space.xxs }) {
      Text($$.label)
        .fontSize(FontSize.caption)
        .lineHeight(LineHeight.caption)
        .fontColor(this.palette.textTertiary)
      Row() {
        Text($$.value)
          .fontSize(FontSize.displayMd)
          .fontFamily('monospace')
          .fontWeight(FontWeight.regular)
          .letterSpacing(LetterSpacing.displayMd)
          .lineHeight(LineHeight.displayMd)
          .fontColor(this.palette.textPrimary)
        if ($$.unit !== '') {
          Text($$.unit)
            .fontSize(FontSize.caption)
            .lineHeight(LineHeight.caption)
            .fontColor(this.palette.textSecondary)
            .margin({ left: Space.xs })
        }
      }
      .alignItems(VerticalAlign.Bottom)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  chartLegend() {
    Row({ space: Space.md }) {
      Row({ space: Space.xs }) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(2)
          .backgroundColor(this.palette.canvasBarBout)
          .border({ width: 1, color: this.palette.divider })
        Text('清嗓')
          .fontSize(FontSize.caption)
          .lineHeight(LineHeight.caption)
          .fontColor(this.palette.textTertiary)
      }
      Row({ space: Space.xs }) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(2)
          .backgroundColor(this.palette.canvasBarPeak)
          .border({ width: 1, color: this.palette.divider })
        Text('咳嗽')
          .fontSize(FontSize.caption)
          .lineHeight(LineHeight.caption)
          .fontColor(this.palette.textTertiary)
      }
    }
  }

  @Builder
  chartSeg(label: string, mode: number) {
    Text(label)
      .fontSize(FontSize.button)
      .fontWeight(FontWeight.regular)
      .fontColor(this.chartMode === mode ? this.palette.brandOn : this.palette.textSecondary)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: Space.lg, right: Space.lg })
      .borderRadius(Radius.pill)
      .backgroundColor(this.chartMode === mode ? this.palette.brand : Color.Transparent)
      .border({ width: 1, color: this.chartMode === mode ? this.palette.brand : this.palette.divider })
      .onClick(() => {
        this.chartMode = mode;
        this.redrawChart();
      })
  }

  @Builder
  analysisSeg(item: AnalysisItem, index: number) {
    Text(this.dimLabel(item.title))
      .fontSize(FontSize.button)
      .fontWeight(FontWeight.regular)
      .fontColor(this.analysisIndex === index ? this.palette.brandOn : this.palette.textSecondary)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: Space.lg, right: Space.lg })
      .borderRadius(Radius.pill)
      .backgroundColor(this.analysisIndex === index ? this.palette.brand : Color.Transparent)
      .border({ width: 1, color: this.analysisIndex === index ? this.palette.brand : this.palette.divider })
      .onClick(() => {
        this.analysisIndex = index;
      })
  }

  @Builder
  analysisBars() {
    Column({ space: Space.sm }) {
      ForEach(this.selectedBuckets(), (bucket: AnalysisBucket) => {
        Row({ space: Space.sm }) {
          Text(bucket.label)
            .fontSize(FontSize.caption)
            .lineHeight(LineHeight.caption)
            .fontColor(this.palette.textSecondary)
            .width(60)
          Row() {
            Row()
              .width(`${Math.round(bucket.ratio * 100)}%`)
              .height(6)
              .borderRadius(Radius.pill)
              .backgroundColor(bucket.isMax ? this.palette.textPrimary : this.palette.textTertiary)
          }
          .layoutWeight(1)
          .height(6)
          .borderRadius(Radius.pill)
          .backgroundColor(this.palette.bgSurfaceAlt)
          Text(`${bucket.peaks}`)
            .fontSize(FontSize.captionMonoSm)
            .fontFamily('monospace')
            .fontColor(bucket.isMax ? this.palette.textPrimary : this.palette.textTertiary)
            .width(28)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (bucket: AnalysisBucket) => `${bucket.label}_${bucket.peaks}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column({ space: Space.lg }) {
        // 概览：2×2 网格 + 高发时段，一眼看结论
        Column({ space: Space.md }) {
          Row() {
            Text('近 7 天小结')
              .fontSize(FontSize.titleSm)
              .fontWeight(FontWeight.regular)
              .lineHeight(LineHeight.bodyMd)
              .fontColor(this.palette.textPrimary)
              .layoutWeight(1)
            if (this.generatedDateText() !== '') {
              Text(`截至 ${this.generatedDateText()}`)
                .fontSize(FontSize.caption)
                .lineHeight(LineHeight.caption)
                .fontColor(this.palette.textTertiary)
            }
          }
          .width('100%')

          if (this.reportMsg !== '') {
            Text(this.reportMsg)
              .fontSize(FontSize.bodySm)
              .lineHeight(LineHeight.bodySm)
              .fontColor(this.palette.textSecondary)
              .width('100%')
              .padding({ top: Space.sm, bottom: Space.sm })
          } else if (this.report === null) {
            Text('加载中…')
              .fontSize(FontSize.bodySm)
              .lineHeight(LineHeight.bodySm)
              .fontColor(this.palette.textSecondary)
              .width('100%')
              .padding({ top: Space.sm, bottom: Space.sm })
          } else {
            Column({ space: Space.md }) {
              Row({ space: Space.lg }) {
                this.metricCell({
                  label: '咳嗽总计',
                  value: `${this.summary().totalCoughs}`,
                  unit: '次'
                })
                Divider().vertical(true).height(44).strokeWidth(1).color(this.palette.divider)
                this.metricCell({
                  label: '清嗓总计',
                  value: `${this.summary().totalThroatClears}`,
                  unit: '次'
                })
              }
              .width('100%')

              Divider().strokeWidth(1).color(this.palette.divider)

              Row({ space: Space.lg }) {
                this.metricCell({
                  label: '阵发总计',
                  value: `${this.summary().totalBouts}`,
                  unit: '次'
                })
                Divider().vertical(true).height(44).strokeWidth(1).color(this.palette.divider)
                this.metricCell({
                  label: '有效监测',
                  value: `${Math.floor(this.summary().listenedMinutes / 60)}`,
                  unit: `小时 ${this.summary().listenedMinutes % 60} 分`
                })
              }
              .width('100%')

              Divider().strokeWidth(1).color(this.palette.divider)

              Row() {
                Text('嗓子不适最集中')
                  .fontSize(FontSize.caption)
                  .lineHeight(LineHeight.caption)
                  .fontColor(this.palette.textTertiary)
                  .layoutWeight(1)
                Text(this.summary().bestHourText)
                  .fontSize(FontSize.bodySm)
                  .lineHeight(LineHeight.bodySm)
                  .fontColor(this.palette.textSecondary)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding(Space.lg)
        .borderRadius(Radius.sm)
        .backgroundColor(this.palette.bgSurface)
        .border({ width: 1, color: this.palette.divider })
        .alignItems(HorizontalAlign.Start)

        // 趋势：今日 / 近14天 分段切换，共用一张图
        Column({ space: Space.md }) {
          Row() {
            Text('趋势')
              .fontSize(FontSize.titleSm)
              .fontWeight(FontWeight.regular)
              .lineHeight(LineHeight.bodyMd)
              .fontColor(this.palette.textPrimary)
              .layoutWeight(1)
            this.chartLegend()
          }
          .width('100%')

          Row({ space: Space.xs }) {
            this.chartSeg('今日', 0)
            this.chartSeg('近 14 天', 1)
          }

          Stack({ alignContent: Alignment.Center }) {
            Canvas(this.ctxChart)
              .width('100%')
              .height(132)
              .onReady(() => {
                this.chartReady = true;
                this.redrawChart();
              })
            if (!this.hasData(this.currentBars())) {
              Text(this.chartEmptyText())
                .fontSize(FontSize.caption)
                .lineHeight(LineHeight.caption)
                .fontColor(this.palette.textTertiary)
            }
          }
          .width('100%')
        }
        .width('100%')
        .padding(Space.lg)
        .borderRadius(Radius.sm)
        .backgroundColor(this.palette.bgSurface)
        .border({ width: 1, color: this.palette.divider })
        .alignItems(HorizontalAlign.Start)

        // 诱因分析：时段/星期/温度/湿度 分段切换，一次只看一组
        Column({ space: Space.md }) {
          Row() {
            Text('诱因分析')
              .fontSize(FontSize.titleSm)
              .fontWeight(FontWeight.regular)
              .lineHeight(LineHeight.bodyMd)
              .fontColor(this.palette.textPrimary)
              .layoutWeight(1)
            Text('近 14 天')
              .fontSize(FontSize.caption)
              .lineHeight(LineHeight.caption)
              .fontColor(this.palette.textTertiary)
          }
          .width('100%')

          if (this.analysisItems.length === 0) {
            Text('暂无数据')
              .fontSize(FontSize.bodySm)
              .lineHeight(LineHeight.bodySm)
              .fontColor(this.palette.textSecondary)
              .width('100%')
              .padding({ top: Space.sm, bottom: Space.sm })
          } else {
            Row({ space: Space.xs }) {
              ForEach(this.analysisItems, (item: AnalysisItem, index: number) => {
                this.analysisSeg(item, index)
              }, (item: AnalysisItem) => item.title)
            }

            this.analysisBars()
          }
        }
        .width('100%')
        .padding(Space.lg)
        .borderRadius(Radius.sm)
        .backgroundColor(this.palette.bgSurface)
        .border({ width: 1, color: this.palette.divider })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({
        left: Space.lg,
        right: Space.lg,
        top: this.barHeight() + Space.sm,
        bottom: SafeArea.pageBottom(this.bottomSafeArea)
      })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.palette.bgBase)
      .scrollBar(BarState.Off)
      .onDidScroll((_x: number, y: number, _state: ScrollState) => {
        this.onScrollDelta(y);
      })

      // 沉浸光感顶栏材质:内容滚动时从其下方穿过,渐变模糊由浓到透
      ImmersiveBarBg({ frosted: this.topFrosted, barHeight: this.barHeight() })

      // 固定顶栏:状态栏避让区内收,位置恒定不随内容滚走
      Row({ space: Space.sm }) {
        this.backButton()
        Text('统计')
          .fontSize(FontSize.displaySm)
          .fontWeight(FontWeight.regular)
          .letterSpacing(LetterSpacing.displaySm)
          .lineHeight(LineHeight.displaySm)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Button('刷新')
          .height(36)
          .fontSize(FontSize.button)
          .fontWeight(FontWeight.regular)
          .borderRadius(Radius.pill)
          .backgroundColor(this.palette.bgSurface)
          .fontColor(this.palette.textPrimary)
          .border({ width: 1, color: this.palette.divider })
          .onClick(() => {
            this.refresh();
          })
      }
      .width('100%')
      .height(this.barHeight())
      .padding({
        top: SafeArea.topInset(this.topSafeArea),
        left: Space.lg,
        right: Space.lg
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}
