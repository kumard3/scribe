import type { SpeakerTurn } from './asr/diarize';

export function speakerName(speaker: number, names?: Record<number, string>): string {
  return names?.[speaker] ?? `Speaker ${speaker + 1}`;
}

/** One speaker means nobody needs a label. */
export function turnsToText(turns: SpeakerTurn[], names?: Record<number, string>): string {
  if (turns.length <= 1) return turns[0]?.text ?? '';
  return turns.map((t) => `${speakerName(t.speaker, names)}: ${t.text}`).join('\n\n');
}

export function meetingTitle(at: number): string {
  const d = new Date(at);
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const day = d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  return `Meeting ${day}, ${time}`;
}

export function durationLabel(sec: number): string {
  const s = Math.max(0, Math.round(sec));
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}:${String(s % 60).padStart(2, '0')}`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
