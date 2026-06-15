import {
  createStreamingSTT,
  type StreamingSttEngine,
  type SttStream,
} from 'react-native-sherpa-onnx/stt';

// True low-latency streaming recognition (sherpa-onnx OnlineRecognizer).
// sherpa resamples internally, so we feed whatever sample rate the mic gives.
let engine: StreamingSttEngine | null = null;
let stream: SttStream | null = null;
let committed = '';
let partial = '';
let onTextCb: ((text: string) => void) | null = null;
let busy = false;
const queue: { samples: Float32Array; sr: number }[] = [];

export async function startSherpaLive(
  modelDir: string,
  onText: (text: string) => void
): Promise<void> {
  await stopSherpaLive().catch(() => {});
  committed = '';
  partial = '';
  queue.length = 0;
  onTextCb = onText;
  engine = await createStreamingSTT({
    modelPath: { type: 'file', path: modelDir },
    modelType: 'auto',
    numThreads: 2,
    enableEndpoint: true,
  });
  stream = await engine.createStream();
}

export function feedSherpaLive(samples: Float32Array, sampleRate: number): void {
  if (!stream) return;
  queue.push({ samples, sr: sampleRate });
  void drain();
}

async function drain(): Promise<void> {
  if (busy || !stream) return;
  busy = true;
  try {
    while (queue.length && stream) {
      const { samples, sr } = queue.shift()!;
      const { result, isEndpoint } = await stream.processAudioChunk(samples, sr);
      partial = (result.text ?? '').trim();
      onTextCb?.((committed + ' ' + partial).trim());
      if (isEndpoint) {
        if (partial) committed = (committed + ' ' + partial).trim();
        partial = '';
        await stream.reset();
        onTextCb?.(committed);
      }
    }
  } catch {
    // drop this batch; next chunk retries
  } finally {
    busy = false;
  }
}

export async function stopSherpaLive(): Promise<string> {
  const out = (committed + ' ' + partial).trim();
  queue.length = 0;
  try {
    if (stream) await stream.release();
  } catch {}
  try {
    if (engine) await engine.destroy();
  } catch {}
  stream = null;
  engine = null;
  committed = '';
  partial = '';
  onTextCb = null;
  return out;
}
