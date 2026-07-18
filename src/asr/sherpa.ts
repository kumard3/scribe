import { createSTT, type SttEngine, type STTModelType } from 'react-native-sherpa-onnx/stt';
import {
  ModelCategory,
  listModelsByCategory,
  downloadModelByCategory,
  isModelDownloadedByCategory,
  getLocalModelPathByCategory,
} from 'react-native-sherpa-onnx/download';
import type { TimedUnit } from './types';
import { unitsFromTokens } from './units';

function stripScheme(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

export type SherpaModelSpec = {
  id: string;
  label: string;
  note: string;
  languages: string;
  modelType: STTModelType;
  matches: (catalogId: string) => boolean;
};

export const SHERPA_MODELS: SherpaModelSpec[] = [
  {
    id: 'moonshine-en',
    label: 'Moonshine · English',
    note: 'Lightweight, fast English',
    languages: 'English',
    modelType: 'moonshine',
    matches: (c) => c.toLowerCase().includes('moonshine'),
  },
];

export function sherpaModelById(id: string): SherpaModelSpec | undefined {
  return SHERPA_MODELS.find((m) => m.id === id);
}

const catalogIdCache: Record<string, string> = {};

async function resolveCatalogId(spec: SherpaModelSpec): Promise<string | null> {
  if (catalogIdCache[spec.id]) return catalogIdCache[spec.id];
  const models = await listModelsByCategory(ModelCategory.Stt);
  const hits = models.filter((m) => spec.matches(m.id));
  if (!hits.length) return null;
  const pick =
    hits.find((m) => /int8/i.test(m.id) && /tiny/i.test(m.id)) ??
    hits.find((m) => /int8/i.test(m.id)) ??
    hits[0];
  catalogIdCache[spec.id] = pick.id;
  return pick.id;
}

export async function sherpaInstalled(spec: SherpaModelSpec): Promise<boolean> {
  const id = await resolveCatalogId(spec);
  if (!id) return false;
  return isModelDownloadedByCategory(ModelCategory.Stt, id);
}

export async function downloadSherpa(
  spec: SherpaModelSpec,
  onProgress?: (ratio: number) => void
): Promise<void> {
  const id = await resolveCatalogId(spec);
  if (!id) throw new Error(`${spec.label}: not found in the sherpa-onnx catalog`);
  await downloadModelByCategory(ModelCategory.Stt, id, {
    onProgress: (p: { bytesDownloaded?: number; totalBytes?: number; progress?: number }) => {
      const ratio =
        typeof p?.progress === 'number'
          ? p.progress
          : p?.totalBytes
            ? (p.bytesDownloaded ?? 0) / p.totalBytes
            : 0;
      onProgress?.(Math.max(0, Math.min(1, ratio)));
    },
  });
}

let engine: SttEngine | null = null;
let loadedId: string | null = null;

async function ensureEngine(spec: SherpaModelSpec): Promise<SttEngine> {
  const id = await resolveCatalogId(spec);
  if (!id) throw new Error(`${spec.label}: not in catalog`);
  if (loadedId !== spec.id || !engine) {
    if (engine) {
      await engine.destroy();
      engine = null;
    }
    const dir = await getLocalModelPathByCategory(ModelCategory.Stt, id);
    if (!dir) throw new Error(`${spec.label}: not downloaded yet`);
    engine = await createSTT({
      modelPath: { type: 'file', path: dir },
      modelType: spec.modelType,
      preferInt8: true,
    });
    loadedId = spec.id;
  }
  return engine;
}

export async function transcribeWithSherpa(spec: SherpaModelSpec, wavUri: string): Promise<string> {
  const e = await ensureEngine(spec);
  const res = await e.transcribeFile(stripScheme(wavUri));
  return (res.text ?? '').trim();
}

export async function transcribeDetailedWithSherpa(
  spec: SherpaModelSpec,
  wavUri: string
): Promise<{ text: string; units: TimedUnit[] }> {
  const e = await ensureEngine(spec);
  const res = await e.transcribeFile(stripScheme(wavUri));
  return {
    text: (res.text ?? '').trim(),
    units: unitsFromTokens(res.tokens ?? [], res.timestamps ?? []),
  };
}

export async function unloadSherpa(): Promise<void> {
  if (engine) {
    await engine.destroy();
    engine = null;
    loadedId = null;
  }
}
