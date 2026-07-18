import type { TimedUnit } from './types';

/**
 * Rebuilds word-level units (with timings) from sherpa-onnx token output.
 * sherpa tokens are sentencepiece subwords: '▁' marks a word start, bare tokens
 * continue the previous word. Timestamps are per-token start times in seconds.
 */
export function unitsFromTokens(tokens: string[], timestamps: number[]): TimedUnit[] {
  const units: TimedUnit[] = [];
  let cur: TimedUnit | null = null;
  for (let i = 0; i < tokens.length; i++) {
    const raw = tokens[i] ?? '';
    const t: number = typeof timestamps[i] === 'number' ? timestamps[i] : cur ? cur.end : 0;
    const startsWord = raw.startsWith('▁') || raw.startsWith(' ');
    const piece = raw.replace(/▁/g, '').trim();
    if (!piece) continue;
    if (startsWord || !cur) {
      if (cur) {
        cur.end = t;
        units.push(cur);
      }
      cur = { start: t, end: t + 0.25, text: piece };
    } else {
      cur.text += piece;
      cur.end = t + 0.25;
    }
  }
  if (cur && cur.text) units.push(cur);
  return units;
}
