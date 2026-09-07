import { writeWavFromFloat32 } from '../../audio/wav';
import { transcribeWithModel } from '../index';
import { cleanupWithLLM, LLM_MODELS, llmInstalled } from '../llm';
import { getAutoPolish, getChunkPauseMs, getDictationStyle } from '../settings';
import { decodeLanguage } from '../whisperText';
import { biasTerms } from '../settings';
import type { ModelSpec } from '../types';
import { PauseChunker } from './pauseChunker';

type TextCb = (cleaned: string, pending: string) => void;

let chunker: PauseChunker | null = null;
let onText: TextCb | null = null;
let spec: ModelSpec | null = null;
let language = 'hi';
let committed = '';
let pending = '';
let busy = false;
let queue: Float32Array[] = [];
let gen = 0;

export async function startWhisperChunks(
  model: ModelSpec,
  lang: string,
  cb: TextCb
): Promise<void> {
  stopWhisperChunksSync();
  spec = model;
  language = decodeLanguage(model, lang, getDictationStyle());
  onText = cb;
  committed = '';
  pending = '';
  busy = false;
  queue = [];
  gen += 1;
  let pause = getChunkPauseMs();
  if (pause < 400) pause = 400;
  if (pause > 700) pause = 700;
  chunker = new PauseChunker({ sampleRate: 16000, pauseMs: pause });
}

export function feedWhisperChunks(samples: Float32Array, sampleRate: number): void {
  if (!chunker) return;
  if (sampleRate !== 16000 && sampleRate > 0) {
    const ratio = sampleRate / 16000;
    const out = new Float32Array(Math.max(1, Math.floor(samples.length / ratio)));
    for (let i = 0; i < out.length; i++) {
      const pos = i * ratio;
      const i0 = Math.min(samples.length - 1, Math.floor(pos));
      out[i] = samples[i0];
    }
    samples = out;
  }
  const chunks = chunker.feed(samples);
  if (chunks.length) queue.push(...chunks);
  void drain();
}

export async function stopWhisperChunks(): Promise<string> {
  const myGen = gen;
  const last = chunker?.flush() ?? null;
  if (last) queue.push(last);
  chunker = null;
  while (busy || queue.length) {
    if (myGen !== gen) break;
    await drain();
    if (busy) await new Promise((r) => setTimeout(r, 40));
  }
  const text = join(committed, pending);
  stopWhisperChunksSync();
  return text;
}

function stopWhisperChunksSync(): void {
  gen += 1;
  chunker = null;
  onText = null;
  spec = null;
  committed = '';
  pending = '';
  busy = false;
  queue = [];
}

async function drain(): Promise<void> {
  if (busy || !spec || queue.length === 0) return;
  const slice = queue.shift();
  if (!slice || slice.length === 0) return;
  busy = true;
  const model = spec;
  const lang = language;
  const cb = onText;
  try {
    const uri = await writeWavFromFloat32([slice], 16000);
    const res = await transcribeWithModel(uri, model, lang, false);
    const raw = (res.text || '').trim();
    if (raw) await accept(raw, cb);
  } catch {
    // keep going; a failed chunk is dropped, later audio still transcribes
  } finally {
    busy = false;
  }
  if (queue.length) await drain();
}

async function accept(raw: string, cb: TextCb | null): Promise<void> {
  pending = join(pending, raw);
  cb?.(committed, pending);
  const llm = LLM_MODELS[0];
  if (getAutoPolish() && llm && llmInstalled(llm)) {
    try {
      const cleaned = (await cleanupWithLLM(llm, raw, { previous: committed, hotwords: biasTerms() })).trim();
      committed = join(committed, cleaned || raw);
    } catch {
      committed = join(committed, raw);
    }
  } else {
    committed = join(committed, raw);
  }
  pending = '';
  cb?.(committed, pending);
}

function join(a: string, b: string): string {
  const left = a.trim();
  const right = b.trim();
  if (!left) return right;
  if (!right) return left;
  return `${left} ${right}`.replace(/\s+/g, ' ');
}
