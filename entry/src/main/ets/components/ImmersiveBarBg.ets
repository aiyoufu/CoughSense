import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';

/**
 * 沉浸光感顶栏背景(通透材质 + 渐变模糊)。
 *
 * 对齐官方最佳实践 bpta-spatiality-immersive:
 *   标题栏固定于屏幕顶部(含状态栏避让区),滚动内容从其下方「穿过」,
 *   材质自顶向底由浓到透,模拟 IMMERSIVE_GRADIENT_BLUR 的渐变过渡。
 *
 * 行为:
 *   - 页面停在顶部时整体透明,顶栏与页面背景无缝沉浸;
 *   - 内容滚动后淡入毛玻璃,滚过的内容透过材质隐约可见。
 * 注意:沉浸光感 systemMaterial 在部分真机(如 API 26 VYG-AL00)对普通组件
 * 不生效,故沿用 backgroundBlurStyle + 半透明 tint 渐变兜底。
 * 本层不接收触摸(hitTestBehavior None),点按落回下层滚动内容。
 */
@Component
export struct ImmersiveBarBg {
  @Prop frosted: boolean = false;
  @Prop barHeight: number = 0;
  @State palette: ColorPalette = ThemeManager.instance.current();
  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubscribe = ThemeManager.instance.subscribe((p: ColorPalette) => {
      this.palette = p;
    });
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  build() {
    Column()
      .width('100%')
      .height(this.barHeight)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .linearGradient({
        angle: 180,
        colors: [[this.palette.barTint, 0], ['#00000000', 1]]
      })
      .hitTestBehavior(HitTestMode.None)
      .opacity(this.frosted ? 1 : 0)
      .animation({ duration: 200, curve: Curve.EaseOut })
  }
}
