export type LanguageCode = string;

export type EngineKind = 'whisper' | 'sherpa';

export type ModelSpec = {
  id: string;
  label: string;
  engine: EngineKind;
  url: string;
  fileName: string;
  sizeMB: number;
  languages: LanguageCode[] | 'multilingual';
};

export type TranscriptionResult = {
  text: string;
  language?: string;
  durationMs?: number;
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
