import { Directory, File, Paths, DownloadTask } from 'expo-file-system';
import { NativeModules } from 'react-native';
import { listBundledArchives, extractArchive } from 'react-native-sherpa-onnx/extraction';
import type { TimedUnit } from './types';

// On-device speaker diarization (who-said-what). Native side calls sherpa-onnx
// OfflineSpeakerDiarization (pyannote segmentation + speaker embedding +
// clustering). Models are pulled from k2-fsa's public releases the same way the
// NeMo models are (the library's own catalog release is dead, see nemo.ts).

type Native = {
  isAvailable(): Promise<boolean>;
  diarize(
    wavPath: string,
    segModel: string,
    embModel: string,
    numSpeakers: number,
    threshold: number
  ): Promise<{ start: number; end: number; speaker: number }[]>;
};

const native = NativeModules.ScribeDiarizer as Native | undefined;
export const diarizationSupported = !!native;

export type SpeakerSegment = { start: number; end: number; speaker: number };

const SEG_REL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models';
const EMB_REL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models';

const SEG = {
  archive: 'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
  sizeBytes: 6125744,
};
const EMB = {
  file: '3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx',
  sizeBytes: 27726574,
};

export const DIARIZATION_DOWNLOAD_LABEL = 'Speaker model';
export const DIARIZATION_SIZE_LABEL = '≈ 33 MB';

function abs(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

function rootDir(): Directory {
  const d = new Directory(Paths.document, 'diar');
  if (!d.exists) d.create({ intermediates: true });
  return d;
}

function findOnnx(dir: Directory, name: string): string | null {
  for (const entry of dir.list()) {
    if (entry instanceof File) {
      if (entry.name === name || entry.name.endsWith('.onnx')) return abs(entry.uri);
    } else if (entry instanceof Directory) {
      const hit = findOnnx(entry, name);
      if (hit) return hit;
    }
  }
  return null;
}

function segDir(): Directory {
  return new Directory(rootDir(), 'segmentation');
}

function embFile(): File {
  return new File(rootDir(), EMB.file);
}

export function segModelPath(): string | null {
  const d = segDir();
  if (!d.exists) return null;
  return findOnnx(d, 'model.onnx');
}

export function embModelPath(): string | null {
  const f = embFile();
  return f.exists ? abs(f.uri) : null;
}

export function diarizationInstalled(): boolean {
  return !!segModelPath() && !!embModelPath();
}

export async function downloadDiarizationModels(
  onProgress?: (ratio: number) => void,
  signal?: AbortSignal
): Promise<void> {
  // 1. Segmentation archive (pyannote) -> extract.
  if (!segModelPath()) {
    const dir = segDir();
    if (!dir.exists) dir.create({ intermediates: true });
    const archiveFile = new File(dir, SEG.archive);
    if (archiveFile.exists) archiveFile.delete();

    let total = 0;
    const task = new DownloadTask(`${SEG_REL}/${SEG.archive}`, archiveFile, {
      signal,
      onProgress: ({ bytesWritten, totalBytes }) => {
        if (totalBytes > 0) total = totalBytes;
        const t = total > 0 ? total : SEG.sizeBytes;
        if (t > 0) onProgress?.((bytesWritten / t) * 0.18);
      },
    });
    const file = await task.downloadAsync();
    if (!file) throw new Error('Segmentation model download did not complete');

    const archives = await listBundledArchives(abs(dir.uri));
    const arch = archives.find((a) => a.archivePath.endsWith(SEG.archive)) ?? archives[0];
    if (!arch) {
      archiveFile.delete();
      throw new Error('Segmentation archive not found after download');
    }
    const res = await extractArchive(arch, abs(dir.uri), {
      force: true,
      showNotificationsEnabled: false,
      signal,
      onProgress: (e) => onProgress?.(0.18 + (Math.max(0, Math.min(100, e.percent)) / 100) * 0.05),
    });
    if (!res.success) {
      if (dir.exists) dir.delete();
      throw new Error(res.reason ?? 'Segmentation model extraction failed. Try again.');
    }
    if (archiveFile.exists) archiveFile.delete();
  }

  // 2. Speaker-embedding model (single .onnx).
  if (!embModelPath()) {
    const dest = embFile();
    if (dest.exists) dest.delete();
    let total = 0;
    const task = new DownloadTask(`${EMB_REL}/${EMB.file}`, dest, {
      signal,
      onProgress: ({ bytesWritten, totalBytes }) => {
        if (totalBytes > 0) total = totalBytes;
        const t = total > 0 ? total : EMB.sizeBytes;
        if (t > 0) onProgress?.(0.23 + (bytesWritten / t) * 0.77);
      },
    });
    const file = await task.downloadAsync();
    if (!file) throw new Error('Speaker model download did not complete');
  }
  onProgress?.(1);
}

export function deleteDiarizationModels(): void {
  const d = rootDir();
  if (d.exists) d.delete();
}

/**
 * Runs diarization on a finished WAV. `numSpeakers` <= 0 lets the clusterer
 * decide the count automatically.
 */
export async function diarizeFile(
  wavPath: string,
  opts?: { numSpeakers?: number; threshold?: number }
): Promise<SpeakerSegment[]> {
  if (!native) throw new Error('Speaker identification is not available in this build');
  const seg = segModelPath();
  const emb = embModelPath();
  if (!seg || !emb) throw new Error('Speaker model not downloaded');
  const res = await native.diarize(
    wavPath,
    seg,
    emb,
    opts?.numSpeakers ?? 0,
    opts?.threshold ?? 0.5
  );
  return res ?? [];
}

function overlap(a0: number, a1: number, b0: number, b1: number): number {
  return Math.max(0, Math.min(a1, b1) - Math.max(a0, b0));
}

function speakerFor(unit: TimedUnit, diar: SpeakerSegment[]): number {
  let best = -1;
  let bestOverlap = 0;
  let nearest = diar[0]?.speaker ?? 0;
  let nearestGap = Infinity;
  for (const s of diar) {
    const ov = overlap(unit.start, unit.end, s.start, s.end);
    if (ov > bestOverlap) {
      bestOverlap = ov;
      best = s.speaker;
    }
    const mid = (unit.start + unit.end) / 2;
    const gap = mid < s.start ? s.start - mid : mid > s.end ? mid - s.end : 0;
    if (gap < nearestGap) {
      nearestGap = gap;
      nearest = s.speaker;
    }
  }
  return best >= 0 ? best : nearest;
}

export type SpeakerTurn = { speaker: number; text: string };

export function speakerLabel(speaker: number): string {
  return `Speaker ${speaker + 1}`;
}

/**
 * Attributes transcript text to speakers. Uses per-segment timings when the
 * engine gave them; otherwise distributes the words across the diarization
 * turns proportionally to their duration (rough, but keeps turn-taking).
 */
export function buildSpeakerTurns(
  text: string,
  units: TimedUnit[] | undefined,
  diar: SpeakerSegment[]
): SpeakerTurn[] {
  if (!diar.length) return text.trim() ? [{ speaker: 0, text: text.trim() }] : [];

  if (units && units.length) {
    const turns: SpeakerTurn[] = [];
    for (const u of units) {
      const spk = speakerFor(u, diar);
      const piece = u.text.trim();
      if (!piece) continue;
      const last = turns[turns.length - 1];
      if (last && last.speaker === spk) last.text += ' ' + piece;
      else turns.push({ speaker: spk, text: piece });
    }
    return turns.map((t) => ({ ...t, text: collapse(t.text) }));
  }

  // No timings, split words across turns by duration share.
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const ordered = [...diar].sort((a, b) => a.start - b.start);
  const totalDur = ordered.reduce((s, d) => s + Math.max(0, d.end - d.start), 0) || 1;
  const turns: SpeakerTurn[] = [];
  let idx = 0;
  ordered.forEach((d, i) => {
    const share = Math.max(0, d.end - d.start) / totalDur;
    const count = i === ordered.length - 1 ? words.length - idx : Math.round(share * words.length);
    const slice = words.slice(idx, idx + count);
    idx += count;
    if (!slice.length) return;
    const last = turns[turns.length - 1];
    if (last && last.speaker === d.speaker) last.text += ' ' + slice.join(' ');
    else turns.push({ speaker: d.speaker, text: slice.join(' ') });
  });
  return turns;
}

function collapse(s: string): string {
  return s.replace(/\s+/g, ' ').replace(/\s+([,.!?;:])/g, '$1').trim();
}

export function turnsToText(turns: SpeakerTurn[]): string {
  if (turns.length <= 1) return turns[0]?.text ?? '';
  return turns.map((t) => `${speakerLabel(t.speaker)}: ${t.text}`).join('\n\n');
}

export function speakerCount(diar: SpeakerSegment[]): number {
  return new Set(diar.map((d) => d.speaker)).size;
}
