import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Clip]';

/**
 * 疑似片段留证：环形缓冲保留最近 N 秒原始音频，
 * 触发嗓子不适事件后补录 postSec 秒，拼成 WAV 写入 filesDir/clips/
 */
export class ClipRecorder {
  private ring: Int16Array;
  private ringPos: number = 0;
  private absSamples: number = 0;
  private sampleRate: number;
  private preSec: number;
  private postSec: number;
  private dir: string;

  constructor(sampleRate: number, preSec: number, postSec: number, clipsDir: string) {
    this.sampleRate = sampleRate;
    this.preSec = preSec;
    this.postSec = postSec;
    this.dir = clipsDir;
    const len = Math.floor(sampleRate * (preSec + postSec + 2));
    this.ring = new Int16Array(len);
  }

  push(buffer: ArrayBuffer): void {
    const view = new Int16Array(buffer);
    for (let i = 0; i < view.length; i++) {
      this.ring[this.ringPos] = view[i];
      this.ringPos = (this.ringPos + 1) % this.ring.length;
    }
    this.absSamples += view.length;
  }

  /**
   * 事件触发时调用：postSec 后从环形缓冲截取 [触发前preSec, 触发后postSec] 落盘
   */
  scheduleSave(eventTs: number): void {
    setTimeout(() => {
      this.saveNow();
    }, (this.postSec + 0.3) * 1000);
  }

  private saveNow(): void {
    try {
      const avail = Math.min(this.absSamples, this.ring.length);
      const startAbs = this.absSamples - avail;
      const pcm = new Int16Array(avail);
      for (let i = 0; i < avail; i++) {
        pcm[i] = this.ring[(startAbs + i) % this.ring.length];
      }
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir, true);
      }
      const path = `${this.dir}/throat_${Date.now()}.wav`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.encodeWav(pcm));
      fs.closeSync(file);
      hilog.info(DOMAIN, TAG, 'clip saved: %{public}s', path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clip save failed');
    }
  }

  private encodeWav(pcm: Int16Array): ArrayBuffer {
    const dataLen = pcm.length * 2;
    const buf = new ArrayBuffer(44 + dataLen);
    const v = new DataView(buf);
    const writeStr = (offset: number, s: string): void => {
      for (let i = 0; i < s.length; i++) {
        v.setUint8(offset + i, s.charCodeAt(i));
      }
    };
    writeStr(0, 'RIFF');
    v.setUint32(4, 36 + dataLen, true);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    v.setUint32(16, 16, true);
    v.setUint16(20, 1, true);
    v.setUint16(22, 1, true);
    v.setUint32(24, this.sampleRate, true);
    v.setUint32(28, this.sampleRate * 2, true);
    v.setUint16(32, 2, true);
    v.setUint16(34, 16, true);
    writeStr(36, 'data');
    v.setUint32(40, dataLen, true);
    let off = 44;
    for (let i = 0; i < pcm.length; i++) {
      v.setInt16(off, pcm[i], true);
      off += 2;
    }
    return buf;
  }
}
