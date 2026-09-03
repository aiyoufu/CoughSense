import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';
import { FontSize, FontWeight, LineHeight, Radius, Space } from '../theme/Tokens';

const KEY_HEIGHT: number = 56;
const LED: number = 8;
const LED_RADIUS: number = 2;

/**
 * 主操作键板:开始/停止监测。
 * 实色墨色键板(paper 上的 ink 反白),两种状态同一对象:
 *   - 待机 = 墨底 paper 字,方形 LED 只显 paper 色描边(熄);
 *   - 在听 = 同底同字,LED 填充品牌色发光,键板坐下 1vp。
 * 按下再叠 1vp + 轻微降透明度。品牌色只出现在 LED。
 */
@Component
export struct PowerKey {
  @Prop running: boolean = false;
  onToggle: () => void = () => {};
  @State palette: ColorPalette = ThemeManager.instance.current();
  @State fingerDown: boolean = false;
  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubscribe = ThemeManager.instance.subscribe((p: ColorPalette) => {
      this.palette = p;
    });
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
    this.fingerDown = false;
  }

  private caption(): string {
    if (this.running) {
      return '停止监测';
    }
    return '开始监测';
  }

  @Builder
  indicatorLamp() {
    Row()
      .width(LED)
      .height(LED)
      .borderRadius(LED_RADIUS)
      .backgroundColor(this.running ? this.palette.brand : Color.Transparent)
      .border({
        width: 1,
        color: this.running ? this.palette.brand : this.palette.bgBase
      })
      .shadow(this.running ? {
        radius: 6,
        color: this.palette.brand,
        offsetX: 0,
        offsetY: 0
      } : {
        radius: 0,
        color: Color.Transparent,
        offsetX: 0,
        offsetY: 0
      })
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Row({ space: Space.md }) {
      this.indicatorLamp()
      Text(this.caption())
        .fontSize(FontSize.button)
        .fontWeight(FontWeight.regular)
        .lineHeight(LineHeight.bodySm)
        .fontColor(this.palette.bgBase)
        .hitTestBehavior(HitTestMode.None)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(KEY_HEIGHT)
    .backgroundColor(this.palette.textPrimary)
    .borderRadius(Radius.control)
    .opacity(this.fingerDown ? 0.85 : 1)
    .translate({ y: this.running ? 1 : (this.fingerDown ? 1 : 0) })
    .animation({
      duration: 180,
      curve: Curve.EaseOut
    })
    .onClick(() => {
      this.onToggle();
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.fingerDown = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.fingerDown = false;
      }
    })
    .focusable(true)
    .accessibilityText(this.caption())
  }
}
