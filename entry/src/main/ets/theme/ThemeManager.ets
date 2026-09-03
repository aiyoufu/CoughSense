import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { DbManager } from '../data/DbManager';
import { ColorPalette, Palette, LightPalette } from './Palette';

export type ThemeMode = 'auto' | 'dark' | 'light';

/**
 * 主题管理。
 * 支持 dark / light / auto 三档：
 *   - auto：跟随系统 colorMode
 *   - dark/light：强制使用对应色板
 * 修改模式会持久化到 settings 表并通知所有订阅者。
 */
export class ThemeManager {
  private static _inst: ThemeManager = new ThemeManager();
  static get instance(): ThemeManager {
    return this._inst;
  }

  private listeners: Set<(p: ColorPalette) => void> = new Set();
  private initialized: boolean = false;
  private mode: ThemeMode = 'auto';
  private systemIsDark: boolean = false;
  private cachedPalette: ColorPalette = Palette;

  /**
   * 启动时调用(EntryAbility.onCreate)。
   * DB 未初始化时会先 init(幂等,与 MonitorController.start 共用同一个 store)。
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      const db = DbManager.getInstance();
      await db.init(context);

      const saved = await db.getSetting('theme');
      if (saved === 'dark' || saved === 'light' || saved === 'auto') {
        this.mode = saved as ThemeMode;
      } else {
        this.mode = 'auto';
        await db.setSetting('theme', this.mode).catch(() => {});
      }

      this.systemIsDark = this.readSystemDark(context);
      this.cachedPalette = this.computePalette();
    } catch (e) { /* 保持默认深色 */ }
    this.initialized = true;
    this.notify();
  }

  // 系统色彩变化时更新 auto 模式
  onConfigurationUpdate(cfg: object): void {
    try {
      const c = cfg as Configuration;
      this.systemIsDark = c.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      this.cachedPalette = this.computePalette();
      if (this.mode === 'auto') {
        this.notify();
      }
    } catch (e) { /* ignore */ }
  }

  setMode(m: ThemeMode): void {
    if (this.mode === m) {
      return;
    }
    this.mode = m;
    this.cachedPalette = this.computePalette();
    DbManager.getInstance().setSetting('theme', m).catch(() => {});
    this.notify();
  }

  getMode(): ThemeMode {
    return this.mode;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  current(): ColorPalette {
    return this.cachedPalette;
  }

  isDark(): boolean {
    return this.mode === 'auto' ? this.systemIsDark : this.mode === 'dark';
  }

  subscribe(cb: (p: ColorPalette) => void): () => void {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  }

  private computePalette(): ColorPalette {
    const dark = this.mode === 'auto' ? this.systemIsDark : this.mode === 'dark';
    return dark ? Palette : LightPalette;
  }

  private readSystemDark(context: common.UIAbilityContext): boolean {
    try {
      return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
  }

  private notify(): void {
    const p = this.current();
    this.listeners.forEach((cb) => {
      cb(p);
    });
  }
}
