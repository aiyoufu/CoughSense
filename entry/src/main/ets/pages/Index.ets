import { common } from '@kit.AbilityKit';
import { WeatherInfo } from '../weather/WeatherService';
import { MonitorController, UiHooks } from '../monitor/MonitorController';
import { HomeView } from '../view/HomeView';
import { StatsView } from '../view/StatsView';
import { SettingsView } from '../view/SettingsView';
import { ColorPalette } from '../theme/Palette';
import { ThemeManager } from '../theme/ThemeManager';

/**
 * 单页容器:Navigation + NavPathStack 压栈管理全部页面。
 *
 * - 首页为录音机整机面板(参考 Braun 渲染图),底部右列两小键为
 *   统计 / 设置图标按钮,点击 push 对应二级页;
 * - 无底部导航,二级页自带返回头,系统返回手势同样可用。
 */
@Entry
@Component
struct Index {
  @StorageLink('topSafeArea') topSafeArea: number = 0;
  @StorageLink('bottomSafeArea') bottomSafeArea: number = 0;
  @State running: boolean = false;
  @State todayCoughs: number = 0;
  @State todayThroatClears: number = 0;
  @State todayBouts: number = 0;
  @State wavePeakDb: number = 0;
  @State waveSeq: number = 0;
  @State weatherText: string = '';
  @State palette: ColorPalette = ThemeManager.instance.current();
  pageStack: NavPathStack = new NavPathStack();
  private ctrl: MonitorController | null = null;
  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.palette = ThemeManager.instance.current();
    this.unsubscribe = ThemeManager.instance.subscribe((p: ColorPalette) => {
      this.palette = p;
    });
    const hooks: UiHooks = {
      onStatus: (_s: string) => {
        // 首页不显示状态文字
      },
      onEventLine: (_line: string) => {
        // 首页不显示事件日志
      },
      onTodayCounts: (coughs: number, throatClears: number, bouts: number) => {
        this.todayCoughs = coughs;
        this.todayThroatClears = throatClears;
        this.todayBouts = bouts;
      },
      onEventAccepted: (peakDb: number) => {
        this.wavePeakDb = peakDb;
        this.waveSeq++;
      },
      onWeather: (info: WeatherInfo | null) => {
        if (info !== null) {
          this.weatherText =
            `${info.temp.toFixed(0)}℃ 湿度${info.humidity}% · 体感${info.feelsLike.toFixed(0)}℃`;
        }
      },
      onRunningChanged: (r: boolean) => {
        this.running = r;
      },
      onStartFailed: (msg: string) => {
        this.showStartFailed(msg);
      }
    };
    this.ctrl = new MonitorController(hooks);

    setTimeout(() => {
      if (this.ctrl !== null) {
        this.ctrl.maybeAutoStart(this.getUIContext().getHostContext() as common.UIAbilityContext);
      }
    }, 600);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  private showStartFailed(msg: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '无法开始监测',
      message: msg,
      buttons: [
        { text: '知道了', color: this.palette.brand }
      ]
    }).catch(() => {});
  }

  @Builder
  pageMap(name: string) {
    if (name === 'stats') {
      NavDestination() {
        StatsView({
          pageActive: true,
          onBack: () => {
            this.pageStack.pop();
          }
        })
      }
      .hideTitleBar(true)
      .backgroundColor(this.palette.bgBase)
      // 默认布局避让状态栏导致二级页顶部非沉浸、头部偏下;
      // 隐藏标题栏后允许扩展到非安全区,由页面内部 padding 自行避让
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'settings') {
      NavDestination() {
        SettingsView({
          ctrl: this.ctrl,
          onBack: () => {
            this.pageStack.pop();
          }
        })
      }
      .hideTitleBar(true)
      .backgroundColor(this.palette.bgBase)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    }
  }

  build() {
    Navigation(this.pageStack) {
      HomeView({
        running: $running,
        todayCoughs: $todayCoughs,
        todayThroatClears: $todayThroatClears,
        todayBouts: $todayBouts,
        wavePeakDb: $wavePeakDb,
        waveSeq: $waveSeq,
        weather: this.weatherText,
        ctrl: this.ctrl,
        onStats: () => {
          this.pageStack.pushPath({ name: 'stats' });
        },
        onSettings: () => {
          this.pageStack.pushPath({ name: 'settings' });
        }
      })
    }
    .hideTitleBar(true)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.bgBase)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
