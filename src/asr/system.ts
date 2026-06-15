import { ExpoSpeechRecognitionModule } from 'expo-speech-recognition';
import type { LanguageCode } from './types';

export type LiveStartOptions = {
  locale: string;
  onDevice: boolean;
  contextualStrings?: string[];
};

export function systemAvailable(): boolean {
  try {
    return ExpoSpeechRecognitionModule.isRecognitionAvailable();
  } catch {
    return false;
  }
}

export function supportsOnDevice(): boolean {
  try {
    return ExpoSpeechRecognitionModule.supportsOnDeviceRecognition();
  } catch {
    return false;
  }
}

export async function requestSystemPermission(): Promise<boolean> {
  const res = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
  return res.granted;
}

export async function installedLocales(): Promise<string[]> {
  try {
    const res = await ExpoSpeechRecognitionModule.getSupportedLocales({});
    return res.installedLocales.length ? res.installedLocales : res.locales;
  } catch {
    return [];
  }
}

function localeInstalled(locale: string, installed: string[]): boolean {
  const lc = locale.toLowerCase();
  const base = lc.split('-')[0];
  return installed.some((l) => {
    const li = l.toLowerCase();
    return li === lc || li.split('-')[0] === base;
  });
}

export async function resolveOnDevice(locale: string): Promise<boolean> {
  // Prefer on-device when the locale pack is installed: it's instant and local.
  // Network recognition is the laggy path ("very slow" on iOS). The 'end'
  // auto-restart in App.tsx covers on-device dropping audio on long dictation.
  if (!supportsOnDevice()) return false;
  try {
    const installed = await installedLocales();
    return localeInstalled(locale, installed);
  } catch {
    return false;
  }
}

export function startLive({ locale, onDevice, contextualStrings }: LiveStartOptions): void {
  ExpoSpeechRecognitionModule.start({
    lang: locale,
    interimResults: true,
    continuous: true,
    requiresOnDeviceRecognition: onDevice,
    addsPunctuation: true,
    iosTaskHint: 'dictation',
    // Enable iOS voice processing (AGC + noise suppression). Without it the mic
    // input is raw/quiet vs Android's processed pipeline — this is the main
    // reason iOS pickup felt weaker than Android.
    iosVoiceProcessingEnabled: true,
    iosCategory: {
      category: 'playAndRecord',
      categoryOptions: ['defaultToSpeaker', 'allowBluetooth'],
    },
    contextualStrings: contextualStrings?.length ? contextualStrings : undefined,
    volumeChangeEventOptions: { enabled: true, intervalMillis: 150 },
  });
}

export function stopLive(): void {
  try {
    ExpoSpeechRecognitionModule.stop();
  } catch {
    // best effort
  }
}

export function abortLive(): void {
  try {
    ExpoSpeechRecognitionModule.abort();
  } catch {
    // best effort
  }
}

export const LIVE_LOCALES: Record<LanguageCode, string> = {
  auto: 'en-US',
  en: 'en-US',
  hi: 'hi-IN',
  'hi-en': 'en-IN',
  es: 'es-ES',
  fr: 'fr-FR',
  de: 'de-DE',
  pt: 'pt-BR',
  it: 'it-IT',
  ja: 'ja-JP',
  ko: 'ko-KR',
  zh: 'zh-CN',
  ar: 'ar-SA',
  ru: 'ru-RU',
  nl: 'nl-NL',
  tr: 'tr-TR',
  id: 'id-ID',
  bn: 'bn-IN',
  ta: 'ta-IN',
  te: 'te-IN',
  mr: 'mr-IN',
  gu: 'gu-IN',
  kn: 'kn-IN',
  ml: 'ml-IN',
  pa: 'pa-IN',
  ur: 'ur-IN',
};

export function localeFor(language: LanguageCode): string {
  return LIVE_LOCALES[language] ?? 'en-US';
}
