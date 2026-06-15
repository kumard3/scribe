import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

const native = NativeModules.ScribeAudioRecorder as
  | {
      start(): Promise<void>;
      stop(): Promise<string>;
      cancel(): Promise<void>;
    }
  | undefined;

export const hasNativeRecorder = Platform.OS === 'ios' && !!native;

const emitter = native ? new NativeEventEmitter(NativeModules.ScribeAudioRecorder) : null;

export async function startNative(): Promise<void> {
  if (!native) throw new Error('Native recorder unavailable');
  return native.start();
}

export async function stopNative(): Promise<string> {
  if (!native) throw new Error('Native recorder unavailable');
  return native.stop();
}

export async function cancelNative(): Promise<void> {
  if (!native) return;
  try {
    await native.cancel();
  } catch {}
}

export function onNativeLevel(cb: (rms: number) => void): () => void {
  const sub = emitter?.addListener('ScribeAudioLevel', (e: { rms: number }) => cb(e.rms));
  return () => sub?.remove();
}
