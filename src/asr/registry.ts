import { LanguageCode, ModelSpec } from './types';

const HF = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

export const MODELS: ModelSpec[] = [
  {
    id: 'oriserve-swift-q8',
    label: 'Swift · Hinglish',
    engine: 'whisper',
    url: 'https://huggingface.co/anish2305/airnote-hinglish-stt-ggml/resolve/main/ggml-oriserve-hinglish-q8_0.bin',
    fileName: 'ggml-oriserve-hinglish-q8_0.bin',
    sizeBytes: 81768585,
    languages: 'multilingual',
    note: 'Oriserve · 74M · romanized Hinglish + Indian English',
    forcedLanguage: 'hi',
  },
  {
    id: 'apex-hinglish-q5',
    label: 'Apex · Hinglish',
    engine: 'whisper',
    url: 'https://huggingface.co/Marquestra/Whisper-Hindi2Hinglish-Apex-GGML/resolve/main/ggml-apex-hinglish-q5_0.bin',
    fileName: 'ggml-apex-hinglish-q5_0.bin',
    sizeBytes: 574041195,
    languages: 'multilingual',
    note: 'Oriserve Whisper Turbo · Indian accents · romanized Hinglish',
    forcedLanguage: 'hi',
  },
  {
    id: 'whisper-tiny',
    label: 'Tiny · multilingual',
    engine: 'whisper',
    url: `${HF}/ggml-tiny.bin`,
    fileName: 'ggml-tiny.bin',
    sizeBytes: 77691713,
    languages: 'multilingual',
    note: 'Fastest · all-in-one',
  },
  {
    id: 'whisper-base-en',
    label: 'Base · English',
    engine: 'whisper',
    url: `${HF}/ggml-base.en.bin`,
    fileName: 'ggml-base.en.bin',
    sizeBytes: 147964211,
    languages: ['en'],
    note: 'English · balanced',
  },
  {
    id: 'whisper-small-en-q5',
    label: 'Small · English (quantized)',
    engine: 'whisper',
    url: `${HF}/ggml-small.en-q5_1.bin`,
    fileName: 'ggml-small.en-q5_1.bin',
    sizeBytes: 190098681,
    languages: ['en'],
    note: 'English · higher accuracy',
  },
  {
    id: 'whisper-small',
    label: 'Small · multilingual',
    engine: 'whisper',
    url: `${HF}/ggml-small.bin`,
    fileName: 'ggml-small.bin',
    sizeBytes: 487601967,
    languages: 'multilingual',
    note: 'Hindi & 90+ languages',
  },
  {
    id: 'whisper-large-turbo-q5',
    label: 'Large v3 Turbo (quantized)',
    engine: 'whisper',
    url: `${HF}/ggml-large-v3-turbo-q5_0.bin`,
    fileName: 'ggml-large-v3-turbo-q5_0.bin',
    sizeBytes: 574041195,
    languages: 'multilingual',
    note: 'Best quality · translation',
  },
];

export const DEFAULT_MODEL_ID = 'whisper-small';

export const LANGUAGE_ROUTES: Record<string, string> = {
  auto: 'whisper-tiny',
  en: 'whisper-base-en',
  hi: 'oriserve-swift-q8',
  'hi-en': 'oriserve-swift-q8',
  es: 'whisper-small',
  fr: 'whisper-small',
  de: 'whisper-small',
};

export function modelById(id: string): ModelSpec {
  const m = MODELS.find((x) => x.id === id);
  if (!m) throw new Error(`Unknown model: ${id}`);
  return m;
}

export const SUPPORTED_LANGUAGES: { code: LanguageCode; label: string }[] = [
  { code: 'auto', label: 'Auto-detect' },
  { code: 'en', label: 'English' },
  { code: 'hi', label: 'Hindi' },
  { code: 'hi-en', label: 'Hinglish · Hindi + English (Roman)' },
  { code: 'es', label: 'Spanish' },
  { code: 'fr', label: 'French' },
  { code: 'de', label: 'German' },
  { code: 'pt', label: 'Portuguese' },
  { code: 'it', label: 'Italian' },
  { code: 'ru', label: 'Russian' },
  { code: 'ar', label: 'Arabic' },
  { code: 'zh', label: 'Chinese' },
  { code: 'ja', label: 'Japanese' },
  { code: 'ko', label: 'Korean' },
  { code: 'nl', label: 'Dutch' },
  { code: 'tr', label: 'Turkish' },
  { code: 'id', label: 'Indonesian' },
  { code: 'bn', label: 'Bengali' },
  { code: 'ta', label: 'Tamil' },
  { code: 'te', label: 'Telugu' },
  { code: 'mr', label: 'Marathi' },
  { code: 'gu', label: 'Gujarati' },
  { code: 'kn', label: 'Kannada' },
  { code: 'ml', label: 'Malayalam' },
  { code: 'pa', label: 'Punjabi' },
  { code: 'ur', label: 'Urdu' },
];

export function formatMB(bytes: number): string {
  return `${Math.round(bytes / 1e6)} MB`;
}
