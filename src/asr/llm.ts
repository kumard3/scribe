import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { initLlama, releaseAllLlama, type LlamaContext } from 'llama.rn';

// On-device LLM (Gemma 4 E2B) for post-processing transcripts — AI Cleanup and
// Summary. It is a POST-PROCESSOR, never a transcription engine: it is install/
// delete only and is invoked on a finished transcript. Inference runs through
// llama.rn (llama.cpp); the GGUF is a single file pulled from Hugging Face.

export type LLMModelSpec = {
  id: string;
  label: string;
  note: string;
  url: string;
  fileName: string;
  sizeBytes: number;
};

export const LLM_MODELS: LLMModelSpec[] = [
  {
    id: 'gemma-4-e2b',
    label: 'Gemma 4 · E2B (cleanup & summary)',
    note: 'Google · on-device text AI · offline',
    url: 'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf',
    fileName: 'gemma-4-E2B-it-Q4_K_M.gguf',
    sizeBytes: 3_110_000_000,
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
async function run(spec: LLMModelSpec, instruction: string, text: string, maxTokens: number) {
  const c = await ensureLoaded(spec);
  const res = await c.completion({
    messages: [{ role: 'user', content: `${instruction}\n\n---\n${text.trim()}` }],
    temperature: 0.2,
    n_predict: maxTokens,
    stop: ['<end_of_turn>'],
  });
  return (res.text ?? '').trim();
}

const CLEANUP =
  'Rewrite the following transcript with correct punctuation and capitalization. ' +
  'Remove filler words and false starts. Keep all of the meaning and the original ' +
  'language (including Hindi or Hinglish). Output only the rewritten text, nothing else.';

const SUMMARY =
  'Summarize the following transcript in 2-3 sentences, in the same language as the ' +
  'input. Output only the summary, nothing else.';

export async function cleanupWithLLM(spec: LLMModelSpec, text: string): Promise<string> {
  return run(spec, CLEANUP, text, 1024);
}

export async function summarizeWithLLM(spec: LLMModelSpec, text: string): Promise<string> {
  return run(spec, SUMMARY, text, 256);
}
