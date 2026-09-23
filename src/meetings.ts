import { Directory, File, Paths } from 'expo-file-system';
import type { SpeakerTurn } from './asr/diarize';
import { meetingTitle, speakerName, turnsToText } from './meetingFormat';

export { durationLabel, speakerName } from './meetingFormat';

export type Meeting = {
  id: string;
  title: string;
  createdAt: number;
  durationSec: number;
  language: string;
  transcript: string;
  turns?: SpeakerTurn[];
  speakerNames?: Record<number, string>;
  summary?: string;
  hasAudio: boolean;
};

function root(): Directory {
  return new Directory(Paths.document, 'meetings');
}

function dir(id: string): Directory {
  return new Directory(root(), id);
}

function metaFile(id: string): File {
  return new File(dir(id), 'meeting.json');
}

export function audioFile(id: string): File {
  return new File(dir(id), 'audio.wav');
}

function read(id: string): Meeting | null {
  try {
    const f = metaFile(id);
    if (!f.exists) return null;
    const m = JSON.parse(f.textSync()) as Meeting;
    return m && m.id ? m : null;
  } catch {
    return null;
  }
}

export function listMeetings(): Meeting[] {
  try {
    const r = root();
    if (!r.exists) return [];
    return r
      .list()
      .map((e) => read(e.name))
      .filter((m): m is Meeting => !!m)
      .sort((a, b) => b.createdAt - a.createdAt);
  } catch {
    return [];
  }
}

export function getMeeting(id: string): Meeting | null {
  return read(id);
}

function write(m: Meeting): void {
  const d = dir(m.id);
  if (!d.exists) d.create({ intermediates: true });
  const f = metaFile(m.id);
  if (!f.exists) f.create();
  f.write(JSON.stringify(m));
}

/** Saves a finished recording as a meeting, moving the WAV into its folder.
 *  The audio is kept so the transcript can be replayed and re-summarized. */
export function saveMeeting(input: {
  transcript: string;
  turns?: SpeakerTurn[] | null;
  language: string;
  durationSec: number;
  audioUri?: string | null;
  title?: string;
}): Meeting {
  const createdAt = Date.now();
  const id = `${createdAt}-${Math.round(Math.random() * 1e6)}`;
  const d = dir(id);
  d.create({ intermediates: true });

  let hasAudio = false;
  if (input.audioUri) {
    try {
      new File(input.audioUri).moveSync(audioFile(id));
      hasAudio = true;
    } catch {
      hasAudio = false;
    }
  }

  const meeting: Meeting = {
    id,
    title: input.title?.trim() || meetingTitle(createdAt),
    createdAt,
    durationSec: Math.max(0, Math.round(input.durationSec)),
    language: input.language,
    transcript: input.transcript,
    turns: input.turns ?? undefined,
    hasAudio,
  };
  write(meeting);
  return meeting;
}

export function updateMeeting(id: string, patch: Partial<Meeting>): Meeting | null {
  const m = read(id);
  if (!m) return null;
  const next = { ...m, ...patch, id: m.id };
  write(next);
  return next;
}

export function renameSpeaker(id: string, speaker: number, name: string): Meeting | null {
  const m = read(id);
  if (!m) return null;
  const names = { ...(m.speakerNames ?? {}) };
  const clean = name.trim();
  if (clean) names[speaker] = clean;
  else delete names[speaker];
  return updateMeeting(id, { speakerNames: names });
}

export function deleteMeeting(id: string): void {
  try {
    const d = dir(id);
    if (d.exists) d.delete();
  } catch {
    /* already gone */
  }
}

export function speakerLabel(m: Meeting, speaker: number): string {
  return speakerName(speaker, m.speakerNames);
}

export function meetingText(m: Meeting): string {
  return m.turns?.length ? turnsToText(m.turns, m.speakerNames) : m.transcript;
}
