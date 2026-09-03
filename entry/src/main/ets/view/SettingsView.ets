import { common } from '@kit.AbilityKit';
import { MonitorController, ScheduleRange } from '../monitor/MonitorController';
import { DbManager } from '../data/DbManager';
import { DataExporter } from '../export/DataExporter';
import { ColorPalette } from '../theme/Palette';
import { ThemeManager, ThemeMode } from '../theme/ThemeManager';
import { FontSize, FontWeight, LetterSpacing, LineHeight, Radius, Space } from '../theme/Tokens';
import { SafeArea } from '../theme/SafeArea';
import { TabIconName, tabIconRes } from '../components/TabIcon';
import { ImmersiveBarBg } from '../components/ImmersiveBarBg';

const GROUP_RADIUS: number = 16;
const ROW_HEIGHT: number = 52;
const DIVIDER_INSET: number = 50;

/**
 * 设置页:分组卡片 + 行结构(左图标 / 右说明 + 开关或箭头)
 */
@Component
export struct SettingsView {
  ctrl: MonitorController | null = null;
  onBack: () => void = () => {};
  @StorageLink('topSafeArea') topSafeArea: number = 0;
  @StorageLink('bottomSafeArea') bottomSafeArea: number = 0;
  @State scheduleLines: Array<string> = [];
  @State newStart: string = '22:00';
  @State newEnd: string = '07:00';
  @State autostart: boolean = false;
  @State medInput: string = '';
  @State meds: Array<string> = [];
  @State scheduleOpen: boolean = false;
  @State medsOpen: boolean = false;
  @State themeMode: ThemeMode = 'auto';
  @State topFrosted: boolean = false;
  @State palette: ColorPalette = ThemeManager.instance.current();
  private db: DbManager = DbManager.getInstance();
  private unsubscribe: (() => void) | null = null;
  private readonly timePattern: RegExp = new RegExp('^\\d{1,2}:\\d{2}$');
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
      this.themeMode = ThemeManager.instance.getMode();
    });
    this.themeMode = ThemeManager.instance.getMode();
    setTimeout(() => {
      this.reload();
    }, 0);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  private reload(): void {
    if (this.ctrl !== null) {
      this.ctrl.getSchedules().then((list: Array<ScheduleRange>) => {
        const lines: Array<string> = [];
        for (const r of list) {
          lines.push(`${r.s} - ${r.e}`);
        }
        this.scheduleLines = lines;
      }).catch(() => {});
    }
    this.db.getSetting('autostart').then((v: string | null) => {
      this.autostart = v === '1';
    }).catch(() => {});
    this.loadMeds();
  }

  private loadMeds(): void {
    this.db.getSetting('meds').then((s: string | null) => {
      try {
        this.meds = s !== null ? JSON.parse(s) as Array<string> : [];
      } catch (e) {
        this.meds = [];
      }
    }).catch(() => {});
  }

  private flash(text: string): void {
    this.getUIContext().getPromptAction().showToast({ message: text, duration: 2500 });
  }

  private addSchedule(): void {
    const s = this.newStart.trim();
    const e = this.newEnd.trim();
    if (!this.timePattern.test(s) || !this.timePattern.test(e)) {
      this.flash('时间格式应为 HH:mm');
      return;
    }
    if (this.ctrl === null) {
      return;
    }
    this.ctrl.getSchedules().then((list: Array<ScheduleRange>) => {
      list.push({ s: s, e: e });
      this.ctrl?.saveSchedules(list).then(() => {
        this.scheduleLines.push(`${s} - ${e}`);
        this.flash('已保存:仅在应用前台时生效');
      });
    }).catch(() => {});
  }

  private removeSchedule(index: number): void {
    if (this.ctrl === null) {
      return;
    }
    this.ctrl.getSchedules().then((list: Array<ScheduleRange>) => {
      if (index < list.length) {
        list.splice(index, 1);
      }
      this.ctrl?.saveSchedules(list).then(() => {
        const lines = this.scheduleLines;
        lines.splice(index, 1);
        this.scheduleLines = lines;
      });
    }).catch(() => {});
  }

  private saveMeds(): void {
    this.db.setSetting('meds', JSON.stringify(this.meds)).then(() => {
      this.flash('用药预设已保存');
    });
  }

  private setTheme(mode: ThemeMode): void {
    ThemeManager.instance.setMode(mode);
  }

  private doExportCsv(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const since = Date.now() - 90 * 86400000;
    DataExporter.exportCsv(ctx.filesDir, since).then((path: string) => {
      this.flash(`CSV 已导出:${path.split('/').pop() ?? path}`);
    }).catch(() => {
      this.flash('导出失败');
    });
  }

  private doBackup(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    DataExporter.backupJson(ctx.filesDir).then((path: string) => {
      this.flash(`备份完成:${path.split('/').pop() ?? path}`);
    }).catch(() => {
      this.flash('备份失败');
    });
  }

  private confirmClear(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '清空并重置数据',
      message: '将删除本机全部监测记录、会话、天气与用药记录，并清空录音片段。此操作不可恢复，建议先备份。',
      buttons: [
        { text: '取消', color: this.palette.textSecondary },
        { text: '清空', color: this.palette.danger }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.doClear();
      }
    }).catch(() => {});
  }

  private doClear(): void {
    if (this.ctrl === null) {
      return;
    }
    this.ctrl.clearAllData().then(() => {
      this.flash('已清空全部数据');
    }).catch(() => {
      this.flash('清空失败');
    });
  }

  private indexForMode(mode: ThemeMode): number {
    if (mode === 'dark') {
      return 1;
    }
    if (mode === 'light') {
      return 2;
    }
    return 0;
  }

  private modeForIndex(index: number): ThemeMode {
    if (index === 1) {
      return 'dark';
    }
    if (index === 2) {
      return 'light';
    }
    return 'auto';
  }

  private labelForMode(mode: ThemeMode): string {
    if (mode === 'dark') {
      return '深色';
    }
    if (mode === 'light') {
      return '浅色';
    }
    return '跟随系统';
  }

  private scheduleMeta(): string {
    if (this.scheduleLines.length === 0) {
      return '未设置';
    }
    if (this.scheduleLines.length === 1) {
      return this.scheduleLines[0];
    }
    return `${this.scheduleLines.length} 段`;
  }

  private medsMeta(): string {
    if (this.meds.length === 0) {
      return '未设置';
    }
    if (this.meds.length === 1) {
      return this.meds[0];
    }
    return `${this.meds.length} 种`;
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
  sectionLabel(title: string) {
    Text(title)
      .fontSize(FontSize.bodySm)
      .lineHeight(LineHeight.bodySm)
      .fontColor(this.palette.textTertiary)
      .width('100%')
      .padding({ left: Space.sm, top: Space.lg, bottom: Space.sm })
  }

  @Builder
  rowIcon(name: TabIconName) {
    SymbolGlyph(tabIconRes(name, false))
      .fontSize(20)
      .fontColor([this.palette.textPrimary])
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .width(22)
      .height(22)
  }

  @Builder
  rowChevron(expanded: boolean) {
    SymbolGlyph(tabIconRes(TabIconName.ChevronRight))
      .fontSize(14)
      .fontColor([this.palette.textTertiary])
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .rotate({ angle: expanded ? 90 : 0 })
  }

  @Builder
  rowDivider() {
    Divider()
      .strokeWidth(1)
      .color(this.palette.divider)
      .margin({ left: DIVIDER_INSET })
  }

  @Builder
  rowTitle(title: string) {
    Text(title)
      .fontSize(FontSize.bodyMd)
      .lineHeight(LineHeight.bodyMd)
      .fontColor(this.palette.textPrimary)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(1)
      .margin({ left: Space.md })
  }

  @Builder
  rowMeta(text: string) {
    Text(text)
      .fontSize(FontSize.caption)
      .lineHeight(LineHeight.caption)
      .fontColor(this.palette.textTertiary)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 140 })
      .margin({ right: Space.sm })
  }

  @Builder
  outlineButton(label: string, onTap: () => void) {
    Button(label)
      .height(36)
      .fontSize(FontSize.button)
      .fontWeight(FontWeight.regular)
      .borderRadius(Radius.pill)
      .backgroundColor(this.palette.bgBase)
      .fontColor(this.palette.textPrimary)
      .border({ width: 1, color: this.palette.divider })
      .onClick(() => {
        onTap();
      })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column() {
        this.sectionLabel('监测')
        Column() {
          Row() {
            this.rowIcon(TabIconName.Clock)
            this.rowTitle('监测时段')
            this.rowMeta(this.scheduleMeta())
            this.rowChevron(this.scheduleOpen)
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.scheduleOpen = !this.scheduleOpen;
          })

          if (this.scheduleOpen) {
            Column({ space: Space.xs }) {
              Text('支持跨午夜,仅在应用前台时自动启停')
                .fontSize(FontSize.caption)
                .lineHeight(LineHeight.caption)
                .fontColor(this.palette.textTertiary)
                .width('100%')
              if (this.scheduleLines.length === 0) {
                Text('暂未设置')
                  .fontSize(FontSize.caption)
                  .lineHeight(LineHeight.caption)
                  .fontColor(this.palette.textTertiary)
                  .width('100%')
              }
              ForEach(this.scheduleLines, (line: string, index: number) => {
                Row() {
                  Text(line)
                    .fontSize(FontSize.bodySm)
                    .lineHeight(LineHeight.bodySm)
                    .fontColor(this.palette.textPrimary)
                    .layoutWeight(1)
                  Text('删除')
                    .fontSize(FontSize.caption)
                    .lineHeight(LineHeight.caption)
                    .fontColor(this.palette.textTertiary)
                    .padding({ left: Space.sm, top: Space.xs, bottom: Space.xs })
                    .onClick(() => {
                      this.removeSchedule(index);
                    })
                }
                .width('100%')
                .height(40)
              }, (line: string, index: number) => `${index}_${line}`)
              Row({ space: Space.sm }) {
                TextInput({ text: this.newStart, placeholder: '开始' })
                  .layoutWeight(1)
                  .height(36)
                  .backgroundColor(this.palette.bgSurfaceAlt)
                  .fontColor(this.palette.textPrimary)
                  .placeholderColor(this.palette.textTertiary)
                  .borderRadius(Radius.sm)
                  .onChange((v: string) => {
                    this.newStart = v;
                  })
                Text('至')
                  .fontSize(FontSize.bodySm)
                  .lineHeight(LineHeight.bodySm)
                  .fontColor(this.palette.textSecondary)
                TextInput({ text: this.newEnd, placeholder: '结束' })
                  .layoutWeight(1)
                  .height(36)
                  .backgroundColor(this.palette.bgSurfaceAlt)
                  .fontColor(this.palette.textPrimary)
                  .placeholderColor(this.palette.textTertiary)
                  .borderRadius(Radius.sm)
                  .onChange((v: string) => {
                    this.newEnd = v;
                  })
                this.outlineButton('添加', () => {
                  this.addSchedule();
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({
              left: Space.lg,
              right: Space.lg,
              bottom: Space.md
            })
            .alignItems(HorizontalAlign.Start)
          }

          this.rowDivider()

          Row() {
            this.rowIcon(TabIconName.ArrowClockwise)
            this.rowTitle('启动即开始监测')
            this.rowMeta('忽略时段')
            Toggle({ type: ToggleType.Switch, isOn: this.autostart })
              .selectedColor(this.palette.textPrimary)
              .onChange((on: boolean) => {
                this.autostart = on;
                this.db.setSetting('autostart', on ? '1' : '0');
              })
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)

          this.rowDivider()

          Row() {
            this.rowIcon(TabIconName.Bell)
            this.rowTitle('原始音频')
            this.rowMeta('正式模式不保存')
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .backgroundColor(this.palette.bgSurface)
        .borderRadius(GROUP_RADIUS)
        .border({ width: 1, color: this.palette.divider })
        .clip(true)
        .alignItems(HorizontalAlign.Start)

        this.sectionLabel('外观')
        Column() {
          Row() {
            this.rowIcon(TabIconName.Brush)
            this.rowTitle('外观主题')
            Select([
              { value: '跟随系统' },
              { value: '深色' },
              { value: '浅色' }
            ])
              .selected(this.indexForMode(this.themeMode))
              .value(this.labelForMode(this.themeMode))
              .controlSize(ControlSize.SMALL)
              .font({ size: FontSize.bodySm })
              .fontColor(this.palette.textPrimary)
              .optionFont({ size: FontSize.bodySm })
              .optionFontColor(this.palette.textPrimary)
              .selectedOptionBgColor(this.palette.bgSurfaceAlt)
              .selectedOptionFontColor(this.palette.textPrimary)
              .onSelect((index: number) => {
                this.setTheme(this.modeForIndex(index));
              })
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .backgroundColor(this.palette.bgSurface)
        .borderRadius(GROUP_RADIUS)
        .border({ width: 1, color: this.palette.divider })
        .clip(true)
        .alignItems(HorizontalAlign.Start)

        this.sectionLabel('用药')
        Column() {
          Row() {
            this.rowIcon(TabIconName.PlusSquare)
            this.rowTitle('用药预设')
            this.rowMeta(this.medsMeta())
            this.rowChevron(this.medsOpen)
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.medsOpen = !this.medsOpen;
          })

          if (this.medsOpen) {
            Column({ space: Space.xs }) {
              Text('首页「记录用药」使用列表中第一个')
                .fontSize(FontSize.caption)
                .lineHeight(LineHeight.caption)
                .fontColor(this.palette.textTertiary)
                .width('100%')
              if (this.meds.length === 0) {
                Text('暂未设置')
                  .fontSize(FontSize.caption)
                  .lineHeight(LineHeight.caption)
                  .fontColor(this.palette.textTertiary)
                  .width('100%')
              }
              ForEach(this.meds, (m: string, medIndex: number) => {
                Row() {
                  Text(m)
                    .fontSize(FontSize.bodySm)
                    .lineHeight(LineHeight.bodySm)
                    .fontColor(this.palette.textPrimary)
                    .layoutWeight(1)
                  Text('删除')
                    .fontSize(FontSize.caption)
                    .lineHeight(LineHeight.caption)
                    .fontColor(this.palette.textTertiary)
                    .onClick(() => {
                      const arr = this.meds;
                      arr.splice(medIndex, 1);
                      this.meds = arr;
                      this.saveMeds();
                    })
                }
                .width('100%')
                .height(40)
              }, (m: string, medIndex: number) => `${m}_${medIndex}`)
              Row({ space: Space.sm }) {
                TextInput({ placeholder: '请输入药品名称', text: this.medInput })
                  .layoutWeight(1)
                  .height(36)
                  .backgroundColor(this.palette.bgSurfaceAlt)
                  .fontColor(this.palette.textPrimary)
                  .placeholderColor(this.palette.textTertiary)
                  .borderRadius(Radius.sm)
                  .onChange((v: string) => {
                    this.medInput = v;
                  })
                this.outlineButton('添加', () => {
                  const name = this.medInput.trim();
                  if (name === '') {
                    return;
                  }
                  const arr = this.meds;
                  arr.push(name);
                  this.meds = arr;
                  this.medInput = '';
                  this.saveMeds();
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding({
              left: Space.lg,
              right: Space.lg,
              bottom: Space.md
            })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .backgroundColor(this.palette.bgSurface)
        .borderRadius(GROUP_RADIUS)
        .border({ width: 1, color: this.palette.divider })
        .clip(true)
        .alignItems(HorizontalAlign.Start)

        this.sectionLabel('数据')
        Column() {
          Row() {
            this.rowIcon(TabIconName.SquareArrowUp)
            this.rowTitle('导出 CSV')
            this.rowMeta('近 90 天')
            this.rowChevron(false)
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.doExportCsv();
          })

          this.rowDivider()

          Row() {
            this.rowIcon(TabIconName.Drive)
            this.rowTitle('备份 JSON')
            this.rowMeta('全量备份')
            this.rowChevron(false)
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.doBackup();
          })

          this.rowDivider()

          Row() {
            SymbolGlyph(tabIconRes(TabIconName.Trash))
              .fontSize(20)
              .fontColor([this.palette.danger])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .width(22)
              .height(22)
            Text('清空并重置数据')
              .fontSize(FontSize.bodyMd)
              .lineHeight(LineHeight.bodyMd)
              .fontColor(this.palette.danger)
              .layoutWeight(1)
              .margin({ left: Space.md })
            this.rowMeta('不可恢复')
          }
          .width('100%')
          .height(ROW_HEIGHT)
          .padding({ left: Space.lg, right: Space.lg })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.confirmClear();
          })
        }
        .width('100%')
        .backgroundColor(this.palette.bgSurface)
        .borderRadius(GROUP_RADIUS)
        .border({ width: 1, color: this.palette.divider })
        .clip(true)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({
        left: Space.lg,
        right: Space.lg,
        top: this.barHeight(),
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
        Text('设置')
          .fontSize(FontSize.displaySm)
          .fontWeight(FontWeight.regular)
          .letterSpacing(LetterSpacing.displaySm)
          .lineHeight(LineHeight.displaySm)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
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
