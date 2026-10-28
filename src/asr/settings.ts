import { File, Paths } from 'expo-file-system';
import * as SecureStore from 'expo-secure-store';
import { mergeVocab } from './vocab';

type Settings = {
  selectedModelId: string;
  vocab: string[];
  autoPolish: boolean;
  dictationStyle: 'auto' | 'english' | 'hinglish';
  chunkPauseMs: number;
  onboarded: boolean;
  translateToEnglish: boolean;
  translateTarget: string;
  cloudApiKey: string;
  cloudBaseUrl: string;
  cloudModel: string;
  cloudChatModel: string;
  cloudProvider: CloudProvider;
  azureSpeechRegion: string;
  azureSpeechEndpoint: string;
  azureOpenAIEndpoint: string;
  azureOpenAIApiVersion: string;
  azureOpenAITranscribe: string;
  azureOpenAIChat: string;
  llmModelId: string;
  smartCorrections: boolean;
  diarizationEnabled: boolean;
  diarizationSpeakers: number;
  recordModelId: string;
  flowIdleMinutes: number;
};

const DEFAULT: Settings = {
  selectedModelId: 'whisper:oriserve-swift-q8',
  vocab: [],
  autoPolish: false,
  dictationStyle: 'auto',
  chunkPauseMs: 550,
  onboarded: false,
  translateToEnglish: false,
  translateTarget: '',
  cloudApiKey: '',
  cloudBaseUrl: 'https://api.openai.com/v1',
  cloudModel: 'whisper-1',
  cloudChatModel: '',
  cloudProvider: 'openai',
  azureSpeechRegion: '',
  azureSpeechEndpoint: '',
  azureOpenAIEndpoint: '',
  azureOpenAIApiVersion: '2025-03-01-preview',
  azureOpenAITranscribe: '',
  azureOpenAIChat: '',
  llmModelId: 'gemma-4-e2b',
  smartCorrections: true,
  diarizationEnabled: false,
  diarizationSpeakers: 0,
  recordModelId: '',
  flowIdleMinutes: 5,
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

export function biasTerms(): string[] {
  return mergeVocab(load().vocab);
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

export function getDictationStyle(): 'auto' | 'english' | 'hinglish' {
  return load().dictationStyle;
}

export function setDictationStyle(dictationStyle: 'auto' | 'english' | 'hinglish'): void {
  persist({ ...load(), dictationStyle });
}

export function getChunkPauseMs(): number {
  const n = load().chunkPauseMs;
  if (n < 400) return 400;
  if (n > 700) return 700;
  return n;
}

export function setChunkPauseMs(chunkPauseMs: number): void {
  persist({ ...load(), chunkPauseMs });
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

export function getLLMModelId(): string {
  return load().llmModelId;
}

export function setLLMModelId(llmModelId: string): void {
  persist({ ...load(), llmModelId });
}

export function getSmartCorrections(): boolean {
  return load().smartCorrections;
}

export function setSmartCorrections(smartCorrections: boolean): void {
  persist({ ...load(), smartCorrections });
}

export function getFlowIdleMinutes(): number {
  return load().flowIdleMinutes;
}

export function setFlowIdleMinutes(flowIdleMinutes: number): void {
  persist({ ...load(), flowIdleMinutes });
}

export type CloudProvider = 'openai' | 'azure-speech' | 'azure-openai';

type CloudSecrets = { apiKey: string; azureSpeechKey: string; azureOpenAIKey: string };

export type CloudSettings = CloudSecrets & {
  provider: CloudProvider;
  baseUrl: string;
  model: string;
  chatModel: string;
  azureSpeechRegion: string;
  azureSpeechEndpoint: string;
  azureOpenAIEndpoint: string;
  azureOpenAIApiVersion: string;
  azureOpenAITranscribe: string;
  azureOpenAIChat: string;
};

const SECRETS_KEY = 'bolkit.cloud.keys';
const SECRETS_OPTS = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY };
const NO_SECRETS: CloudSecrets = { apiKey: '', azureSpeechKey: '', azureOpenAIKey: '' };
let secretsCache: CloudSecrets | null = null;

function readSecrets(): CloudSecrets {
  if (secretsCache) return secretsCache;
  try {
    const raw = SecureStore.getItem(SECRETS_KEY, SECRETS_OPTS);
    secretsCache = { ...NO_SECRETS, ...(raw ? JSON.parse(raw) : {}) };
  } catch {
    secretsCache = { ...NO_SECRETS };
  }
  const s = load();
  if (s.cloudApiKey && writeSecrets({ ...secretsCache!, apiKey: secretsCache!.apiKey || s.cloudApiKey })) {
    persist({ ...s, cloudApiKey: '' });
  }
  return secretsCache!;
}

function writeSecrets(next: CloudSecrets): boolean {
  try {
    SecureStore.setItem(SECRETS_KEY, JSON.stringify(next), SECRETS_OPTS);
    secretsCache = next;
    return true;
  } catch {
    return false;
  }
}

export function getCloud(): CloudSettings {
  const s = load();
  return {
    ...readSecrets(),
    provider: s.cloudProvider,
    baseUrl: s.cloudBaseUrl,
    model: s.cloudModel,
    chatModel: s.cloudChatModel,
    azureSpeechRegion: s.azureSpeechRegion,
    azureSpeechEndpoint: s.azureSpeechEndpoint,
    azureOpenAIEndpoint: s.azureOpenAIEndpoint,
    azureOpenAIApiVersion: s.azureOpenAIApiVersion,
    azureOpenAITranscribe: s.azureOpenAITranscribe,
    azureOpenAIChat: s.azureOpenAIChat,
  };
}

export function setCloud(patch: Partial<CloudSettings>): boolean {
  const c = { ...getCloud(), ...patch };
  const t = (v: string) => v.trim();
  const saved = writeSecrets({ apiKey: t(c.apiKey), azureSpeechKey: t(c.azureSpeechKey), azureOpenAIKey: t(c.azureOpenAIKey) });
  persist({
    ...load(),
    cloudProvider: c.provider,
    cloudBaseUrl: t(c.baseUrl),
    cloudModel: t(c.model),
    cloudChatModel: t(c.chatModel),
    azureSpeechRegion: t(c.azureSpeechRegion),
    azureSpeechEndpoint: t(c.azureSpeechEndpoint),
    azureOpenAIEndpoint: t(c.azureOpenAIEndpoint),
    azureOpenAIApiVersion: t(c.azureOpenAIApiVersion),
    azureOpenAITranscribe: t(c.azureOpenAITranscribe),
    azureOpenAIChat: t(c.azureOpenAIChat),
  });
  return saved;
}
