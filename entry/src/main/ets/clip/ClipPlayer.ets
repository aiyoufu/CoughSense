import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Player]';

/**
 * 留证片段播放器：单实例 AVPlayer，同一时间只播一个文件
 */
export class ClipPlayer {
  private player: media.AVPlayer | null = null;
  private openFd: number = -1;
  private playingPath: string = '';
  private onStateChanged: ((playing: boolean, path: string) => void) | null = null;

  setListener(cb: (playing: boolean, path: string) => void): void {
    this.onStateChanged = cb;
  }

  isPlaying(path: string): boolean {
    return this.playingPath === path && this.player !== null;
  }

  async toggle(path: string): Promise<void> {
    if (this.isPlaying(path)) {
      await this.stop();
      return;
    }
    await this.play(path);
  }

  async play(path: string): Promise<void> {
    await this.stopInternal();
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      this.openFd = file.fd;
      const p = await media.createAVPlayer();
      this.player = p;
      p.url = `fd://${file.fd}`;
      p.on('stateChange', (state: string) => {
        hilog.info(DOMAIN, TAG, 'state %{public}s', state);
        if (state === 'completed' || state === 'error' || state === 'released') {
          this.playingPath = '';
          if (this.onStateChanged !== null) {
            this.onStateChanged(false, path);
          }
        }
      });
      p.on('error', (err: Error) => {
        hilog.error(DOMAIN, TAG, 'player error');
      });
      await p.prepare();
      await p.play();
      this.playingPath = path;
      if (this.onStateChanged !== null) {
        this.onStateChanged(true, path);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'play failed');
      await this.stopInternal();
    }
  }

  async stop(): Promise<void> {
    const path = this.playingPath;
    await this.stopInternal();
    if (this.onStateChanged !== null) {
      this.onStateChanged(false, path);
    }
  }

  private async stopInternal(): Promise<void> {
    if (this.player !== null) {
      try {
        await this.player.release();
      } catch (e) { /* 忽略 */ }
      this.player = null;
    }
    if (this.openFd >= 0) {
      try {
        fs.closeSync(this.openFd);
      } catch (e) { /* 忽略 */ }
      this.openFd = -1;
    }
    this.playingPath = '';
  }
}
