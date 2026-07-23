import { createPcmLiveStream, type PcmLiveStreamHandle } from 'react-native-sherpa-onnx/audio';

// Native mic capture with native resampling, always delivers Float32 PCM at
// the requested rate (16k for STT). Far more reliable for live streaming than
// feeding JS buffers from expo-audio.
let handle: PcmLiveStreamHandle | null = null;
let unsubs: (() => void)[] = [];

export async function startLiveMic(
  onSamples: (samples: Float32Array, sampleRate: number) => void,
  onError?: (message: string) => void
): Promise<void> {
  await stopLiveMic();
  handle = createPcmLiveStream({ sampleRate: 16000, channelCount: 1 });
  unsubs.push(handle.onData(onSamples));
  if (onError) unsubs.push(handle.onError(onError));
  await handle.start();
}

export async function stopLiveMic(): Promise<void> {
  for (const u of unsubs) {
    try {
      u();
    } catch {}
  }
  unsubs = [];
  if (handle) {
    try {
      await handle.stop();
    } catch {}
    handle = null;
  }
}
