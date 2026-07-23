import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { NativeModules } from 'react-native';
import { listBundledArchives, extractArchive } from 'react-native-sherpa-onnx/extraction';
import type { CatalogModel } from './catalog';

// On-device punctuation restoration for engines that emit unpunctuated text.
// Native side wraps sherpa-onnx OnlinePunctuation (CNN-BiLSTM). Model pulled
// from k2-fsa releases, same mechanism as the NeMo/diarization models.

type Native = {
  isAvailable(): Promise<boolean>;
  addPunctuation(text: string, cnnBilstm: string, bpeVocab: string): Promise<string>;
};

const native = NativeModules.ScribePunctuator as Native | undefined;
export const punctuationSupported = !!native;

const REL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models';
const ARCHIVE = 'sherpa-onnx-online-punct-en-2024-08-06.tar.bz2';
const SIZE_BYTES = 29 * 1024 * 1024;
export const PUNCTUATION_SIZE_LABEL = '≈ 29 MB';

// Models that already produce punctuation; skip them.
const PUNCTUATED_PREFIXES = ['whisper:', 'cloud', 'nemo:nemotron'];
const PUNCTUATED_IDS = new Set([
  'nemo:nemo-parakeet-tdt-0.6b-v2-en',
  'nemo:nemo-parakeet-tdt-0.6b-v3-multi',
  'nemo:nemo-canary-180m-multi',
]);

/** True for CTC/streaming engines whose output is a lowercase, unpunctuated wall. */
export function needsPunctuation(model: CatalogModel): boolean {
  if (model.kind === 'llm') return false;
  if (PUNCTUATED_IDS.has(model.id)) return false;
  return !PUNCTUATED_PREFIXES.some((p) => model.id.startsWith(p));
}

function abs(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

function rootDir(): Directory {
  const d = new Directory(Paths.document, 'punct');
  if (!d.exists) d.create({ intermediates: true });
  return d;
}

function find(dir: Directory, name: string): string | null {
  for (const entry of dir.list()) {
    if (entry instanceof File) {
      if (entry.name === name) return abs(entry.uri);
    } else if (entry instanceof Directory) {
      const hit = find(entry, name);
      if (hit) return hit;
    }
  }
  return null;
}

function modelPath(): string | null {
  const d = rootDir();
  return d.exists ? find(d, 'model.onnx') : null;
}

function vocabPath(): string | null {
  const d = rootDir();
  return d.exists ? find(d, 'bpe.vocab') : null;
}

export function punctuationInstalled(): boolean {
  return !!modelPath() && !!vocabPath();
}

export async function downloadPunctuationModel(
  onProgress?: (ratio: number) => void,
  signal?: AbortSignal
): Promise<void> {
  if (punctuationInstalled()) return;
  const dir = rootDir();
  const archiveFile = new File(dir, ARCHIVE);
  if (archiveFile.exists) archiveFile.delete();

  let total = 0;
  const task = new DownloadTask(`${REL}/${ARCHIVE}`, archiveFile, {
    signal,
    onProgress: ({ bytesWritten, totalBytes }) => {
      if (totalBytes > 0) total = totalBytes;
      const t = total > 0 ? total : SIZE_BYTES;
      if (t > 0) onProgress?.((bytesWritten / t) * 0.9);
    },
  });
  const file = await task.downloadAsync();
  if (!file) throw new Error('Punctuation model download did not complete');

  const archives = await listBundledArchives(abs(dir.uri));
  const arch = archives.find((a) => a.archivePath.endsWith(ARCHIVE)) ?? archives[0];
  if (!arch) {
    archiveFile.delete();
    throw new Error('Punctuation archive not found after download');
  }
  const res = await extractArchive(arch, abs(dir.uri), {
    force: true,
    showNotificationsEnabled: false,
    signal,
    onProgress: (e) => onProgress?.(0.9 + (Math.max(0, Math.min(100, e.percent)) / 100) * 0.1),
  });
  if (!res.success) {
    if (dir.exists) dir.delete();
    throw new Error(res.reason ?? 'Punctuation model extraction failed. Try again.');
  }
  if (archiveFile.exists) archiveFile.delete();
  onProgress?.(1);
}

export function deletePunctuationModel(): void {
  const d = rootDir();
  if (d.exists) d.delete();
}

/** Adds punctuation/casing to raw text. No-op if unsupported or not installed. */
export async function punctuate(text: string): Promise<string> {
  if (!native || !text.trim()) return text;
  const model = modelPath();
  const vocab = vocabPath();
  if (!model || !vocab) return text;
  try {
    const out = await native.addPunctuation(text, model, vocab);
    return out?.trim() ? out : text;
  } catch {
    return text;
  }
}
