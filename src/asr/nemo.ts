import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { createSTT, createStreamingSTT, type SttEngine, type STTModelType } from 'react-native-sherpa-onnx/stt';
import { listBundledArchives, extractArchive } from 'react-native-sherpa-onnx/extraction';
import { listModelsAtPath } from 'react-native-sherpa-onnx';
import type { TimedUnit } from './types';
import { unitsFromTokens } from './units';
import { decodeWavTo16kMono } from '../audio/wav';

// NVIDIA NeMo (Parakeet / Canary) models, hosted by k2-fsa as prebuilt
// sherpa-onnx archives. We download + extract them directly: the library's
// own model catalog (XDcobra release) is dead (404), so the catalog-based
// path in sherpa.ts can't reach these.
const REL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

function abs(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

export type NemoModelSpec = {
  id: string;
  label: string;
  note: string;
  languages: string;
  archive: string;
  sizeBytes: number;
  modelType: STTModelType;
  /** true = streaming/online model (live), used via createStreamingSTT. */
  live?: boolean;
};

export const NEMO_MODELS: NemoModelSpec[] = [
  // ---- Streaming / live (sherpa createStreamingSTT) ----
  // NOTE: sherpa's OnlineRecognizer only supports these online model types:
  // transducer, paraformer, zipformer2_ctc, nemo_ctc, tone_ctc. NVIDIA's
  // Parakeet "unified streaming" detects as nemo_transducer → NOT streamable
  // here, so it's intentionally omitted. Zipformer is a plain transducer.
  {
    id: 'zipformer-streaming-en',
    label: 'Zipformer Streaming · English',
    note: 'Live · fast · lightweight',
    languages: 'English',
    archive: 'sherpa-onnx-streaming-zipformer-en-2023-06-21-mobile.tar.bz2',
    sizeBytes: 365748162,
    modelType: 'transducer',
    live: true,
  },
  {
    id: 'nemotron-3.5-streaming-multi',
    label: 'Nemotron 3.5 Streaming · Multilingual',
    note: 'NVIDIA · live · 40 languages · auto-detect · punctuated',
    languages: 'Multilingual (40 locales)',
    archive: 'sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2',
    sizeBytes: 473894907,
    modelType: 'auto',
    live: true,
  },
  {
    id: 'nemotron-streaming-en',
    label: 'Nemotron Streaming · English',
    note: 'NVIDIA · live · instant · punctuated',
    languages: 'English',
    archive: 'sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2',
    sizeBytes: 463945051,
    modelType: 'auto',
    live: true,
  },
  // ---- Offline / batch (record → transcribe) ----
  {
    id: 'nemo-parakeet-ctc-110m-en',
    label: 'Parakeet 110M · English',
    note: 'NVIDIA · fast · offline',
    languages: 'English',
    archive: 'sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8.tar.bz2',
    sizeBytes: 104337827,
    modelType: 'nemo_ctc',
  },
  {
    id: 'nemo-parakeet-tdt-0.6b-v2-en',
    label: 'Parakeet 0.6B v2 · English',
    note: 'NVIDIA · best English accuracy',
    languages: 'English',
    archive: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2',
    sizeBytes: 482468385,
    modelType: 'auto',
  },
  {
    id: 'nemo-parakeet-tdt-0.6b-v3-multi',
    label: 'Parakeet 0.6B v3 · Multilingual',
    note: 'NVIDIA · 25 languages',
    languages: 'Multilingual (EU)',
    archive: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    sizeBytes: 487170055,
    modelType: 'auto',
  },
  {
    id: 'nemo-canary-180m-multi',
    label: 'Canary 180M · Multilingual',
    note: 'NVIDIA · EN/ES/DE/FR + translation',
    languages: 'EN/ES/DE/FR',
    archive: 'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8.tar.bz2',
    sizeBytes: 153692328,
    modelType: 'canary',
  },
  {
    id: 'moonshine-tiny-en',
    label: 'Moonshine Tiny · English',
    note: 'Useful Sensors · tiny · offline',
    languages: 'English',
    archive: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2',
    sizeBytes: 29858559,
    modelType: 'moonshine',
  },
  {
    id: 'moonshine-base-en',
    label: 'Moonshine Base · English',
    note: 'Useful Sensors · balanced · offline',
    languages: 'English',
    archive: 'sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2',
    sizeBytes: 111266225,
    modelType: 'moonshine',
  },
];

export function nemoModelById(id: string): NemoModelSpec | undefined {
  return NEMO_MODELS.find((m) => m.id === id);
}

function rootDir(): Directory {
  const d = new Directory(Paths.document, 'nemo');
  if (!d.exists) d.create({ intermediates: true });
  return d;
}

function modelDirFor(spec: NemoModelSpec): Directory {
  return new Directory(rootDir(), spec.id);
}

async function resolveModelFolder(extractedRoot: Directory): Promise<string | null> {
  const found = await listModelsAtPath(abs(extractedRoot.uri), true);
  const pick = found.find((f) => f.hint === 'stt') ?? found[0];
  if (!pick) return null;
  if (pick.folder.startsWith('/')) return pick.folder;
  return abs(new Directory(extractedRoot, pick.folder).uri);
}

export async function nemoModelDir(spec: NemoModelSpec): Promise<string | null> {
  const dir = modelDirFor(spec);
  if (!dir.exists) return null;
  try {
    return await resolveModelFolder(dir);
  } catch {
    return null;
  }
}

export async function nemoInstalled(spec: NemoModelSpec): Promise<boolean> {
  const dir = modelDirFor(spec);
  if (!dir.exists) return false;
  try {
    return !!(await resolveModelFolder(dir));
  } catch {
    return false;
  }
}

export async function downloadNemo(
  spec: NemoModelSpec,
  onProgress?: (ratio: number) => void,
  signal?: AbortSignal
): Promise<void> {
  const dir = modelDirFor(spec);
  if (!dir.exists) dir.create({ intermediates: true });

  const archiveFile = new File(dir, spec.archive);
  if (archiveFile.exists) archiveFile.delete();

  let total = 0;
  const task = new DownloadTask(`${REL}/${spec.archive}`, archiveFile, {
    signal,
    onProgress: ({ bytesWritten, totalBytes }) => {
      if (totalBytes > 0) total = totalBytes;
      const t = total > 0 ? total : spec.sizeBytes;
      if (t > 0) onProgress?.((bytesWritten / t) * 0.9);
    },
  });
  const file = await task.downloadAsync();
  if (!file) throw new Error(`Download of ${spec.label} did not complete`);

  // Reject truncated downloads — a partial archive fails to extract with an
  // opaque "failed to open archive file". Make the user retry instead.
  const expected = total > 0 ? total : spec.sizeBytes;
  if (expected > 0 && file.size < expected * 0.995) {
    file.delete();
    throw new Error(
      `${spec.label} downloaded incompletely (${Math.round(file.size / 1e6)} of ${Math.round(
        expected / 1e6
      )} MB). Check your connection and tap Get again.`
    );
  }

  const archives = await listBundledArchives(abs(dir.uri));
  const arch = archives.find((a) => a.archivePath.endsWith(spec.archive)) ?? archives[0];
  if (!arch) {
    if (archiveFile.exists) archiveFile.delete();
    throw new Error(`${spec.label}: archive not found after download`);
  }

  let res;
  try {
    res = await extractArchive(arch, abs(dir.uri), {
      force: true,
      showNotificationsEnabled: false,
      signal,
      onProgress: (e) => onProgress?.(0.9 + (Math.max(0, Math.min(100, e.percent)) / 100) * 0.1),
    });
  } catch (e) {
    if (dir.exists) dir.delete();
    throw e;
  }
  if (!res.success) {
    if (dir.exists) dir.delete();
    throw new Error(res.reason ?? `${spec.label}: extraction failed — tap Get to retry.`);
  }

  if (archiveFile.exists) archiveFile.delete();
  onProgress?.(1);
}

let engine: SttEngine | null = null;
let loadedId: string | null = null;

async function ensureEngine(spec: NemoModelSpec): Promise<SttEngine> {
  const dir = modelDirFor(spec);
  if (!dir.exists) throw new Error(`${spec.label}: download it in Models first.`);
  if (loadedId !== spec.id || !engine) {
    if (engine) {
      await engine.destroy();
      engine = null;
      loadedId = null;
    }
    const folder = await resolveModelFolder(dir);
    if (!folder) throw new Error(`${spec.label}: model files missing — re-download.`);
    engine = await createSTT({
      modelPath: { type: 'file', path: folder },
      modelType: spec.modelType,
      preferInt8: true,
    });
    loadedId = spec.id;
  }
  return engine;
}

// Streaming-only models have no offline recognizer, so a recorded file is
// decoded and pushed through the online stream; trailing silence flushes the tail.
async function transcribeFileStreaming(spec: NemoModelSpec, wavUri: string): Promise<string> {
  const dir = await nemoModelDir(spec);
  if (!dir) throw new Error(`${spec.label}: download it in Models first.`);
  const eng = await createStreamingSTT({
    modelPath: { type: 'file', path: dir },
    modelType: spec.modelType,
    numThreads: 2,
    enableEndpoint: true,
  });
  const stream = await eng.createStream();
  try {
    const samples = await decodeWavTo16kMono(wavUri);
    let committed = '';
    const CHUNK = 8000; // 0.5 s @ 16 kHz
    for (let i = 0; i < samples.length; i += CHUNK) {
      const slice = samples.subarray(i, Math.min(i + CHUNK, samples.length));
      const { result, isEndpoint } = await stream.processAudioChunk(slice, 16000);
      if (isEndpoint) {
        const partial = (result.text ?? '').trim();
        if (partial) committed = (committed + ' ' + partial).trim();
        await stream.reset();
      }
    }
    const { result } = await stream.processAudioChunk(new Float32Array(8000), 16000);
    const partial = (result.text ?? '').trim();
    return (committed + ' ' + partial).trim();
  } finally {
    try { await stream.release(); } catch {}
    try { await eng.destroy(); } catch {}
  }
}

export async function transcribeWithNemo(spec: NemoModelSpec, wavUri: string): Promise<string> {
  if (spec.live) return transcribeFileStreaming(spec, wavUri);
  const e = await ensureEngine(spec);
  const res = await e.transcribeFile(abs(wavUri));
  return (res.text ?? '').trim();
}

export async function transcribeDetailedWithNemo(
  spec: NemoModelSpec,
  wavUri: string
): Promise<{ text: string; units: TimedUnit[] }> {
  if (spec.live) {
    return { text: await transcribeFileStreaming(spec, wavUri), units: [] };
  }
  const e = await ensureEngine(spec);
  const res = await e.transcribeFile(abs(wavUri));
  return {
    text: (res.text ?? '').trim(),
    units: unitsFromTokens(res.tokens ?? [], res.timestamps ?? []),
  };
}

export function deleteNemo(spec: NemoModelSpec): void {
  const dir = modelDirFor(spec);
  if (dir.exists) dir.delete();
}

export async function unloadNemo(): Promise<void> {
  if (engine) {
    await engine.destroy();
    engine = null;
    loadedId = null;
  }
}

export function deleteAllNemo(): void {
  const d = rootDir();
  if (d.exists) d.delete();
}
