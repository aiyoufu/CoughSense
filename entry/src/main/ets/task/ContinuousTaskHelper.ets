import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Task]';

export class ContinuousTaskHelper {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async start(): Promise<void> {
    // bundleName / moduleName / abilityName 必须与实际运行的 Ability 一致，
    // 写死字符串一旦改包名就会报 "Invalid wantAgent object"，故动态取当前 Ability 信息
    const abilityInfo = this.context.abilityInfo;
    const bundleName: string = abilityInfo?.bundleName ?? this.context.applicationInfo.name;
    const moduleName: string = abilityInfo?.moduleName ?? 'entry';
    const abilityName: string = abilityInfo?.name ?? 'EntryAbility';
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: bundleName,
          moduleName: moduleName,
          abilityName: abilityName
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    await backgroundTaskManager.startBackgroundRunning(this.context, ['audioRecording'], agent);
    hilog.info(DOMAIN, TAG, 'continuous task started (audioRecording)');
  }

  async stop(): Promise<void> {
    await backgroundTaskManager.stopBackgroundRunning(this.context);
    hilog.info(DOMAIN, TAG, 'continuous task stopped');
  }
}
