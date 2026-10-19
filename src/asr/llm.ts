import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { initLlama, releaseAllLlama, type LlamaContext } from 'llama.rn';
import { chatCloud, cloudChatReady } from './cloud';
import { getCloud, getLLMModelId, getSmartCorrections } from './settings';
import { backtrack } from '../util/corrections';

// On-device LLM for post-processing transcripts, AI Cleanup and
// Summary. It is a POST-PROCESSOR, never a transcription engine: it is install/
// delete only and is invoked on a finished transcript. Inference runs through
// llama.rn (llama.cpp); the GGUF is a single file pulled from Hugging Face.

export type LLMModelSpec = {
  id: string;
  label: string;
  note: string;
  chip: string;
  url: string;
  fileName: string;
  sizeBytes: number;
};

export const LLM_MODELS: LLMModelSpec[] = [
  {
    id: 'gemma-4-e2b',
    label: 'Gemma 4 E2B',
    note: 'Google. The best balance of quality and speed on most phones.',
    chip: 'Recommended',
    url: 'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-E2B-it-Q4_K_M.gguf',
    sizeBytes: 3_106_738_272,
  },
  {
    id: 'gemma-4-e4b',
    label: 'Gemma 4 E4B',
    note: 'Google. Smartest cleanup and summaries. For high-end phones with lots of memory.',
    chip: 'Smartest',
    url: 'https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-E4B-it-Q4_K_M.gguf',
    sizeBytes: 4_977_171_584,
  },
  {
    id: 'gemma-3-1b',
    label: 'Gemma 3 1B',
    note: 'Google. Small and fast, for phones with less memory.',
    chip: 'Fast',
    url: 'https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf',
    fileName: 'gemma-3-1b-it-Q4_K_M.gguf',
    sizeBytes: 806_058_272,
  },
  {
    id: 'qwen-2.5-1.5b',
    label: 'Qwen 2.5 1.5B',
    note: 'Alibaba. Small and fast, strongest in plain English.',
    chip: 'Fast',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1_117_320_736,
  },
];

export function llmModelById(id: string): LLMModelSpec | undefined {
  return LLM_MODELS.find((m) => m.id === id);
}

function llmDir(): Directory {
  const d = new Directory(Paths.document, 'llm');
  if (!d.exists) d.create({ intermediates: true });
  return d;
}

export function llmLocalFile(spec: LLMModelSpec): File {
  return new File(llmDir(), spec.fileName);
}

// Tolerant size check: HF/CDN content-length can drift slightly from our pinned
// estimate, so accept anything within 1% of the expected size (a truncated
// download is well below that and still rejected).
export function llmInstalled(spec: LLMModelSpec): boolean {
  const f = llmLocalFile(spec);
  return f.exists && f.size >= spec.sizeBytes * 0.99;
}

export async function downloadLLM(
  spec: LLMModelSpec,
  onProgress?: (ratio: number) => void,
  signal?: AbortSignal
): Promise<File> {
  const dest = llmLocalFile(spec);
  if (llmInstalled(spec)) return dest;
  if (dest.exists) dest.delete();

  let total = 0;
  const task = new DownloadTask(spec.url, dest, {
    signal,
    onProgress: ({ bytesWritten, totalBytes }) => {
      if (totalBytes > 0) total = totalBytes;
      const t = total > 0 ? total : spec.sizeBytes;
      if (t > 0) onProgress?.(bytesWritten / t);
    },
  });
  const file = await task.downloadAsync();
  if (!file) throw new Error(`Download of ${spec.label} did not complete`);

  const expected = total > 0 ? total : spec.sizeBytes;
  if (expected > 0 && file.size < expected * 0.99) {
    file.delete();
    throw new Error(
      `${spec.label} downloaded incompletely (${Math.round(file.size / 1e6)} of ${Math.round(
        expected / 1e6
      )} MB). Check your connection and tap Get again.`
    );
  }
  onProgress?.(1);
  return file;
}

export function deleteLLM(spec: LLMModelSpec): void {
  void release();
  const f = llmLocalFile(spec);
  if (f.exists) f.delete();
}

export function deleteAllLLM(): void {
  void release();
  const d = llmDir();
  if (d.exists) d.delete();
}

export function installedLLMStorageBytes(): number {
  return LLM_MODELS.reduce((sum, m) => {
    const f = llmLocalFile(m);
    return sum + (f.exists ? f.size : 0);
  }, 0);
}

// ---- Inference ----

let ctx: LlamaContext | null = null;
let loadedId: string | null = null;

async function ensureLoaded(spec: LLMModelSpec): Promise<LlamaContext> {
  if (!llmInstalled(spec)) throw new Error(`${spec.label}: download it in Models first.`);
  if (ctx && loadedId === spec.id) return ctx;
  await release();
  ctx = await initLlama({
    model: llmLocalFile(spec).uri,
    n_ctx: 2048,
    n_gpu_layers: 99,
    use_mlock: false,
  });
  loadedId = spec.id;
  return ctx;
}

export async function release(): Promise<void> {
  if (ctx) {
    try {
      await ctx.release();
    } catch {
      await releaseAllLlama().catch(() => {});
    }
    ctx = null;
    loadedId = null;
  }
}

// Gemma's chat template has no separate system role, so the instruction is
// folded into the single user turn for portability across GGUF builds.
async function runLocal(spec: LLMModelSpec, instruction: string, text: string, maxTokens: number) {
  const c = await ensureLoaded(spec);
  const res = await c.completion({
    messages: [{ role: 'user', content: `${instruction}\n\n---\n${text.trim()}` }],
    temperature: 0.2,
    n_predict: maxTokens,
    stop: ['<end_of_turn>', '<|im_end|>'],
  });
  return (res.text ?? '').trim();
}

const CLEANUP =
  'You clean speech-to-text. Do not answer the user. Do not translate.\n\n' +
  'Language:\n' +
  '- Mostly English → clean English. Keep Indian English. Do not Americanize.\n' +
  '- Hindi/English mix or romanized Hindi → WhatsApp Hinglish. No Devanagari.\n' +
  '- Keep the same mix as the input.\n\n' +
  'Rules:\n' +
  '- Keep English words in English spelling (office, client, call, Bolkit, Gemma, chunking).\n' +
  '- Add punctuation. Remove fillers only: um, uh, you know, like (when empty).\n' +
  '- Do not add facts. If a word is unclear, keep the ASR token.\n' +
  '- Prefer HOTWORDS spelling when the audio/text is close.\n' +
  '- Output only the cleaned transcript, nothing else.';

export type CleanupOpts = { previous?: string; hotwords?: string[] };

function cleanupInstruction(opts?: CleanupOpts): string {
  const terms = (opts?.hotwords ?? []).join(', ') || 'Bolkit, Gemma, E2B, chunking, Hinglish, Oriserve, Apex, Swift';
  const prev = (opts?.previous ?? '').trim() || '(none)';
  return (
    `${CLEANUP}\n\nHOTWORDS:\n${terms}\n\nPREVIOUS:\n${prev}\n\n` +
    'Only rewrite the NEW CHUNK. Previous text is context. Do not change it.\n' +
    'OUTPUT (new chunk only):'
  );
}

const SUMMARY =
  'Summarize the following transcript in 2-3 sentences, in the same language as the ' +
  'input. Output only the summary, nothing else.';

export type AI = (instruction: string, text: string, maxTokens: number) => Promise<string>;

export function activeAI(): AI | null {
  const local = llmModelById(getLLMModelId());
  if (local && llmInstalled(local)) return (i, t, n) => runLocal(local, i, t, n);
  const cfg = getCloud();
  return cloudChatReady(cfg) ? (i, t) => chatCloud(cfg, i, t) : null;
}

export async function cleanupWithLLM(ai: AI, text: string, opts?: CleanupOpts): Promise<string> {
  return ai(cleanupInstruction(opts), text, 1024);
}

export async function summarizeWithLLM(ai: AI, text: string): Promise<string> {
  return ai(SUMMARY, text, 256);
}

export async function smartCorrect(text: string): Promise<string> {
  const ai = getSmartCorrections() ? activeAI() : null;
  if (!ai || !text.trim()) return text;
  return backtrack(text, (i, t) => ai(i, t, 512));
}
