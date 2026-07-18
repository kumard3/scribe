export type LanguageCode = string;

export type EngineKind = 'whisper' | 'sherpa';

export type ModelSpec = {
  id: string;
  label: string;
  engine: EngineKind;
  url: string;
  fileName: string;
  sizeBytes: number;
  languages: LanguageCode[] | 'multilingual';
  note?: string;
};

export type TimedUnit = { start: number; end: number; text: string };

export type TranscriptionResult = {
  text: string;
  language?: string;
  durationMs?: number;
  /** Segment/word timings (seconds), when the engine provides them. Used to
   *  attribute text to speakers during diarization. */
  units?: TimedUnit[];
};

export type TranscribeRequest = {
  wavPath: string;
  language: LanguageCode;
  translateToEnglish?: boolean;
};

export interface ASREngine {
  readonly kind: EngineKind;
  load(model: ModelSpec, localUri: string): Promise<void>;
  loadedModelId(): string | null;
  transcribe(req: TranscribeRequest): Promise<TranscriptionResult>;
  unload(): Promise<void>;
}
