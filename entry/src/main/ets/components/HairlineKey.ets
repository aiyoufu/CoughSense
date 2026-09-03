import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';
import { FontSize, FontWeight, LineHeight, Radius, Space } from '../theme/Tokens';

const KEY_HEIGHT: number = 52;

/**
 * 次操作键板(记录用药等):画布上的透明 hairline 键。
 * 透明底 + 1px hairline 描边 + ink 文字;按下时垫一层 bgSurface 并下沉 1vp。
 */
@Component
export struct HairlineKey {
  @Prop label: string = '';
  onPress: () => void = () => {};
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

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSize.button)
        .fontWeight(FontWeight.regular)
        .lineHeight(LineHeight.bodySm)
        .fontColor(this.palette.textPrimary)
        .hitTestBehavior(HitTestMode.None)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(KEY_HEIGHT)
    .backgroundColor(this.fingerDown ? this.palette.bgSurface : Color.Transparent)
    .borderRadius(Radius.control)
    .translate({ y: this.fingerDown ? 1 : 0 })
    .animation({
      duration: 180,
      curve: Curve.EaseOut
    })
    .onClick(() => {
      this.onPress();
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.fingerDown = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.fingerDown = false;
      }
    })
    .focusable(true)
    .accessibilityText(this.label)
  }
}
