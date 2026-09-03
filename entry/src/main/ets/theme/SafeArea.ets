import { display } from '@kit.ArkUI';

/**
 * 安全区换算与底部悬浮页签预留。
 *
 * 对齐华为最佳实践 bpta-spatiality-immersive:
 *   - 窗口全屏后,避让区高度来自 getWindowAvoidArea,单位 px,需换成 vp
 *   - 悬浮页签 barBottomMargin:有指示条时取其高度,否则 8vp;设计规范抬高 28vp
 *   - 内容区底部预留 = 页签高度 + 底距 + 余量,避免被悬浮栏挡住
 */
export class SafeArea {
  static readonly TAB_BAR_HEIGHT: number = 56;
  static readonly TAB_MASK_HEIGHT: number = 92;
  static readonly TAB_SIDE_MARGIN: number = 16;
  static readonly DEFAULT_TOP: number = 44;
  static readonly DEFAULT_BOTTOM: number = 28;

  static pxToVp(px: number): number {
    if (px <= 0) {
      return 0;
    }
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const density: number = info.densityPixels;
      if (density > 0) {
        return px / density;
      }
    } catch (e) {
      // 无 display 时按 3x 估
    }
    return px / 3;
  }

  static topInset(px: number): number {
    const vp: number = SafeArea.pxToVp(px);
    return vp > 0 ? vp : SafeArea.DEFAULT_TOP;
  }

  static barBottomMargin(indicatorPx: number): number {
    const vp: number = SafeArea.pxToVp(indicatorPx);
    if (vp > SafeArea.DEFAULT_BOTTOM) {
      return vp;
    }
    return SafeArea.DEFAULT_BOTTOM;
  }

  static contentBottom(indicatorPx: number): number {
    return SafeArea.TAB_BAR_HEIGHT + SafeArea.barBottomMargin(indicatorPx) + 12;
  }

  /**
   * 单页容器底部预留(无底部导航后使用):仅指示条高度 + 余量。
   * contentBottom 保留给历史调用,新页面请用 pageBottom。
   */
  static pageBottom(indicatorPx: number): number {
    return SafeArea.barBottomMargin(indicatorPx) + 12;
  }
}
