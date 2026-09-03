import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Audio]';

export type RmsCallback = (rmsLinear: number, blockMs: number, blockStartSample: number) => void;
export type RawBlockCallback = (buffer: ArrayBuffer, blockStartSample: number) => void;
export type InterruptedCallback = () => void;

export class AudioCaptureManager {
  private capturer: audio.AudioCapturer | null = null;
  private sampleRate: number = 16000;
  private absSamples: number = 0;
  private onFrame: RmsCallback | null = null;
  private onRaw: RawBlockCallback | null = null;
  private onInterrupted: InterruptedCallback | null = null;
  private stopping: boolean = false;
  private sessionActive: boolean = false;

  static async create(sampleRate: number, onFrame: RmsCallback | null,
    onRaw?: RawBlockCallback, onInterrupted?: InterruptedCallback): Promise<AudioCaptureManager> {
    const mgr = new AudioCaptureManager();
    mgr.sampleRate = sampleRate;
    mgr.onFrame = onFrame;
    mgr.onRaw = onRaw !== undefined ? onRaw : null;
    mgr.onInterrupted = onInterrupted !== undefined ? onInterrupted : null;

    // HarmonyOS NEXT：建 capturer 之前必须先激活 audio session，
    // 否则 capturer.start() 会抛 6800301（ERR_AUDIO_ENGINE_CREATE_FAILED）
    // 顺序：activateAudioSession → createAudioCapturer → start；释放对称
    try {
      const sessionManager = audio.getAudioManager().getSessionManager();
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT
      };
      await sessionManager.activateAudioSession(strategy);
      mgr.sessionActive = true;
      hilog.info(DOMAIN, TAG, 'audio session activated');
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'activateAudioSession failed: code=%{public}d message=%{public}s',
        be.code, be.message);
      throw new Error(`activateAudioSession failed: code=${be.code} message=${be.message}`);
    }

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    mgr.capturer = await audio.createAudioCapturer(options);
    hilog.info(DOMAIN, TAG, 'capturer created, state=%{public}s', String(mgr.capturer.state));
    return mgr;
  }

  async start(): Promise<void> {
    if (this.capturer === null) {
      throw new Error('capturer not created');
    }
    this.absSamples = 0;
    this.stopping = false;
    this.capturer.on('readData', (buffer: ArrayBuffer) => {
      this.onReadData(buffer);
    });
    this.capturer.on('stateChange', (state: audio.AudioState) => {
      hilog.info(DOMAIN, TAG, 'stateChange -> %{public}s', String(state));
      if (state === audio.AudioState.STATE_STOPPED && !this.stopping) {
        hilog.warn(DOMAIN, TAG, 'capturer stopped unexpectedly (interrupt?)');
        if (this.onInterrupted !== null) {
          this.onInterrupted();
        }
      }
    });
    try {
      await this.capturer.start();
    } catch (e) {
      // 透出原始 BusinessError（HarmonyOS 的 audio 错误通常带 code + message），
      // 否则上层只能看到"capturer.start failed"这层壳，没法定位设备/权限/状态机问题
      const be = e as BusinessError;
      const detail = `code=${String(be.code)} message=${String(be.message)}`;
      hilog.error(DOMAIN, TAG, 'capturer.start failed: %{public}s', detail);
      throw new Error(`capturer.start failed: ${detail}`);
    }
    hilog.info(DOMAIN, TAG, 'capturer started');
  }

  async stop(): Promise<void> {
    if (this.capturer === null && !this.sessionActive) {
      return;
    }
    this.stopping = true;
    if (this.capturer !== null) {
      try {
        this.capturer.off('readData');
        this.capturer.off('stateChange');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'off listeners warn');
      }
      try {
        await this.capturer.stop();
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'capturer.stop warn: code=%{public}d message=%{public}s',
          be.code, be.message);
      }
      try {
        await this.capturer.release();
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'capturer.release warn: code=%{public}d message=%{public}s',
          be.code, be.message);
      }
      this.capturer = null;
    }
    // 释放 audio session（与 create 中的 activate 对称），不释放会导致下次启动报 6800301
    if (this.sessionActive) {
      try {
        const sessionManager = audio.getAudioManager().getSessionManager();
        await sessionManager.deactivateAudioSession();
        hilog.info(DOMAIN, TAG, 'audio session deactivated');
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'deactivateAudioSession warn: code=%{public}d message=%{public}s',
          be.code, be.message);
      }
      this.sessionActive = false;
    }
    hilog.info(DOMAIN, TAG, 'capturer stopped and released');
  }

  isRunning(): boolean {
    return this.capturer !== null;
  }

  private onReadData(buffer: ArrayBuffer): void {
    const view = new Int16Array(buffer);
    if (view.length === 0) {
      return;
    }
    const rawStartSample = this.absSamples;
    if (this.onRaw !== null) {
      this.onRaw(buffer, rawStartSample);
    }
    if (this.onFrame === null) {
      this.absSamples += view.length;
      return;
    }
    // 按 20ms 子块计算包络：清嗓事件只有 150-800ms，
    // 整块 RMS 会把起音/峰值/时长抹平，包络状态机就测不准（甚至全部误拒）
    const subLen: number = Math.max(1, Math.round(this.sampleRate / 50));
    let off = 0;
    while (off < view.length) {
      const n: number = Math.min(subLen, view.length - off);
      let sum = 0;
      for (let i = 0; i < n; i++) {
        const v = view[off + i] / 32768;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / n);
      const blockMs = n / this.sampleRate * 1000;
      const blockStartSample = this.absSamples;
      this.absSamples += n;
      this.onFrame(rms, blockMs, blockStartSample);
      off += n;
    }
  }
}
