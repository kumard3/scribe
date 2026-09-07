import type { ModelSpec } from './types';

// Whisper emits bracketed non-speech annotations ([BLANK_AUDIO], [MUSIC],
// [NON-ENGLISH SPEECH]) as decoder output; they are not transcript.
const ANNOTATION = /\[[A-Z][A-Z _'-]*\]/g;

export function stripAnnotations(text: string): string {
  return text.replace(ANNOTATION, '').replace(/[ \t]{2,}/g, ' ').trim();
}

// .en models have no language-detection head; asking one for 'auto' or any
// non-English locale returns [NON-ENGLISH SPEECH] instead of a transcript.
export function decodeLanguage(
  spec: ModelSpec | null,
  language: string,
  style = 'auto'
): string {
  if (style === 'english') return 'en';
  if (spec?.forcedLanguage) {
    if (style === 'hinglish') return spec.forcedLanguage;
    if (language === 'en') return spec.forcedLanguage;
    return spec.forcedLanguage;
  }
  const requested = language === 'hi-en' ? 'en' : language;
  return Array.isArray(spec?.languages) ? 'en' : requested;
}
