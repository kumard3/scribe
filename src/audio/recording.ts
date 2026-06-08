import { AudioQuality, IOSOutputFormat, RecordingOptions } from 'expo-audio';

export const WAV_16K_MONO: RecordingOptions = {
  isMeteringEnabled: true,
  extension: '.wav',
  sampleRate: 16000,
  numberOfChannels: 1,
  bitRate: 256000,
  ios: {
    extension: '.wav',
    outputFormat: IOSOutputFormat.LINEARPCM,
    audioQuality: AudioQuality.HIGH,
    linearPCMBitDepth: 16,
    linearPCMIsBigEndian: false,
    linearPCMIsFloat: false,
  },
  android: {
    extension: '.wav',
    outputFormat: 'default',
    audioEncoder: 'default',
  },
  web: {
    mimeType: 'audio/webm',
    bitsPerSecond: 128000,
  },
};
