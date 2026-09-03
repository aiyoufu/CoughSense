import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Db]';

const OLD_EVENT_TABLE = 'cough_event';
const NEW_EVENT_TABLE = 'throat_event';
const OLD_DB_NAME = 'cough.db';
const NEW_DB_NAME = 'throat.db';

const SQL_CREATE_EVENT = `
  CREATE TABLE IF NOT EXISTS throat_event (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,
    duration_ms   INTEGER NOT NULL,
    peak_db       REAL NOT NULL,
    score         REAL DEFAULT 0,
    session_id    INTEGER,
    bout_id       INTEGER NOT NULL DEFAULT 0,
    is_bout_start INTEGER DEFAULT 0,
    note          TEXT,
    cloud_synced  INTEGER DEFAULT 0,
    event_type    TEXT,
    target_confidence REAL DEFAULT 0,
    quality_flags INTEGER DEFAULT 0,
    algorithm_version TEXT DEFAULT 'legacy'
  )`;
const SQL_CREATE_SESSION = `
  CREATE TABLE IF NOT EXISTS listen_session (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    start_ts     INTEGER NOT NULL,
    end_ts       INTEGER,
    end_reason   TEXT,
    cloud_synced INTEGER DEFAULT 0
  )`;
const SQL_CREATE_WEATHER = `
  CREATE TABLE IF NOT EXISTS weather_snapshot (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,
    temp         REAL,
    feels_like   REAL,
    humidity     INTEGER,
    weather_code INTEGER,
    lat          REAL,
    lon          REAL,
    source       TEXT DEFAULT 'open-meteo',
    cloud_synced INTEGER DEFAULT 0
  )`;
const SQL_CREATE_MED = `
  CREATE TABLE IF NOT EXISTS medication_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,
    drug         TEXT NOT NULL,
    dose         TEXT,
    note         TEXT,
    cloud_synced INTEGER DEFAULT 0
  )`;
const SQL_CREATE_SETTINGS = `
  CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`;

export interface EventRow {
  id: number;
  ts: number;
  durationMs: number;
  peakDb: number;
  sessionId: number;
  boutId: number;
  isBoutStart: boolean;
  score: number;
  eventType: string;
  targetConfidence: number;
  qualityFlags: number;
  algorithmVersion: string;
}

export interface DailyCount {
  day: string;
  peaks: number;
  bouts: number;
  coughs: number;
  throatClears: number;
}

export interface HourCount {
  hour: number;
  peaks: number;
  bouts: number;
  coughs: number;
  throatClears: number;
}

export interface TodayCounts {
  peaks: number;
  bouts: number;
  coughs: number;
  throatClears: number;
}

export interface EventWithContext {
  id: number;
  ts: number;
  durationMs: number;
  peakDb: number;
  boutId: number;
  note: string;
  eventType: string | null;
  score: number;
  temp: number | null;
  humidity: number | null;
  weatherCode: number | null;
}

export interface MedRow {
  id: number;
  ts: number;
  drug: string;
  dose: string;
}

export interface WeatherPoint {
  ts: number;
  temp: number;
  humidity: number;
}

export class DbManager {
  private static inst: DbManager | null = null;

  static getInstance(): DbManager {
    if (DbManager.inst === null) {
      DbManager.inst = new DbManager();
    }
    return DbManager.inst;
  }

  private constructor() {
  }

  private store: relationalStore.RdbStore | null = null;
  private eventQueue: relationalStore.ValuesBucket[] = [];
  private flushTimerId: number = -1;

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: NEW_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.store.executeSql(SQL_CREATE_EVENT);
    await this.ensureEventColumns();
    const probe = await this.store.querySql(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [OLD_EVENT_TABLE]);
    if (probe.goToFirstRow()) {
      probe.close();
      await this.store.executeSql(
        `INSERT INTO ${NEW_EVENT_TABLE}
         (ts, duration_ms, peak_db, score, session_id, bout_id, is_bout_start, note, cloud_synced,
          event_type, target_confidence, quality_flags, algorithm_version)
         SELECT ts, duration_ms, peak_db, score, session_id, bout_id, is_bout_start, note, cloud_synced,
                NULL, 0, 0, 'legacy'
         FROM ${OLD_EVENT_TABLE}`);
      await this.store.executeSql(`DROP TABLE ${OLD_EVENT_TABLE}`);
      hilog.info(DOMAIN, TAG, 'legacy cough events migrated as unclassified');
    } else {
      probe.close();
    }
    await this.store.executeSql(SQL_CREATE_SESSION);
    await this.store.executeSql(SQL_CREATE_WEATHER);
    await this.store.executeSql(SQL_CREATE_MED);
    await this.store.executeSql(SQL_CREATE_SETTINGS);
    hilog.info(DOMAIN, TAG, 'rdb init ok');
  }

  private async ensureEventColumns(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const columns = new Set<string>();
    const rs = await this.store.querySql(`PRAGMA table_info(${NEW_EVENT_TABLE})`);
    while (rs.goToNextRow()) {
      columns.add(rs.getString(rs.getColumnIndex('name')));
    }
    rs.close();
    if (!columns.has('event_type')) {
      await this.store.executeSql(`ALTER TABLE ${NEW_EVENT_TABLE} ADD COLUMN event_type TEXT`);
    }
    if (!columns.has('target_confidence')) {
      await this.store.executeSql(`ALTER TABLE ${NEW_EVENT_TABLE} ADD COLUMN target_confidence REAL DEFAULT 0`);
    }
    if (!columns.has('quality_flags')) {
      await this.store.executeSql(`ALTER TABLE ${NEW_EVENT_TABLE} ADD COLUMN quality_flags INTEGER DEFAULT 0`);
    }
    if (!columns.has('algorithm_version')) {
      await this.store.executeSql(`ALTER TABLE ${NEW_EVENT_TABLE} ADD COLUMN algorithm_version TEXT DEFAULT 'legacy'`);
    }
  }

  isReady(): boolean {
    return this.store !== null;
  }

  // ---------- 设置 KV ----------
  async getSetting(key: string): Promise<string | null> {
    if (this.store === null) {
      return null;
    }
    const pred = new relationalStore.RdbPredicates('settings');
    pred.equalTo('key', key);
    const rs = await this.store.query(pred, ['value']);
    let v: string | null = null;
    if (rs.goToFirstRow()) {
      v = rs.getString(rs.getColumnIndex('value'));
    }
    rs.close();
    return v;
  }

  async setSetting(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = { 'key': key, 'value': value };
    await this.store.insert('settings', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  // ---------- 不适事件（队列 + 批量落库） ----------
  enqueueEvent(ev: EventRow): void {
    const bucket: relationalStore.ValuesBucket = {
      'ts': ev.ts,
      'duration_ms': ev.durationMs,
      'peak_db': ev.peakDb,
      'score': ev.score,
      'session_id': ev.sessionId,
      'bout_id': ev.boutId,
      'is_bout_start': ev.isBoutStart ? 1 : 0,
      'event_type': ev.eventType,
      'target_confidence': ev.targetConfidence,
      'quality_flags': ev.qualityFlags,
      'algorithm_version': ev.algorithmVersion
    };
    this.eventQueue.push(bucket);
    if (this.eventQueue.length >= 5) {
      this.flushEvents();
      return;
    }
    if (this.flushTimerId === -1) {
      this.flushTimerId = setTimeout(() => {
        this.flushTimerId = -1;
        this.flushEvents();
      }, 3000);
    }
  }

  async flushEvents(): Promise<void> {
    if (this.store === null || this.eventQueue.length === 0) {
      return;
    }
    const batch = this.eventQueue;
    this.eventQueue = [];
    try {
      await this.store.batchInsert('throat_event', batch);
      hilog.info(DOMAIN, TAG, 'flushed %{public}d events', batch.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'flushEvents failed');
      for (const b of batch) {
        this.eventQueue.push(b);
      }
    }
  }

  // ---------- 监听会话 ----------
  async startSession(startTs: number): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const bucket: relationalStore.ValuesBucket = { 'start_ts': startTs };
    const rowId = await this.store.insert('listen_session', bucket);
    hilog.info(DOMAIN, TAG, 'session #%{public}d started', rowId);
    return rowId;
  }

  async closeSession(sessionId: number, endTs: number, reason: string): Promise<void> {
    if (this.store === null || sessionId <= 0) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('listen_session');
    pred.equalTo('id', sessionId);
    const bucket: relationalStore.ValuesBucket = { 'end_ts': endTs, 'end_reason': reason };
    await this.store.update(bucket, pred);
  }

  // ---------- 天气快照 ----------
  async insertWeatherSnapshot(ts: number, temp: number, feelsLike: number,
    humidity: number, weatherCode: number, lat: number, lon: number, source: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'ts': ts,
      'temp': temp,
      'feels_like': feelsLike,
      'humidity': humidity,
      'weather_code': weatherCode,
      'lat': lat,
      'lon': lon,
      'source': source
    };
    await this.store.insert('weather_snapshot', bucket);
  }

  // ---------- 事件备注 ----------
  async updateEventNote(id: number, note: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('throat_event');
    pred.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'note': note };
    await this.store.update(bucket, pred);
    hilog.info(DOMAIN, TAG, 'event #%{public}d note updated', id);
  }

  // ---------- 用药 ----------
  async insertMedication(ts: number, drug: string, dose: string): Promise<void> {    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = { 'ts': ts, 'drug': drug, 'dose': dose };
    await this.store.insert('medication_log', bucket);
  }

  async listMedications(limit: number): Promise<MedRow[]> {
    if (this.store === null) {
      return [];
    }
    const rs = await this.store.querySql(
      'SELECT id, ts, drug, dose FROM medication_log ORDER BY ts DESC LIMIT ?', [limit]);
    const out: MedRow[] = [];
    while (rs.goToNextRow()) {
      out.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        ts: rs.getLong(rs.getColumnIndex('ts')),
        drug: rs.getString(rs.getColumnIndex('drug')),
        dose: rs.isColumnNull(rs.getColumnIndex('dose')) ? '' : rs.getString(rs.getColumnIndex('dose'))
      });
    }
    rs.close();
    return out;
  }

  // ---------- 清空重置 ----------
  /** 清空全部业务数据（事件/会话/天气/用药）。保留 settings 表的用户配置 */
  async clearAllData(): Promise<void> {
    if (this.store === null) {
      return;
    }
    this.eventQueue = [];
    if (this.flushTimerId !== -1) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = -1;
    }
    await this.store.executeSql('DELETE FROM throat_event');
    await this.store.executeSql('DELETE FROM listen_session');
    await this.store.executeSql('DELETE FROM weather_snapshot');
    await this.store.executeSql('DELETE FROM medication_log');
    hilog.info(DOMAIN, TAG, 'all business data cleared');
  }

  // ---------- 统计查询 ----------
  async dailyCounts(days: number): Promise<DailyCount[]> {
    if (this.store === null) {
      return [];
    }
    const start = Date.now() - days * 86400000;
    const rs = await this.store.querySql(
      `SELECT strftime('%Y-%m-%d', ts/1000.0, 'unixepoch', 'localtime') AS d,
              COUNT(*) AS peaks, COALESCE(SUM(is_bout_start), 0) AS bouts,
              COALESCE(SUM(CASE WHEN event_type='cough' THEN 1 ELSE 0 END), 0) AS coughs,
              COALESCE(SUM(CASE WHEN event_type='throat_clear' THEN 1 ELSE 0 END), 0) AS throat_clears
       FROM throat_event WHERE ts >= ? GROUP BY d ORDER BY d`, [start]);
    const out: DailyCount[] = [];
    while (rs.goToNextRow()) {
      out.push({
        day: rs.getString(rs.getColumnIndex('d')),
        peaks: rs.getLong(rs.getColumnIndex('peaks')),
        bouts: rs.getLong(rs.getColumnIndex('bouts')),
        coughs: rs.getLong(rs.getColumnIndex('coughs')),
        throatClears: rs.getLong(rs.getColumnIndex('throat_clears'))
      });
    }
    rs.close();
    return out;
  }

  async hourlyCounts(startTs: number): Promise<HourCount[]> {
    if (this.store === null) {
      return [];
    }
    const rs = await this.store.querySql(
      `SELECT CAST(strftime('%H', ts/1000.0, 'unixepoch', 'localtime') AS INTEGER) AS h,
              COUNT(*) AS peaks, COALESCE(SUM(is_bout_start), 0) AS bouts,
              COALESCE(SUM(CASE WHEN event_type='cough' THEN 1 ELSE 0 END), 0) AS coughs,
              COALESCE(SUM(CASE WHEN event_type='throat_clear' THEN 1 ELSE 0 END), 0) AS throat_clears
       FROM throat_event WHERE ts >= ? GROUP BY h ORDER BY h`, [startTs]);
    const out: HourCount[] = [];
    while (rs.goToNextRow()) {
      out.push({
        hour: rs.getLong(rs.getColumnIndex('h')),
        peaks: rs.getLong(rs.getColumnIndex('peaks')),
        bouts: rs.getLong(rs.getColumnIndex('bouts')),
        coughs: rs.getLong(rs.getColumnIndex('coughs')),
        throatClears: rs.getLong(rs.getColumnIndex('throat_clears'))
      });
    }
    rs.close();
    return out;
  }

  async todayCounts(): Promise<TodayCounts> {
    const todayStart = new Date().setHours(0, 0, 0, 0);
    if (this.store === null) {
      return { peaks: 0, bouts: 0, coughs: 0, throatClears: 0 };
    }
    const rs = await this.store.querySql(
      `SELECT COUNT(*) AS peaks, COALESCE(SUM(is_bout_start), 0) AS bouts,
              COALESCE(SUM(CASE WHEN event_type='cough' THEN 1 ELSE 0 END), 0) AS coughs,
              COALESCE(SUM(CASE WHEN event_type='throat_clear' THEN 1 ELSE 0 END), 0) AS throat_clears
       FROM throat_event WHERE ts >= ?`, [todayStart]);
    const out: TodayCounts = { peaks: 0, bouts: 0, coughs: 0, throatClears: 0 };
    if (rs.goToFirstRow()) {
      out.peaks = rs.getLong(rs.getColumnIndex('peaks'));
      out.bouts = rs.getLong(rs.getColumnIndex('bouts'));
      out.coughs = rs.getLong(rs.getColumnIndex('coughs'));
      out.throatClears = rs.getLong(rs.getColumnIndex('throat_clears'));
    }
    rs.close();
    return out;
  }

  /** 按监听会话起始日归组（跨零点的夜算作开始那晚） */
  async dailyCountsBySession(days: number): Promise<DailyCount[]> {
    if (this.store === null) {
      return [];
    }
    const start = Date.now() - days * 86400000;
    const rs = await this.store.querySql(
      `SELECT strftime('%Y-%m-%d', s.start_ts/1000.0, 'unixepoch', 'localtime') AS d,
              COUNT(*) AS peaks, COALESCE(SUM(e.is_bout_start), 0) AS bouts,
              COALESCE(SUM(CASE WHEN e.event_type='cough' THEN 1 ELSE 0 END), 0) AS coughs,
              COALESCE(SUM(CASE WHEN e.event_type='throat_clear' THEN 1 ELSE 0 END), 0) AS throat_clears
       FROM throat_event e JOIN listen_session s ON e.session_id = s.id
       WHERE e.ts >= ? GROUP BY d ORDER BY d`, [start]);
    const out: DailyCount[] = [];
    while (rs.goToNextRow()) {
      out.push({
        day: rs.getString(rs.getColumnIndex('d')),
        peaks: rs.getLong(rs.getColumnIndex('peaks')),
        bouts: rs.getLong(rs.getColumnIndex('bouts')),
        coughs: rs.getLong(rs.getColumnIndex('coughs')),
        throatClears: rs.getLong(rs.getColumnIndex('throat_clears'))
      });
    }
    rs.close();
    return out;
  }

  async eventsWithContext(limit: number, sinceTs: number): Promise<EventWithContext[]> {
    if (this.store === null) {
      return [];
    }
    const rs = await this.store.querySql(
      `SELECT e.id AS eid, e.ts AS ets, e.duration_ms AS edur, e.peak_db AS epk, e.bout_id AS ebout,
              e.note AS enote, e.event_type AS etype, e.score AS escore,
              w.temp AS wtemp, w.humidity AS whum, w.weather_code AS wcode
       FROM throat_event e
       LEFT JOIN weather_snapshot w
         ON w.ts = (SELECT MAX(ts) FROM weather_snapshot WHERE ts <= e.ts)
       WHERE e.ts >= ?
       ORDER BY e.ts DESC LIMIT ?`, [sinceTs, limit]);
    const out: EventWithContext[] = [];
    while (rs.goToNextRow()) {
      const tempIdx = rs.getColumnIndex('wtemp');
      const humIdx = rs.getColumnIndex('whum');
      const codeIdx = rs.getColumnIndex('wcode');
      const noteIdx = rs.getColumnIndex('enote');
      const typeIdx = rs.getColumnIndex('etype');
      out.push({
        id: rs.getLong(rs.getColumnIndex('eid')),
        ts: rs.getLong(rs.getColumnIndex('ets')),
        durationMs: rs.getLong(rs.getColumnIndex('edur')),
        peakDb: rs.getDouble(rs.getColumnIndex('epk')),
        boutId: rs.getLong(rs.getColumnIndex('ebout')),
        note: rs.isColumnNull(noteIdx) ? '' : rs.getString(noteIdx),
        eventType: rs.isColumnNull(typeIdx) ? null : rs.getString(typeIdx),
        score: rs.getDouble(rs.getColumnIndex('escore')),
        temp: rs.isColumnNull(tempIdx) ? null : rs.getDouble(tempIdx),
        humidity: rs.isColumnNull(humIdx) ? null : rs.getLong(humIdx),
        weatherCode: rs.isColumnNull(codeIdx) ? null : rs.getLong(codeIdx)
      });
    }
    rs.close();
    return out;
  }

  /** 有效监听分钟数（会话时长求和，进行中的会话算到现在） */
  async hourHistogram(sinceTs: number): Promise<Array<number>> {
    const out: Array<number> = [];
    for (let i = 0; i < 24; i++) {
      out.push(0);
    }
    if (this.store === null) {
      return out;
    }
    const rs = await this.store.querySql(
      `SELECT CAST(strftime('%H', ts/1000.0, 'unixepoch', 'localtime') AS INTEGER) AS h,
              COUNT(*) AS c
       FROM throat_event WHERE ts >= ? GROUP BY h`, [sinceTs]);
    while (rs.goToNextRow()) {
      const h = rs.getLong(rs.getColumnIndex('h'));
      if (h >= 0 && h < 24) {
        out[h] = rs.getLong(rs.getColumnIndex('c'));
      }
    }
    rs.close();
    return out;
  }

  async weekdayHistogram(sinceTs: number): Promise<Array<number>> {
    const out: Array<number> = [];
    for (let i = 0; i < 7; i++) {
      out.push(0);
    }
    if (this.store === null) {
      return out;
    }
    const rs = await this.store.querySql(
      `SELECT CAST(strftime('%w', ts/1000.0, 'unixepoch', 'localtime') AS INTEGER) AS w,
              COUNT(*) AS c
       FROM throat_event WHERE ts >= ? GROUP BY w`, [sinceTs]);
    while (rs.goToNextRow()) {
      const w = rs.getLong(rs.getColumnIndex('w'));
      if (w >= 0 && w < 7) {
        out[w] = rs.getLong(rs.getColumnIndex('c'));
      }
    }
    rs.close();
    return out;
  }

  async eventTimestamps(sinceTs: number): Promise<Array<number>> {
    if (this.store === null) {
      return [];
    }
    const rs = await this.store.querySql(
      'SELECT ts FROM throat_event WHERE ts >= ? ORDER BY ts', [sinceTs]);
    const out: Array<number> = [];
    while (rs.goToNextRow()) {
      out.push(rs.getLong(rs.getColumnIndex('ts')));
    }
    rs.close();
    return out;
  }

  async weatherPoints(sinceTs: number): Promise<Array<WeatherPoint>> {
    if (this.store === null) {
      return [];
    }
    const rs = await this.store.querySql(
      `SELECT ts, temp, humidity FROM weather_snapshot
       WHERE ts >= ? AND temp IS NOT NULL ORDER BY ts`, [sinceTs - 86400000]);
    const out: Array<WeatherPoint> = [];
    while (rs.goToNextRow()) {
      const tempIdx = rs.getColumnIndex('temp');
      const humIdx = rs.getColumnIndex('humidity');
      const point: WeatherPoint = {
        ts: rs.getLong(rs.getColumnIndex('ts')),
        temp: rs.isColumnNull(tempIdx) ? Number.NaN : rs.getDouble(tempIdx),
        humidity: rs.isColumnNull(humIdx) ? -1 : rs.getLong(humIdx)
      };
      out.push(point);
    }
    rs.close();
    return out;
  }

  async listenedMinutes(sinceTs: number): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const now = Date.now();
    const rs = await this.store.querySql(
      `SELECT COALESCE(SUM(CASE WHEN end_ts IS NULL THEN ? - start_ts ELSE end_ts - start_ts END), 0) AS ms
       FROM listen_session WHERE start_ts >= ?`, [now, sinceTs]);
    let minutes = 0;
    if (rs.goToFirstRow()) {
      minutes = Math.round(rs.getLong(rs.getColumnIndex('ms')) / 60000);
    }
    rs.close();
    return minutes;
  }

  /** 备份用：整表导出（原始列名）。列类型按表静态声明，兼容 API12 */
  async dumpTable(table: string): Promise<Array<Record<string, Object>>> {
    const cols = TABLE_COL_SPECS.get(table);
    if (this.store === null || cols === undefined) {
      return [];
    }
    const rs = await this.store.querySql(`SELECT * FROM ${table} ORDER BY id`);
    const out: Array<Record<string, Object>> = [];
    while (rs.goToNextRow()) {
      const row: Record<string, Object> = {};
      for (const c of cols) {
        const idx = rs.getColumnIndex(c.name);
        if (rs.isColumnNull(idx)) {
          row[c.name] = '';
        } else if (c.kind === 'long') {
          row[c.name] = rs.getLong(idx);
        } else if (c.kind === 'double') {
          row[c.name] = rs.getDouble(idx);
        } else {
          row[c.name] = rs.getString(idx);
        }
      }
      out.push(row);
    }
    rs.close();
    return out;
  }
}

interface ColSpec {
  name: string;
  kind: string; // 'long' | 'double' | 'string'
}

function buildColSpecs(): Map<string, Array<ColSpec>> {
  const m = new Map<string, Array<ColSpec>>();
  const eventCols: Array<ColSpec> = [
    { name: 'id', kind: 'long' },
    { name: 'ts', kind: 'long' },
    { name: 'duration_ms', kind: 'long' },
    { name: 'peak_db', kind: 'double' },
    { name: 'score', kind: 'double' },
    { name: 'session_id', kind: 'long' },
    { name: 'bout_id', kind: 'long' },
    { name: 'is_bout_start', kind: 'long' },
    { name: 'note', kind: 'string' },
    { name: 'cloud_synced', kind: 'long' },
    { name: 'event_type', kind: 'string' },
    { name: 'target_confidence', kind: 'double' },
    { name: 'quality_flags', kind: 'long' },
    { name: 'algorithm_version', kind: 'string' }
  ];
  const sessionCols: Array<ColSpec> = [
    { name: 'id', kind: 'long' },
    { name: 'start_ts', kind: 'long' },
    { name: 'end_ts', kind: 'long' },
    { name: 'end_reason', kind: 'string' },
    { name: 'cloud_synced', kind: 'long' }
  ];
  const weatherCols: Array<ColSpec> = [
    { name: 'id', kind: 'long' },
    { name: 'ts', kind: 'long' },
    { name: 'temp', kind: 'double' },
    { name: 'feels_like', kind: 'double' },
    { name: 'humidity', kind: 'long' },
    { name: 'weather_code', kind: 'long' },
    { name: 'lat', kind: 'double' },
    { name: 'lon', kind: 'double' },
    { name: 'source', kind: 'string' },
    { name: 'cloud_synced', kind: 'long' }
  ];
  const medCols: Array<ColSpec> = [
    { name: 'id', kind: 'long' },
    { name: 'ts', kind: 'long' },
    { name: 'drug', kind: 'string' },
    { name: 'dose', kind: 'string' },
    { name: 'note', kind: 'string' },
    { name: 'cloud_synced', kind: 'long' }
  ];
  m.set('throat_event', eventCols);
  m.set('listen_session', sessionCols);
  m.set('weather_snapshot', weatherCols);
  m.set('medication_log', medCols);
  return m;
}

const TABLE_COL_SPECS: Map<string, Array<ColSpec>> = buildColSpecs();
