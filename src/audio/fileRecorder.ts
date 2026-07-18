import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

// Long-form recorder for Record Mode. Captures straight to a 16 kHz mono WAV
// file via a native foreground recorder so it survives backgrounding and never
// buffers a whole meeting in the JS heap.
//   - Android: ScribeRecorder (RecorderService, foreground microphone service)
//   - iOS:     ScribeAudioRecorder (AVAudioEngine, also used by quick dictation)

type AndroidRec = {
  start(): Promise<boolean>;
  stop(): Promise<string | null>;
  pause(): Promise<boolean>;
  resume(): Promise<boolean>;
  cancel(): Promise<void>;
  isRecording(): Promise<boolean>;
};

type IosRec = {
  start(): Promise<void>;
  stop(): Promise<string>;
  cancel(): Promise<void>;
};

const androidRec = NativeModules.ScribeRecorder as AndroidRec | undefined;
const iosRec = NativeModules.ScribeAudioRecorder as IosRec | undefined;

export const recorderAvailable =
  Platform.OS === 'android' ? !!androidRec : Platform.OS === 'ios' ? !!iosRec : false;

// Only the Android foreground service genuinely keeps recording with the screen
// off / app backgrounded. iOS needs the audio background mode (Info.plist).
export const recorderBackgroundCapable = Platform.OS === 'android';
export const recorderSupportsPause = Platform.OS === 'android';

export function onRecorderLevel(cb: (rms: number) => void): () => void {
  if (Platform.OS === 'android' && androidRec) {
    const emitter = new NativeEventEmitter(NativeModules.ScribeRecorder);
    const sub = emitter.addListener('ScribeRecorderLevel', (e: { rms: number }) => cb(e.rms));
    return () => sub.remove();
  }
  if (Platform.OS === 'ios' && iosRec) {
    const emitter = new NativeEventEmitter(NativeModules.ScribeAudioRecorder);
    const sub = emitter.addListener('ScribeAudioLevel', (e: { rms: number }) => cb(e.rms));
    return () => sub.remove();
  }
  return () => {};
}

export async function startRecorder(): Promise<void> {
  if (Platform.OS === 'android' && androidRec) {
    await androidRec.start();
    return;
  }
  if (Platform.OS === 'ios' && iosRec) {
    await iosRec.start();
    return;
  }
  throw new Error('Recording is not available on this device');
}

/** Stops capture and returns the file:// URI of the finished 16 kHz mono WAV. */
export async function stopRecorder(): Promise<string> {
  if (Platform.OS === 'android' && androidRec) {
    const uri = await androidRec.stop();
    if (!uri) throw new Error('No audio captured');
    return uri;
  }
  if (Platform.OS === 'ios' && iosRec) {
    return iosRec.stop();
  }
  throw new Error('Recording is not available on this device');
}

export async function pauseRecorder(): Promise<void> {
  if (Platform.OS === 'android' && androidRec) await androidRec.pause();
}

export async function resumeRecorder(): Promise<void> {
  if (Platform.OS === 'android' && androidRec) await androidRec.resume();
}

export async function cancelRecorder(): Promise<void> {
  if (Platform.OS === 'android' && androidRec) await androidRec.cancel();
  else if (Platform.OS === 'ios' && iosRec) await iosRec.cancel();
}
