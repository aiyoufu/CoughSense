/**
 * Tab / 设置项图标。使用系统 SymbolGlyph(单色矢量),避免 Unicode/emoji 随字体变色、糊成一团。
 */
export enum TabIconName {
  Home = 'home',
  Stats = 'stats',
  Settings = 'settings',
  ThemeAuto = 'theme_auto',
  ThemeDark = 'theme_dark',
  ThemeLight = 'theme_light',
  Clock = 'clock',
  ArrowClockwise = 'arrow_clockwise',
  Bell = 'bell',
  Brush = 'brush',
  Viewfinder = 'viewfinder',
  PlusSquare = 'plus_square',
  SquareArrowUp = 'square_arrow_up',
  Drive = 'drive',
  ChevronRight = 'chevron_right',
  Checkmark = 'checkmark',
  Trash = 'trash'
}

export interface TabIconOptions {
  size?: number;
  color?: string;
  filled?: boolean;
}

function iconFilled(options?: TabIconOptions): boolean {
  if (options === undefined) {
    return false;
  }
  return options.filled === true;
}

function iconSize(options?: TabIconOptions): number {
  if (options === undefined || options.size === undefined) {
    return 22;
  }
  return options.size;
}

function iconColor(options?: TabIconOptions): string {
  if (options === undefined || options.color === undefined) {
    return '#8a8a8a';
  }
  return options.color;
}

function iconColors(color: string): Array<ResourceColor> {
  const colors: Array<ResourceColor> = [color];
  return colors;
}

export function tabIconRes(name: TabIconName, filled: boolean = false): Resource {
  return iconRes(name, filled);
}

function iconRes(name: TabIconName, filled: boolean): Resource {
  switch (name) {
    case TabIconName.Home:
      return filled ? $r('sys.symbol.house_fill') : $r('sys.symbol.house');
    case TabIconName.Stats:
      return filled ? $r('sys.symbol.histogram_fill') : $r('sys.symbol.histogram');
    case TabIconName.Settings:
      return filled ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape');
    case TabIconName.ThemeAuto:
      return $r('sys.symbol.circle_lefthalf_inset_filled');
    case TabIconName.ThemeDark:
      return filled ? $r('sys.symbol.moon_fill') : $r('sys.symbol.moon');
    case TabIconName.ThemeLight:
      return filled ? $r('sys.symbol.sun_max_fill') : $r('sys.symbol.sun_max');
    case TabIconName.Clock:
      return $r('sys.symbol.clock');
    case TabIconName.ArrowClockwise:
      return $r('sys.symbol.arrow_clockwise');
    case TabIconName.Bell:
      return $r('sys.symbol.bell_fill');
    case TabIconName.Brush:
      return filled ? $r('sys.symbol.brush_fill') : $r('sys.symbol.brush');
    case TabIconName.Viewfinder:
      return $r('sys.symbol.circle_viewfinder');
    case TabIconName.PlusSquare:
      return $r('sys.symbol.plus_square');
    case TabIconName.SquareArrowUp:
      return $r('sys.symbol.arrow_right_up_and_square');
    case TabIconName.Drive:
      return $r('sys.symbol.externaldrive');
    case TabIconName.ChevronRight:
      return $r('sys.symbol.chevron_right');
    case TabIconName.Checkmark:
      return $r('sys.symbol.checkmark');
    case TabIconName.Trash:
      return $r('sys.symbol.trash');
    default:
      return $r('sys.symbol.house');
  }
}

@Builder
export function TabIcon(name: TabIconName, options?: TabIconOptions) {
  SymbolGlyph(iconRes(name, iconFilled(options)))
    .fontSize(iconSize(options))
    .fontColor(iconColors(iconColor(options)))
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
}
