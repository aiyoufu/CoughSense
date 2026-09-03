/** 功能开关 */
export class FeatureFlags {
  /** 原始音频默认不落盘；仅显式授权的校准模式可开启 */
  static readonly CLIP_ENABLED: boolean = false;
  /** 片段保留时长（秒，触发前） */
  static readonly CLIP_PRE_SEC: number = 2;
  /** 触发后补录时长（秒） */
  static readonly CLIP_POST_SEC: number = 1.5;
}
