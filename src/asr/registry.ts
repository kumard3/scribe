import { LanguageCode, ModelSpec } from './types';

const HF = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

export const MODELS: ModelSpec[] = [
  {
    id: 'whisper-tiny-multi',
    label: 'Tiny · multilingual (all-in-one)',
    engine: 'whisper',
    url: `${HF}/ggml-tiny.bin`,
    fileName: 'ggml-tiny.bin',
    sizeMB: 75,
    languages: 'multilingual',
  },
  {
    id: 'whisper-base-en',
    label: 'Base · English',
    engine: 'whisper',
    url: `${HF}/ggml-base.en.bin`,
    fileName: 'ggml-base.en.bin',
    sizeMB: 142,
    languages: ['en'],
  },
  {
    id: 'whisper-small-multi',
    label: 'Small · multilingual (Hindi & others)',
    engine: 'whisper',
    url: `${HF}/ggml-small.bin`,
    fileName: 'ggml-small.bin',
    sizeMB: 466,
    languages: 'multilingual',
  },
];

export const ALL_IN_ONE_MODEL_ID = 'whisper-tiny-multi';
export const DEFAULT_MODEL_ID = 'whisper-small-multi';

export const LANGUAGE_ROUTES: Record<string, string> = {
  auto: ALL_IN_ONE_MODEL_ID,
  en: 'whisper-base-en',
  hi: 'whisper-small-multi',
  es: 'whisper-small-multi',
  fr: 'whisper-small-multi',
  de: 'whisper-small-multi',
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
  { code: 'es', label: 'Spanish' },
  { code: 'fr', label: 'French' },
  { code: 'de', label: 'German' },
];
