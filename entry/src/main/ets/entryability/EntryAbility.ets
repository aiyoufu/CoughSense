import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { MonitorController } from '../monitor/MonitorController';
import { ThemeManager } from '../theme/ThemeManager';
import { LightPalette } from '../theme/Palette';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Ability]';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    // 读 DB 里保存的主题（DB 未初始化则先 init，幂等）
    ThemeManager.instance.init(this.context).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'theme init failed: %{public}s', e.message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    MonitorController.emergencyTeardown();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed, code=%{public}d msg=%{public}s', err.code, err.message ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
      try {
        const win = windowStage.getMainWindowSync();
        // 沉浸式：布局延伸至状态栏/导航栏区域，UI 自己用 safe area padding 留白
        // (API 12+ 默认沉浸,此调用为兼容保留,deprecated 仅 WARN)
        win.setWindowLayoutFullScreen(true).catch((e: Error) => {
          hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', e.message);
        });
        // 状态栏 / 导航栏内容色随主题切换;启动时先设置一次,主题变化由订阅回调更新
        this.applySystemBar(win);
        ThemeManager.instance.subscribe(() => {
          this.applySystemBar(win);
        });
        // 安全区写入 AppStorage;avoidAreaChange 覆盖折叠/旋转等变化
        this.updateSafeArea(win);
        win.on('avoidAreaChange', () => {
          this.updateSafeArea(win);
        });
        // 部分机型启动初期 avoid area 尚未就绪,延迟补读一次,
        // 防止页面头部避让长时间退回默认值(表现为标题偏下)
        setTimeout(() => {
          this.updateSafeArea(win);
        }, 300);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setSystemBar failed');
      }
    });
  }

  private applySystemBar(win: window.Window): void {
    const isLight = ThemeManager.instance.current() === LightPalette;
    const contentColor = isLight ? '#000000' : '#FFFFFF';
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: contentColor,
      navigationBarColor: '#00000000',
      navigationBarContentColor: contentColor
    }).catch(() => {});
  }

  private updateSafeArea(win: window.Window): void {
    try {
      const sysArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const topPx: number = Math.max(sysArea.topRect.height, cutout.topRect.height);
      AppStorage.setOrCreate<number>('topSafeArea', topPx);
      const navArea: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomPx: number = Math.max(sysArea.bottomRect.height, navArea.bottomRect.height);
      AppStorage.setOrCreate<number>('bottomSafeArea', bottomPx);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'updateSafeArea failed');
    }
  }

  onWindowStageDestroy(): void {
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate');
    ThemeManager.instance.onConfigurationUpdate(newConfig);
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
