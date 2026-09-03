import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';

/**
 * 沉浸光感材质工具类
 *
 * 参考华为官方文档:
 *   https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-spatiality-immersive
 *   章节:菜单栏适配沉浸光感 / Tabs.barFloatingStyle.systemMaterial
 *
 * 项目使用纯 ArkUI Tabs(无 HdsTabs),走文档「普通组件 / Tabs 开启沉浸光感」路径:
 *   new uiMaterial.ImmersiveMaterial(...) 交给 .barFloatingStyle({ systemMaterial })
 *
 * 行为:
 *   - API 26+ 且设备支持时返回 ImmersiveMaterial
 *   - 不支持时返回 undefined,调用方用 bgSurface 兜底
 */
export class ImmersiveMaterialUtil {
  private static readonly MIN_API: number = 26;

  public static isSupported(): boolean {
    try {
      let ok = false;
      try {
        ok = (deviceInfo.apiAvailable as (v: number) => boolean)(ImmersiveMaterialUtil.MIN_API);
      } catch (e1) {
        // ignore
      }
      if (!ok) {
        try {
          const major = ImmersiveMaterialUtil.MIN_API;
          ok = (deviceInfo.apiAvailable as (v: string) => boolean)(`${major}.0.0`);
        } catch (e2) {
          // ignore
        }
      }
      return ok;
    } catch (e) {
      return false;
    }
  }

  public static buildMaterial(isDark: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isSupported()) {
      return undefined;
    }
    try {
      // 档位对标 go-forward 的 HdsTabs ADAPTIVE 系统策略档(≈GENTLE/SMOOTH)。
      // ULTRA_THIN(≈EXQUISITE)+光效拉满会导致 tab 切换动画期间材质逐帧重采样卡顿,勿升档
      const options: uiMaterial.ImmersiveOptions = {
        style: isDark ? uiMaterial.ImmersiveStyle.THIN : uiMaterial.ImmersiveStyle.REGULAR,
        interactive: false,
        colorInvert: isDark
      };
      return new uiMaterial.ImmersiveMaterial(options);
    } catch (e) {
      return undefined;
    }
  }
}
