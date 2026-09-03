export type AcousticEventType = 'cough' | 'throat_clear';

export interface AudioBlock {
  pcm: Int16Array;
  startSample: number;
  endSample: number;
}

export interface AcousticEvent {
  type: AcousticEventType;
  startSample: number;
  endSample: number;
  durationMs: number;
  peakDb: number;
  classConfidence: number;
  targetConfidence: number;
  qualityFlags: number;
  algorithmVersion: string;
}

export enum AudioQualityFlag {
  NONE = 0,
  CLIPPED = 1,
  LOW_SNR = 2,
  TOO_SHORT = 4,
  TOO_LONG = 8,
  TONAL = 16,
  IMPACT = 32,
  SPEECH_LIKE = 64,
  AMBIGUOUS = 128
}
