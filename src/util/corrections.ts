export const BACKTRACK =
  'You apply a speaker\'s spoken self-corrections to their dictation. When the speaker takes\n' +
  'something back or corrects it ("scratch that", "no wait", "actually", "I mean", "sorry",\n' +
  '"make that", "delete everything I said"), remove the words they took back and the\n' +
  'correction phrase itself, and keep the correction. If they ask to delete everything said so\n' +
  'far, keep only what comes after that request. Do not add, reword, reorder, translate or\n' +
  're-punctuate anything else. If there is no self-correction, return the text unchanged.\n' +
  'Output only the final text.\n\n' +
  'Examples:\n' +
  "In: let's meet at 2 actually 3 pm\n" +
  "Out: let's meet at 3 pm\n" +
  'In: send it to Rahul no wait send it to Priya\n' +
  'Out: send it to Priya\n' +
  'In: no no no delete everything I said till now the meeting is moved to Friday\n' +
  'Out: the meeting is moved to Friday\n' +
  'In: I actually liked the demo\n' +
  'Out: I actually liked the demo';

const CUES =
  /\b(?:scratch that|delete that|ignore that|forget that|delete everything|scratch everything|erase everything|start over|no wait|wait no|actually no|no actually|i meant|i mean|sorry|correction|make that|rather|let me rephrase|oops|actually|no no)\b/gi;

const FILLERS = new Set(['um', 'uh', 'er', 'erm', 'ah', 'hmm']);
const SOFT = new Set(['actually', 'sorry', 'rather', 'oops']);

export function cueCount(text: string): number {
  return text.match(CUES)?.length ?? 0;
}

export function tokens(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/’/g, "'")
    .split(/[^\p{L}\p{N}']+/u)
    .map((t) => t.replace(/^'+|'+$/g, ''))
    .filter((t) => t && !FILLERS.has(t));
}

export function validateBacktrack(raw: string, candidate: string): { ok: boolean; reason: string } {
  const r = tokens(raw);
  const c = tokens(candidate);
  if (!c.length) return { ok: false, reason: 'empty' };
  if (c.length >= r.length) return { ok: false, reason: 'not shorter' };
  const removed: string[] = [];
  let j = 0;
  for (const t of r) {
    if (j < c.length && t === c[j]) j++;
    else removed.push(t);
  }
  if (j < c.length) return { ok: false, reason: 'not a subsequence' };
  if (cueCount(candidate) >= cueCount(raw)) return { ok: false, reason: 'cue count not lower' };
  if (removed.every((t) => SOFT.has(t))) return { ok: false, reason: 'only soft cue words removed' };
  return { ok: true, reason: 'accepted' };
}

export async function backtrack(
  text: string,
  complete: (instruction: string, text: string) => Promise<string>
): Promise<string> {
  if (!cueCount(text)) return text;
  try {
    const out = (await complete(BACKTRACK, text)).trim().replace(/^out:\s*/i, '');
    const v = validateBacktrack(text, out);
    console.log(`smart corrections ${v.ok ? 'accepted' : 'rejected'}: ${v.reason}`);
    return v.ok ? out : text;
  } catch (e: any) {
    console.log(`smart corrections skipped: ${e?.message ?? e}`);
    return text;
  }
}
