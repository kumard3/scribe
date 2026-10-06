import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import { getDictationStyle } from './settings';
import { localeFor } from './system';
import type { LanguageCode, TimedUnit } from './types';

type Native = {
  isAvailable(): Promise<boolean>;
  start(locale: string, romanize: boolean, terms: string[]): Promise<void>;
  stop(): Promise<void>;
  transcribeFile(path: string, locale: string, romanize: boolean): Promise<{ text: string; units: TimedUnit[] }>;
};

export type AppleSpeechEvent =
  | { type: 'start' }
  | { type: 'result'; text: string; isFinal: boolean }
  | { type: 'level'; value: number }
  | { type: 'end' }
  | { type: 'error'; message: string };

const native = Platform.OS === 'ios' ? (NativeModules.ScribeAppleSpeech as Native | undefined) : undefined;
let available = false;

/** iOS 26+ SpeechAnalyzer, the engine the Mac app uses. Resolves once at launch. */
export const appleSpeechReady: Promise<boolean> = native
  ? native.isAvailable().then((ok) => (available = ok)).catch(() => false)
  : Promise.resolve(false);

export function appleSpeechAvailable(): boolean {
  return available;
}

/** Auto and Hinglish use Apple's hi-IN model romanized, like the Mac's Hinglish mode. */
function appleLocale(language: LanguageCode): { locale: string; romanize: boolean } {
  const style = getDictationStyle();
  if (style === 'hinglish' || (language === 'auto' && style !== 'english')) return { locale: 'hi-IN', romanize: true };
  return { locale: localeFor(language), romanize: false };
}

export function onAppleSpeech(listener: (e: AppleSpeechEvent) => void): () => void {
  if (!native) return () => {};
  const sub = new NativeEventEmitter(NativeModules.ScribeAppleSpeech).addListener('ScribeAppleSpeech', listener);
  return () => sub.remove();
}

export function startAppleSpeech(language: LanguageCode, terms: string[]): Promise<void> {
  const { locale, romanize } = appleLocale(language);
  return native ? native.start(locale, romanize, terms) : Promise.reject(new Error('Apple speech unavailable'));
}

export function stopAppleSpeech(): Promise<void> {
  return native ? native.stop() : Promise.resolve();
}

export function transcribeFileWithApple(uri: string, language: LanguageCode): Promise<{ text: string; units: TimedUnit[] }> {
  const { locale, romanize } = appleLocale(language);
  if (!native) return Promise.reject(new Error('Apple speech unavailable'));
  return native.transcribeFile(uri.replace(/^file:\/\//, ''), locale, romanize);
}
