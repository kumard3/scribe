import { NativeModules } from 'react-native';
import TranslateText, { TranslateLanguage } from '@react-native-ml-kit/translate-text';
import IdentifyLanguages from '@react-native-ml-kit/identify-languages';

// On-device translation (Google ML Kit). Speak in any language, transcribe with
// the normal STT, then translate the text to a single target the user picks,
// the way Wispr Flow does it on Android. Models download once per language and
// then run fully offline. Both native modules expose a NativeModules entry; if
// the build hasn't linked them yet, every call here degrades to a no-op so the
// JS never throws.

const VALID = new Set<string>(Object.values(TranslateLanguage));

export const translationSupported = NativeModules.TranslateText != null;
const identifySupported = NativeModules.IdentifyLanguages != null;

// English name for every language ML Kit supports.
const LANG_LABELS: Record<string, string> = {
  af: 'Afrikaans', sq: 'Albanian', ar: 'Arabic', be: 'Belarusian', bg: 'Bulgarian',
  bn: 'Bengali', ca: 'Catalan', zh: 'Chinese', hr: 'Croatian', cs: 'Czech', da: 'Danish',
  nl: 'Dutch', en: 'English', eo: 'Esperanto', et: 'Estonian', fi: 'Finnish', fr: 'French',
  gl: 'Galician', ka: 'Georgian', de: 'German', el: 'Greek', gu: 'Gujarati',
  ht: 'Haitian Creole', he: 'Hebrew', hi: 'Hindi', hu: 'Hungarian', is: 'Icelandic',
  id: 'Indonesian', ga: 'Irish', it: 'Italian', ja: 'Japanese', kn: 'Kannada', ko: 'Korean',
  lt: 'Lithuanian', lv: 'Latvian', mk: 'Macedonian', mr: 'Marathi', ms: 'Malay',
  mt: 'Maltese', no: 'Norwegian', fa: 'Persian', pl: 'Polish', pt: 'Portuguese',
  ro: 'Romanian', ru: 'Russian', sk: 'Slovak', sl: 'Slovenian', es: 'Spanish', sv: 'Swedish',
  sw: 'Swahili', tl: 'Tagalog', ta: 'Tamil', te: 'Telugu', th: 'Thai', tr: 'Turkish',
  uk: 'Ukrainian', ur: 'Urdu', vi: 'Vietnamese', cy: 'Welsh',
};

// Common picks first, then everything else ML Kit supports, alphabetically.
const POPULAR = ['en', 'es', 'hi', 'fr', 'de', 'zh', 'ar', 'pt', 'ru', 'ja'];

// Every ML Kit language, built from the SDK enum so the list can't drift.
export const TRANSLATE_TARGETS: { code: string; label: string }[] = [
  { code: '', label: 'Off, no translation' },
  ...POPULAR.filter((c) => VALID.has(c)).map((c) => ({ code: c, label: LANG_LABELS[c] ?? c })),
  ...Object.values(TranslateLanguage)
    .filter((c) => !POPULAR.includes(c))
    .map((c) => ({ code: c, label: LANG_LABELS[c] ?? c }))
    .sort((a, b) => a.label.localeCompare(b.label)),
];

export function translateTargetLabel(code: string): string {
  return code === '' ? 'Off' : LANG_LABELS[code] ?? code;
}

/** Reduce an app/BCP-47 code (e.g. 'zh-Latn', 'hi-en') to a supported ML Kit code, or null. */
function normalize(code: string | undefined | null): string | null {
  if (!code) return null;
  const base = code.split('-')[0].toLowerCase();
  return VALID.has(base) ? base : null;
}

async function detectSource(text: string): Promise<string | null> {
  if (!identifySupported) return null;
  try {
    const id = await IdentifyLanguages.identify(text.slice(0, 240));
    return id === 'und' ? null : normalize(id);
  } catch {
    return null;
  }
}

/**
 * Translate `text` into `targetCode`. `sourceHint` is the STT language; when it
 * isn't a concrete language ('auto'/'hi-en') the source is detected from the
 * text. Returns the original text unchanged if translation is off, unsupported,
 * the source already equals the target, or the model isn't available yet.
 */
export async function translateText(
  text: string,
  targetCode: string,
  sourceHint?: string
): Promise<string> {
  const target = normalize(targetCode);
  if (!translationSupported || !target || !text.trim()) return text;

  let source =
    sourceHint && sourceHint !== 'auto' && sourceHint !== 'hi-en'
      ? normalize(sourceHint)
      : null;
  if (!source) source = await detectSource(text);
  if (!source || source === target) return text;

  try {
    const out = (await TranslateText.translate({
      text,
      sourceLanguage: source as TranslateLanguage,
      targetLanguage: target as TranslateLanguage,
      downloadModelIfNeeded: true,
    })) as unknown as string;
    return out && out.length ? out : text;
  } catch {
    return text;
  }
}
