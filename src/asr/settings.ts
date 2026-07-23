import { File, Paths } from 'expo-file-system';

type Settings = {
  selectedModelId: string;
  vocab: string[];
  autoPolish: boolean;
  onboarded: boolean;
  translateToEnglish: boolean;
  translateTarget: string;
  cloudApiKey: string;
  cloudBaseUrl: string;
  cloudModel: string;
  diarizationEnabled: boolean;
  diarizationSpeakers: number;
  recordModelId: string;
};

const DEFAULT: Settings = {
  selectedModelId: 'system',
  vocab: [],
  autoPolish: false,
  onboarded: false,
  translateToEnglish: false,
  translateTarget: '',
  cloudApiKey: '',
  cloudBaseUrl: 'https://api.openai.com/v1',
  cloudModel: 'whisper-1',
  diarizationEnabled: false,
  diarizationSpeakers: 0,
  recordModelId: '',
};

function file(): File {
  return new File(Paths.document, 'settings.json');
}

function load(): Settings {
  try {
    const f = file();
    if (!f.exists) return DEFAULT;
    return { ...DEFAULT, ...JSON.parse(f.textSync()) };
  } catch {
    return DEFAULT;
  }
}

function persist(s: Settings): void {
  const f = file();
  if (!f.exists) f.create();
  f.write(JSON.stringify(s));
}

export function getSelectedModelId(): string {
  return load().selectedModelId;
}

export function setSelectedModelId(selectedModelId: string): void {
  persist({ ...load(), selectedModelId });
}

export function getVocab(): string[] {
  return load().vocab;
}

export function setVocab(vocab: string[]): void {
  persist({ ...load(), vocab });
}

export function getAutoPolish(): boolean {
  return load().autoPolish;
}

export function setAutoPolish(autoPolish: boolean): void {
  persist({ ...load(), autoPolish });
}

export function getOnboarded(): boolean {
  return load().onboarded;
}

export function setOnboarded(onboarded: boolean): void {
  persist({ ...load(), onboarded });
}

export function getTranslateToEnglish(): boolean {
  return load().translateToEnglish;
}

export function setTranslateToEnglish(translateToEnglish: boolean): void {
  persist({ ...load(), translateToEnglish });
}

// Target language for translation ('' = off). Migrates the old English toggle.
export function getTranslateTarget(): string {
  const s = load();
  return s.translateTarget || (s.translateToEnglish ? 'en' : '');
}

export function setTranslateTarget(translateTarget: string): void {
  persist({ ...load(), translateTarget });
}

export function getDiarizationEnabled(): boolean {
  return load().diarizationEnabled;
}

export function setDiarizationEnabled(diarizationEnabled: boolean): void {
  persist({ ...load(), diarizationEnabled });
}

// Expected speaker count for diarization. 0 = auto-detect, which over-clusters
// badly on long real-world calls (a 42-min call auto-detected 116 speakers), so
// letting the user pin a count is the practical fix.
export function getDiarizationSpeakers(): number {
  return load().diarizationSpeakers;
}

export function setDiarizationSpeakers(diarizationSpeakers: number): void {
  persist({ ...load(), diarizationSpeakers });
}

// Model used in Record Mode (must be file-capable). Falls back to the live
// selection when it's an offline model, else '' so the UI can prompt a pick.
export function getRecordModelId(): string {
  return load().recordModelId;
}

export function setRecordModelId(recordModelId: string): void {
  persist({ ...load(), recordModelId });
}

export type CloudSettings = { apiKey: string; baseUrl: string; model: string };

export function getCloud(): CloudSettings {
  const s = load();
  return { apiKey: s.cloudApiKey, baseUrl: s.cloudBaseUrl, model: s.cloudModel };
}

export function setCloud(patch: Partial<CloudSettings>): void {
  const s = load();
  persist({
    ...s,
    cloudApiKey: patch.apiKey ?? s.cloudApiKey,
    cloudBaseUrl: patch.baseUrl ?? s.cloudBaseUrl,
    cloudModel: patch.model ?? s.cloudModel,
  });
}
