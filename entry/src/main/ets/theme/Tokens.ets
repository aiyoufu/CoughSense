/**
 * 排版 / 圆角 / 间距 tokens
 * 按 DESIGN.md 博朗仪器体系落地。
 *
 * 移动端规则:
 * - weight 以 400 为主,层级靠字号与墨色,不靠加粗
 * - 标题轻微负字距;标签用自然句式,不用 uppercase tracking
 * - 圆角: none / sm(8) / control(14 键板与次操作) / face(18 内嵌表盘) / panel(24 机壳) / pill(单选)
 * - 间距 4px 基准
 * - 计数用等宽数字
 *
 * 字体: HarmonyOS Sans。无 Helvetica 时系统黑体即中性 grotesque。
 */
export class FontSize {
  // 移动端 1-up 容器内的等价标题
  static readonly displayXl: number = 28;   // 96 → 28
  static readonly displayLg: number = 24;   // 72 → 24
  static readonly displayMd: number = 22;   // 48 → 22
  static readonly displaySm: number = 20;   // 32 → 20
  static readonly displayXs: number = 18;   // 20 → 18
  static readonly titleLg: number = 18;
  static readonly titleMd: number = 16;
  static readonly titleSm: number = 15;
  static readonly bodyMd: number = 15;
  static readonly bodySm: number = 14;
  static readonly caption: number = 12;
  static readonly captionMono: number = 12;     // 14 → 12
  static readonly captionMonoSm: number = 11;   // 12 → 11
  static readonly button: number = 14;
  static readonly navLink: number = 14;
}

export class FontWeight {
  // 全站以 400 为主,无 medium / bold;表盘大号读数用 300(BC21 细字径)
  static readonly light: number = 300;
  static readonly regular: number = 400;
}

export class LetterSpacing {
  // display 强负字距;caption-mono 正字距 1.4px
  static readonly displayXl: number = -0.6;
  static readonly displayLg: number = -0.5;
  static readonly displayMd: number = -0.4;
  static readonly displaySm: number = -0.3;
  static readonly displayXs: number = -0.2;
  static readonly captionMono: number = 1.4;
  static readonly captionMonoSm: number = 1.2;
}

export class LineHeight {
  // ArkUI .lineHeight(number) 单位是 vp,不是倍数。传 1.0 会把行盒压成 1vp,文字互相重叠。
  static readonly displayXl: number = 28;
  static readonly displayLg: number = 24;
  static readonly displayMd: number = 26;
  static readonly displaySm: number = 24;
  static readonly displayXs: number = 24;
  static readonly hero: number = 64;
  static readonly bodyLg: number = 24;
  static readonly bodyMd: number = 22;
  static readonly bodySm: number = 20;
  static readonly caption: number = 18;
  static readonly code: number = 20;
}

export class FontSizeHero {
  static readonly display: number = 56;
}

// 圆角:机壳 24 / 内嵌表盘 18 / 键板与次操作 14 / 单选 pill
export class Radius {
  static readonly none: number = 0;
  static readonly sm: number = 8;
  static readonly control: number = 14;
  static readonly face: number = 18;
  static readonly panel: number = 24;
  static readonly pill: number = 9999;
}

// 间距 tokens(4px 基准)
export class Space {
  static readonly xxs: number = 2;
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
  static readonly xxl: number = 32;
  static readonly xxxl: number = 48;
  static readonly section: number = 64;
}
