import { initWhisper, type WhisperContext } from 'whisper.rn';
import { RealtimeTranscriber } from 'whisper.rn/realtime-transcription';
import type {
  AudioStreamInterface,
  AudioStreamData,
  AudioStreamConfig,
} from 'whisper.rn/realtime-transcription';
import { resampleTo16k, float32ToInt16Bytes } from '../../audio/wav';

// whisper.rn's realtime path wants an AudioStreamInterface. The bundled
// adapter needs @fugood/react-native-audio-pcm-stream (not installed), so we
// relay PCM ourselves from the expo-audio stream via push().
class PushPcmStream implements AudioStreamInterface {
  private dataCb: ((d: AudioStreamData) => void) | null = null;
  private statusCb: ((r: boolean) => void) | null = null;
  private endCb: (() => void) | null = null;
  private recording = false;

  async initialize(_config: AudioStreamConfig): Promise<void> {}
  async start(): Promise<void> {
    this.recording = true;
    this.statusCb?.(true);
  }
  async stop(): Promise<void> {
    this.recording = false;
    this.statusCb?.(false);
    this.endCb?.();
  }
  isRecording(): boolean {
    return this.recording;
  }
  onData(cb: (d: AudioStreamData) => void): void {
    this.dataCb = cb;
  }
  onError(_cb: (e: string) => void): void {}
  onStatusChange(cb: (r: boolean) => void): void {
    this.statusCb = cb;
  }
  onEnd(cb: () => void): void {
    this.endCb = cb;
  }
  async release(): Promise<void> {}

  push(data: Uint8Array, sampleRate: number): void {
    if (this.recording) this.dataCb?.({ data, sampleRate, channels: 1, timestamp: 0 });
  }
}

let transcriber: RealtimeTranscriber | null = null;
let ctx: WhisperContext | null = null;
let pcm: PushPcmStream | null = null;
let onTextCb: ((text: string) => void) | null = null;
const sliceText: Record<number, string> = {};

function joinText(): string {
  return Object.keys(sliceText)
    .map(Number)
    .sort((a, b) => a - b)
    .map((i) => sliceText[i])
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export async function startWhisperLive(
  fileUri: string,
  language: string,
  translate: boolean,
  onText: (text: string) => void
): Promise<void> {
  await stopWhisperLive().catch(() => {});
  for (const k of Object.keys(sliceText)) delete sliceText[Number(k)];
  onTextCb = onText;
  const filePath = fileUri.replace(/^file:\/\//, '');
  ctx = await initWhisper({ filePath });
  pcm = new PushPcmStream();
  const lang = language === 'hi-en' ? 'en' : language || 'auto';
  transcriber = new RealtimeTranscriber(
    { whisperContext: ctx as any, audioStream: pcm },
    {
      audioSliceSec: 12,
      audioMinSec: 1,
      maxSlicesInMemory: 2,
      promptPreviousSlices: true,
      realtimeProcessingPauseMs: 300,
      transcribeOptions: { language: lang, translate, maxThreads: 4 } as any,
    },
    {
      onTranscribe: (e: { data?: { result?: string }; sliceIndex: number }) => {
        const text = e.data?.result;
        if (text != null) {
          sliceText[e.sliceIndex] = text.trim();
          onTextCb?.(joinText());
        }
      },
      onError: () => {},
    }
  );
  await transcriber.start();
}

export function feedWhisperLive(samples: Float32Array, sampleRate: number): void {
  if (!pcm) return;
  const r16 = resampleTo16k(samples, sampleRate);
  pcm.push(float32ToInt16Bytes(r16), 16000);
}

export async function stopWhisperLive(): Promise<string> {
  const out = joinText();
  try {
    if (transcriber) await transcriber.stop();
  } catch {}
  try {
    if (transcriber) await transcriber.release();
  } catch {}
  try {
    if (ctx) await ctx.release();
  } catch {}
  transcriber = null;
  ctx = null;
  pcm = null;
  onTextCb = null;
  return out;
}
