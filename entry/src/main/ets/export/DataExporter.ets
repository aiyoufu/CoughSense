import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbManager } from '../data/DbManager';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Export]';

class BackupFile {
  version: number = 2;
  exportedAt: string = '';
  throat_event: Array<Record<string, Object>> = [];
  listen_session: Array<Record<string, Object>> = [];
  weather_snapshot: Array<Record<string, Object>> = [];
  medication_log: Array<Record<string, Object>> = [];
}

/**
 * 数据导出：CSV（事件+天气上下文）与 JSON 全量备份，写入 filesDir/export/
 */
export class DataExporter {
  /**
   * CSV：每行一条嗓子不适事件，含就近天气。返回文件路径
   */
  static async exportCsv(filesDir: string, sinceTs: number): Promise<string> {
    const db = DbManager.getInstance();
    const events = await db.eventsWithContext(1000000, sinceTs);
    const head = 'timestamp_iso,event_type,duration_ms,peak_dbfs,class_confidence,bout_id,temp_c,humidity_pct,weather_code';
    const lines: Array<string> = [head];
    for (const e of events) {
      const eventType = e.eventType === null ? '' : e.eventType;
      const temp = e.temp === null ? '' : e.temp.toFixed(1);
      const hum = e.humidity === null ? '' : String(e.humidity);
      const code = e.weatherCode === null ? '' : String(e.weatherCode);
      lines.push(`${new Date(e.ts).toISOString()},${eventType},${e.durationMs},${e.peakDb},${e.score},${e.boutId},${temp},${hum},${code}`);
    }
    const dir = `${filesDir}/export`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const path = `${dir}/throat_events_${Date.now()}.csv`;
    DataExporter.writeText(path, lines.join('\n') + '\n');
    return path;
  }

  /**
   * JSON 全量备份（四张业务表）。返回文件路径
   */
  static async backupJson(filesDir: string): Promise<string> {
    const db = DbManager.getInstance();
    const backup = new BackupFile();
    backup.exportedAt = new Date().toISOString();
    backup.throat_event = await db.dumpTable('throat_event');
    backup.listen_session = await db.dumpTable('listen_session');
    backup.weather_snapshot = await db.dumpTable('weather_snapshot');
    backup.medication_log = await db.dumpTable('medication_log');
    const dir = `${filesDir}/export`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const path = `${dir}/backup_${Date.now()}.json`;
    DataExporter.writeText(path, JSON.stringify(backup));
    return path;
  }

  private static writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
    hilog.info(DOMAIN, TAG, 'written %{public}s', path);
  }
}
