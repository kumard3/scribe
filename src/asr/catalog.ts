import { MODELS, formatMB } from './registry';
import { ModelSpec } from './types';
import { NEMO_MODELS, NemoModelSpec } from './nemo';

export type ModelKind = 'system' | 'whisper' | 'nemo' | 'sherpa' | 'cloud';

export type CatalogModel = {
  id: string; // namespaced selection id
  kind: ModelKind;
  label: string;
  note: string;
  sizeLabel: string;
  /** true = streams live as you speak; false = record then transcribe (batch). */
  live: boolean;
  // Consumer-facing presentation (set for the curated picks; the rest fall back
  // to label/note under "More models").
  title?: string;
  tagline?: string;
  chip?: string;
  featured?: boolean;
  whisper?: ModelSpec;
  nemo?: NemoModelSpec;
  sherpaId?: string;
};

export const SYSTEM_MODEL_ID = 'system';
export const CLOUD_MODEL_ID = 'cloud';

// What a normal person actually wants to choose between — by purpose, no model
// names. Keyed by namespaced catalog id.
const DISPLAY: Record<string, Pick<CatalogModel, 'title' | 'tagline' | 'chip' | 'featured'>> = {
  system: {
    title: 'Instant',
    tagline: 'No download. Works the moment you start — best for quick notes and messages.',
    chip: 'Recommended',
    featured: true,
  },
  'whisper:whisper-small-en-q5': {
    title: 'Sharper English',
    tagline: 'Cleaner, more accurate English. One-time download, then fully offline.',
    chip: 'More accurate',
    featured: true,
  },
  'whisper:whisper-small': {
    title: 'Many languages',
    tagline: 'Understands 90+ languages including Hindi. One-time download, offline.',
    chip: '90+ languages',
    featured: true,
  },
  'whisper:whisper-large-turbo-q5': {
    title: 'Best quality',
    tagline: 'Highest accuracy with built-in translation. Largest download.',
    chip: 'Pro',
    featured: true,
  },
};

export function buildCatalog(): CatalogModel[] {
  const system: CatalogModel = {
    id: SYSTEM_MODEL_ID,
    kind: 'system',
    label: 'Built-in · Fast',
    note: 'Instant streaming, no download — uses your phone’s on-device speech engine.',
    sizeLabel: 'No download',
    live: true,
  };
  const nemo: CatalogModel[] = NEMO_MODELS.map((m) => ({
    id: `nemo:${m.id}`,
    kind: 'nemo',
    label: m.label,
    note: m.note,
    sizeLabel: formatMB(m.sizeBytes),
    live: !!m.live,
    nemo: m,
  }));
  const whisper: CatalogModel[] = MODELS.map((m) => ({
    id: `whisper:${m.id}`,
    kind: 'whisper',
    label: m.label,
    note: m.note ?? '',
    sizeLabel: formatMB(m.sizeBytes),
    live: true,
    whisper: m,
  }));
  const cloud: CatalogModel = {
    id: CLOUD_MODEL_ID,
    kind: 'cloud',
    label: 'Your API key',
    note: 'OpenAI-compatible cloud transcription. Audio leaves your phone — highest accuracy.',
    sizeLabel: 'BYOK',
    live: false,
  };
  // Sherpa/Moonshine intentionally omitted: the library's model catalog
  // (XDcobra release) is dead (404). NVIDIA NeMo models below are fetched
  // directly from k2-fsa instead. Whisper covers general offline use.
  return [system, ...nemo, ...whisper, cloud].map((m) =>
    DISPLAY[m.id] ? { ...m, ...DISPLAY[m.id] } : m,
  );
}

export function catalogModelById(id: string): CatalogModel | undefined {
  return buildCatalog().find((m) => m.id === id);
}
