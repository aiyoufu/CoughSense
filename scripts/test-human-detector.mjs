// Offline sanity check for HumanSoundDetector. Not shipped with the app.
import { readFileSync } from 'fs';

const src = readFileSync(new URL('../entry/src/main/ets/detector/HumanSoundDetector.ets', import.meta.url), 'utf8');
let js = src
  .replace(/import \{ hilog \} from '@kit\.PerformanceAnalysisKit';\r?\n/, '')
  .replace(/import \{ AcousticEvent, AcousticEventType, AudioQualityFlag \} from '\.\.\/detection\/DetectionTypes';\r?\n/,
    `const AudioQualityFlag = { NONE:0, CLIPPED:1, LOW_SNR:2, TOO_SHORT:4, TOO_LONG:8, TONAL:16, IMPACT:32, SPEECH_LIKE:64, AMBIGUOUS:128 };
const hilog = { info() {} };\n`)
  .replace(/interface FrameFeature \{[\s\S]*?\}\r?\n/, '')
  .replace(/export interface DetectorDecision \{[\s\S]*?\}\r?\n/, '')
  .replace(/let bestType: AcousticEventType/g, 'let bestType')
  .replace(/const event: AcousticEvent =/g, 'const event =')
  .replace(/private /g, '')
  .replace(/export class/g, 'class')
  .replace(/: Array<FrameFeature>/g, '')
  .replace(/: Array<DetectorDecision>/g, '')
  .replace(/: DetectorDecision \| null/g, '')
  .replace(/: DetectorDecision/g, '')
  .replace(/: FrameFeature/g, '')
  .replace(/: Int16Array/g, '')
  .replace(/: Float64Array/g, '')
  .replace(/: Uint32Array/g, '')
  .replace(/: ArrayBuffer/g, '')
  .replace(/: string/g, '')
  .replace(/: boolean/g, '')
  .replace(/: number/g, '')
  .replace(/: void/g, '')
  .replace(/ as AcousticEventType/g, '');

const moduleJs = js + `\nexport { HumanSoundDetector };\n`;
const { HumanSoundDetector } = await import(`data:text/javascript,${encodeURIComponent(moduleJs)}`);

function pcmFrom(samples) {
  return samples.buffer.slice(samples.byteOffset, samples.byteOffset + samples.byteLength);
}

function makeSignal(seconds, fn) {
  const n = Math.round(16000 * seconds);
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / 16000;
    const v = Math.max(-1, Math.min(1, fn(t, i, n)));
    out[i] = Math.round(v * 30000);
  }
  return out;
}

function envelope(t, start, rise, hold, fall) {
  const x = t - start;
  if (x < 0 || x > rise + hold + fall) return 0;
  if (x < rise) return x / rise;
  if (x < rise + hold) return 1;
  return Math.max(0, 1 - (x - rise - hold) / fall);
}

function withLead(samples) {
  const lead = makeSignal(1.7, () => 0.0003 * (Math.random() * 2 - 1));
  const out = new Int16Array(lead.length + samples.length);
  out.set(lead, 0);
  out.set(samples, lead.length);
  return out;
}

function run(name, samples) {
  const det = new HumanSoundDetector();
  const decisions = det.push(pcmFrom(withLead(samples)), 0);
  const accepted = decisions.filter((d) => d.event);
  const rejected = decisions.filter((d) => !d.event);
  console.log(name, {
    decisions: decisions.length,
    accepted: accepted.map((d) => `${d.event.type}/${d.event.durationMs}ms/${d.event.classConfidence}`),
    rejected: rejected.map((d) => d.reason)
  });
  return { accepted, rejected };
}

const silence = makeSignal(1.0, () => 0.0004 * (Math.random() * 2 - 1));
const throat = makeSignal(1.2, (t) => {
  const env = envelope(t, 0.35, 0.08, 0.16, 0.10);
  const voice = Math.sin(2 * Math.PI * 160 * t) + 0.35 * Math.sin(2 * Math.PI * 320 * t) + 0.12 * Math.sin(2 * Math.PI * 480 * t);
  const noise = (Math.random() * 2 - 1) * 0.22;
  return 0.0005 * (Math.random() * 2 - 1) + env * (0.22 * voice + noise * 0.18);
});
let quietLp = 0;
const quietThroat = makeSignal(1.2, (t) => {
  const env = envelope(t, 0.35, 0.10, 0.12, 0.12);
  const voice = Math.sin(2 * Math.PI * 140 * t) + 0.25 * Math.sin(2 * Math.PI * 280 * t);
  quietLp = quietLp * 0.88 + (Math.random() * 2 - 1) * 0.12;
  return 0.0005 * (Math.random() * 2 - 1) + env * (0.16 * voice + quietLp * 0.18);
});
const cough = makeSignal(1.0, (t) => {
  const env = envelope(t, 0.4, 0.02, 0.08, 0.12);
  const noise = (Math.random() * 2 - 1);
  return 0.0005 * (Math.random() * 2 - 1) + env * noise * 0.35;
});
const speech = makeSignal(1.6, (t) => {
  const env = envelope(t, 0.2, 0.05, 1.1, 0.08);
  const voice = Math.sin(2 * Math.PI * 180 * t) + 0.5 * Math.sin(2 * Math.PI * 360 * t);
  return 0.0004 * (Math.random() * 2 - 1) + env * voice * 0.18;
});
const impact = makeSignal(0.8, (t) => {
  const env = envelope(t, 0.4, 0.004, 0.008, 0.03);
  return 0.0004 * (Math.random() * 2 - 1) + env * (Math.random() * 2 - 1) * 0.9;
});
const doubleThroat = makeSignal(2.4, (t) => {
  const e1 = envelope(t, 0.4, 0.07, 0.14, 0.08);
  const e2 = envelope(t, 1.15, 0.07, 0.14, 0.08);
  const env = Math.max(e1, e2);
  const voice = Math.sin(2 * Math.PI * 155 * t) + 0.3 * Math.sin(2 * Math.PI * 310 * t);
  const noise = (Math.random() * 2 - 1) * 0.25;
  return 0.0005 * (Math.random() * 2 - 1) + env * (0.20 * voice + noise * 0.16);
});
let lp = 0;
const rasp = makeSignal(1.1, (t) => {
  const env = envelope(t, 0.35, 0.09, 0.14, 0.10);
  lp = lp * 0.82 + (Math.random() * 2 - 1) * 0.18;
  return 0.0005 * (Math.random() * 2 - 1) + env * lp * 0.55;
});
let body = 0;
const phoneCough = makeSignal(1.0, (t) => {
  const env = envelope(t, 0.4, 0.015, 0.07, 0.14);
  const n = Math.random() * 2 - 1;
  body = body * 0.55 + n * 0.45;
  const turbulence = n - body * 0.65;
  return 0.0005 * (Math.random() * 2 - 1) + env * (body * 0.22 + turbulence * 0.50);
});
let muff = 0;
const muffledCough = makeSignal(1.0, (t) => {
  const env = envelope(t, 0.4, 0.06, 0.08, 0.12);
  const n = Math.random() * 2 - 1;
  muff = muff * 0.62 + n * 0.38;
  return 0.0005 * (Math.random() * 2 - 1) + env * (muff * 0.28 + n * 0.22);
});

const longSilence = makeSignal(5.0, () => 0.0004 * (Math.random() * 2 - 1));
const t0 = Date.now();
const idle = new HumanSoundDetector();
idle.push(pcmFrom(longSilence), 0);
const idleMs = Date.now() - t0;
console.log('idle5sMs', idleMs);
const room = makeSignal(2.5, () => 0.018 * (Math.random() * 2 - 1));
const rRoom = run('roomNoise', room);
const r1 = run('silence', silence);
const r2 = run('throat', throat);
const r3 = run('quietThroat', quietThroat);
const r4 = run('cough', cough);
const r5 = run('speech', speech);
const r6 = run('impact', impact);
const r7 = run('doubleThroat', doubleThroat);
const r8 = run('rasp', rasp);
const r9 = run('phoneCough', phoneCough);
const r10 = run('muffledCough', muffledCough);

const ok = idleMs < 80
  && rRoom.accepted.length === 0
  && r1.accepted.length === 0
  && r2.accepted.some((d) => d.event.type === 'throat_clear')
  && r3.accepted.some((d) => d.event.type === 'throat_clear')
  && r4.accepted.some((d) => d.event.type === 'cough')
  && r5.accepted.length === 0
  && r6.accepted.length === 0
  && r7.accepted.filter((d) => d.event.type === 'throat_clear').length >= 2
  && r9.accepted.some((d) => d.event.type === 'cough')
  && !r9.accepted.some((d) => d.event.type === 'throat_clear')
  && r10.accepted.some((d) => d.event.type === 'cough')
  && !r10.accepted.some((d) => d.event.type === 'throat_clear');
if (!ok) {
  console.error('SANITY CHECK FAILED');
  process.exit(1);
}
console.log('SANITY CHECK PASSED');
