import { Platform } from 'react-native';

// The rename to Bolkit (App Store guideline 4.1(c)) is iOS-only for now.
export const BRAND = Platform.OS === 'ios' ? 'Bolkit' : 'Scribe';
export const TAGLINE = 'Your on-device transcriber';
