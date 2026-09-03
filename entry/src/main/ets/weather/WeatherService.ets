import { geoLocationManager } from '@kit.LocationKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DbManager } from '../data/DbManager';

const DOMAIN = 0x0001;
const TAG = 'ThroatApp[Weather]';

export interface WeatherInfo {
  temp: number;
  feelsLike: number;
  humidity: number;
  weatherCode: number;
  lat: number;
  lon: number;
  ts: number;
}

interface OpenMeteoCurrent {
  temperature_2m?: number;
  apparent_temperature?: number;
  relative_humidity_2m?: number;
  weather_code?: number;
}

interface OpenMeteoResponse {
  current?: OpenMeteoCurrent;
}

export class WeatherService {
  private lastInfo: WeatherInfo | null = null;
  private lastLat: number = 0;
  private lastLon: number = 0;

  getLast(): WeatherInfo | null {
    return this.lastInfo;
  }

  /**
   * 拉取当前天气并落库快照。
   * relocate=false 时复用上次坐标（省电：避免反复触发定位），
   * 仅会话开始时传 true 重新定位。失败时返回缓存（若有）。
   */
  async refresh(db: DbManager, relocate: boolean): Promise<WeatherInfo | null> {
    let lat = 0;
    let lon = 0;
    if (!relocate && this.lastLat !== 0) {
      lat = this.lastLat;
      lon = this.lastLon;
    } else {
      try {
        const req: geoLocationManager.CurrentLocationRequest = {
          priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
          scenario: geoLocationManager.LocationRequestScenario.UNSET,
          maxAccuracy: 0
        };
        const loc = await geoLocationManager.getCurrentLocation(req);
        lat = loc.latitude;
        lon = loc.longitude;
        this.lastLat = lat;
        this.lastLon = lon;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'location failed, use last cache');
        return this.lastInfo;
      }
    }

    try {
      const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat.toFixed(3)}&longitude=${lon.toFixed(3)}` +
        `&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code`;
      const info = await this.fetchOpenMeteo(url, lat, lon);
      this.lastInfo = info;
      await db.insertWeatherSnapshot(info.ts, info.temp, info.feelsLike, info.humidity,
        info.weatherCode, info.lat, info.lon, 'open-meteo');
      hilog.info(DOMAIN, TAG, 'weather ok: %{public}d C', Math.round(info.temp));
      return info;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open-meteo failed');
      return this.lastInfo;
    }
  }

  private fetchOpenMeteo(url: string, lat: number, lon: number): Promise<WeatherInfo> {
    return new Promise<WeatherInfo>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((resp) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          reject(new Error(`http ${resp.responseCode}`));
          return;
        }
        const parsed = JSON.parse(resp.result as string) as OpenMeteoResponse;
        const cur = parsed.current;
        if (cur === undefined || cur.temperature_2m === undefined) {
          reject(new Error('bad payload'));
          return;
        }
        const info: WeatherInfo = {
          temp: cur.temperature_2m,
          feelsLike: cur.apparent_temperature !== undefined ? cur.apparent_temperature : cur.temperature_2m,
          humidity: cur.relative_humidity_2m !== undefined ? cur.relative_humidity_2m : 0,
          weatherCode: cur.weather_code !== undefined ? cur.weather_code : 0,
          lat: lat,
          lon: lon,
          ts: Date.now()
        };
        resolve(info);
      }).catch((e: Error) => {
        req.destroy();
        reject(e);
      });
    });
  }
}
