import { DbManager, DailyCount, HourCount } from '../data/DbManager';

export interface ReportSummary {
  days: number;
  totalPeaks: number;
  totalCoughs: number;
  totalThroatClears: number;
  totalBouts: number;
  avgBoutsPerDay: number;
  listenedMinutes: number;
  bestHourText: string;
  generatedAt: number;
}

export interface BucketStat {
  label: string;
  peaks: number;
}

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function tempRangeLabel(t: number): string {
  if (t < 5) return '<5℃';
  if (t < 10) return '5-10℃';
  if (t < 15) return '10-15℃';
  if (t < 20) return '15-20℃';
  if (t < 25) return '20-25℃';
  return '≥25℃';
}

function humidityRangeLabel(h: number): string {
  if (h < 40) return '<40%';
  if (h < 60) return '40-60%';
  if (h < 80) return '60-80%';
  return '≥80%';
}

/**
 * 统计聚合与诱因分析（数据量个人级，内存分桶即可）
 */
export class StatsService {
  private db: DbManager;

  constructor() {
    this.db = DbManager.getInstance();
  }

  async daily(days: number): Promise<DailyCount[]> {
    return this.db.dailyCounts(days);
  }

  async hourly(sinceTs: number): Promise<HourCount[]> {
    return this.db.hourlyCounts(sinceTs);
  }

  async report(days: number): Promise<ReportSummary> {
    const since = Date.now() - days * 86400000;
    const packed = await Promise.all([
      this.db.listenedMinutes(since),
      this.db.dailyCounts(days),
      this.db.hourHistogram(since)
    ]);
    const minutes = packed[0];
    const daily = packed[1];
    const hourBuckets = packed[2];
    let bouts = 0;
    let coughs = 0;
    let throatClears = 0;
    let peaks = 0;
    for (const row of daily) {
      bouts += row.bouts;
      coughs += row.coughs;
      throatClears += row.throatClears;
      peaks += row.peaks;
    }
    let bestHour = -1;
    let bestVal = 0;
    for (let h = 0; h < 24; h++) {
      if (hourBuckets[h] > bestVal) {
        bestVal = hourBuckets[h];
        bestHour = h;
      }
    }
    const summary: ReportSummary = {
      days: days,
      totalPeaks: peaks,
      totalCoughs: coughs,
      totalThroatClears: throatClears,
      totalBouts: bouts,
      avgBoutsPerDay: Math.round(bouts / days * 10) / 10,
      listenedMinutes: minutes,
      bestHourText: bestHour >= 0 ? `${String(bestHour).padStart(2, '0')}:00 前后（${bestVal} 次）` : '无数据',
      generatedAt: Date.now()
    };
    return summary;
  }

  /**
   * 诱因分析：按时段/星期/温度区间/湿度区间分组统计事件数
   */
  async triggerAnalysis(days: number): Promise<Map<string, BucketStat[]>> {
    const since = Date.now() - days * 86400000;
    const packed = await Promise.all([
      this.db.hourHistogram(since),
      this.db.weekdayHistogram(since),
      this.db.eventTimestamps(since),
      this.db.weatherPoints(since)
    ]);
    const byHourArr = packed[0];
    const byWeekdayArr = packed[1];
    const stamps = packed[2];
    const weather = packed[3];
    const byWeekday = new Map<string, number>();
    for (let w = 0; w < 7; w++) {
      byWeekday.set(WEEKDAYS[w], byWeekdayArr[w]);
    }
    const byTemp = new Map<string, number>();
    const byHum = new Map<string, number>();
    let wi = 0;
    let lastTemp = Number.NaN;
    let lastHum = -1;
    for (let i = 0; i < stamps.length; i++) {
      const ts = stamps[i];
      while (wi < weather.length && weather[wi].ts <= ts) {
        lastTemp = weather[wi].temp;
        lastHum = weather[wi].humidity;
        wi++;
      }
      if (!Number.isNaN(lastTemp)) {
        const tl = tempRangeLabel(lastTemp);
        byTemp.set(tl, (byTemp.get(tl) ?? 0) + 1);
      }
      if (lastHum >= 0) {
        const hl = humidityRangeLabel(lastHum);
        byHum.set(hl, (byHum.get(hl) ?? 0) + 1);
      }
    }

    const result = new Map<string, BucketStat[]>();

    const hours: Array<BucketStat> = [];
    for (let h = 0; h < 24; h += 3) {
      let sum = 0;
      for (let k = h; k < h + 3 && k < 24; k++) {
        sum += byHourArr[k];
      }
      hours.push(mkBucket(`${String(h).padStart(2, '0')}-${String(Math.min(h + 3, 24)).padStart(2, '0')}时`, sum));
    }
    result.set('按时段', hours);

    const weekOrder = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const weekStats: Array<BucketStat> = [];
    for (const w of weekOrder) {
      weekStats.push(mkBucket(w, byWeekday.get(w) ?? 0));
    }
    result.set('按星期', weekStats);

    const tempOrder = ['<5℃', '5-10℃', '10-15℃', '15-20℃', '20-25℃', '≥25℃'];
    const tempStats: Array<BucketStat> = [];
    for (const t of tempOrder) {
      tempStats.push(mkBucket(t, byTemp.get(t) ?? 0));
    }
    result.set('按温度', tempStats);

    const humOrder = ['<40%', '40-60%', '60-80%', '≥80%'];
    const humStats: Array<BucketStat> = [];
    for (const h of humOrder) {
      humStats.push(mkBucket(h, byHum.get(h) ?? 0));
    }
    result.set('按湿度', humStats);

    return result;
  }
}

function mkBucket(label: string, peaks: number): BucketStat {
  const b: BucketStat = { label: label, peaks: peaks };
  return b;
}
