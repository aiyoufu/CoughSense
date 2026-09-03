/**
 * 色板两套：浅色按 DESIGN-cursor.md 直接映射；深色为同族暖调推导。
 *
 * 品牌规则（以 DESIGN-cursor.md 为准）：
 * - 浅色：暖奶油画布 #f7f7f4，白卡片 #ffffff，暖近黑文字 #26251e，
 *   层级靠 1px hairline #e6e5e0 与底色/卡面色差，不用阴影
 * - 品牌主色是 Cursor Orange #f54e00，仅用于主 CTA；选中页签用中性 ink/暖白
 * - 深色：由暖墨/奶油的暖调基因推导（暖近黑底 #131210 + 暖柔白文字 #e9e7e2），
 *   主文字不用纯白，柔化高对比
 *
 * 视图侧只通过 ColorPalette 字段取色，禁止在 view 中再硬编码色值。
 */
export interface ColorPalette {
  bgBase: string;        // canvas  页面底
  bgSurface: string;     // surface-card 卡片底
  bgSurfaceAlt: string;  // 输入/嵌套底
  textPrimary: string;   // ink 主文
  textSecondary: string; // body 次文
  textTertiary: string;  // muted 弱化文字
  brand: string;         // 主品牌 / 主 CTA（Cursor Orange）
  brandOn: string;       // 主色上的文字色
  danger: string;        // 危险 / 停止语义
  warn: string;          // 警告 / 关注语义
  accent: string;        // 辅助信息
  divider: string;       // hairline 1px 分隔线
  barTint: string;       // 沉浸光感标题栏·顶部渐变模糊底色(半透明 bgBase)
  tabBarBg: string;      // 悬浮页签胶囊底
  tabItemOn: string;     // 选中页签
  tabItemOff: string;    // 未选中页签
  canvasBarBout: string; // 柱状图·实色柱
  canvasBarPeak: string; // 柱状图·浅色柱
  canvasAxis: string;    // 柱状图·轴与刻度
  keyplateHilite: string; // 键板顶部 1vp 受光高光
  keyplateShadow: string; // 键板接触阴影
}

// ── 深色板（暖深色推导：暖近黑底 + 暖柔白文字，非纯白）──────────────
export const Palette: ColorPalette = {
  bgBase: '#131210',          // 暖近黑画布
  bgSurface: '#1d1c19',       // 暖卡片
  bgSurfaceAlt: '#262521',    // 输入/嵌套，比卡片略亮一档
  textPrimary: '#e9e7e2',     // 暖柔白
  textSecondary: '#c2bfb6',
  textTertiary: '#8a877d',
  brand: '#f54e00',           // Cursor Orange
  brandOn: '#ffffff',
  danger: '#cf2d56',
  warn: '#d99e46',            // 暖金，为深底提亮一档
  accent: '#3aa981',          // 暖绿，为深底提亮一档
  divider: '#2b2a26',
  barTint: '#CC131210',       // 暖近黑 80%:标题栏渐变模糊底
  tabBarBg: '#1d1c19',
  tabItemOn: '#e9e7e2',         // 中性暖白，选中态不再抢视觉中心
  tabItemOff: '#8a877d',

  // 柱状图：实色柱=暖柔白 浅色柱需比卡片底略亮才可见 坐标轴=弱化文字
  canvasBarBout: '#e9e7e2',
  canvasBarPeak: '#34322c',
  canvasAxis: '#8a877d',

  // 键板:深底上提一档,投影用纯黑低透明度
  keyplateHilite: '#2f2e29',
  keyplateShadow: '#80000000',
};

// ── 浅色板（DESIGN-cursor.md 直接映射）──────────────────────────────
export const LightPalette: ColorPalette = {
  bgBase: '#f7f7f4',          // canvas 暖奶油
  bgSurface: '#ffffff',       // surface-card
  bgSurfaceAlt: '#e6e5e0',    // surface-strong 输入/嵌套
  textPrimary: '#26251e',     // ink
  textSecondary: '#5a5852',   // body
  textTertiary: '#807d72',    // muted
  brand: '#f54e00',           // Cursor Orange
  brandOn: '#ffffff',         // on-primary
  danger: '#cf2d56',          // semantic-error
  warn: '#c08532',            // 暖金（原文件 timeline-done）
  accent: '#1f8a65',          // semantic-success
  divider: '#e6e5e0',         // hairline
  barTint: '#CCF7F7F4',       // 暖奶油 80%:标题栏渐变模糊底
  tabBarBg: '#ffffff',
  tabItemOn: '#26251e',         // 中性 ink，选中态不再抢视觉中心
  tabItemOff: '#807d72',

  // 柱状图：实色柱=ink 浅色柱需比卡片底略深才可见 坐标轴=muted
  canvasBarBout: '#26251e',
  canvasBarPeak: '#e6e5e0',
  canvasAxis: '#807d72',

  // 键板:浅键板面上再亮一档的受光,投影用墨色低透明度
  keyplateHilite: '#f0efe9',
  keyplateShadow: '#1f26251e',
};
