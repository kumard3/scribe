// On-device extractive summary — no network, no LLM. Ranks sentences by the
// frequency of their meaningful words and returns the top few in original
// order. Good enough to give a quick gist of a long dictation; it pulls out
// real sentences rather than generating new text.

const STOPWORDS = new Set(
  (
    'a an the and or but if then else of to in on at by for with from into over after before ' +
    'is are was were be been being am do does did doing have has had having will would shall ' +
    'should can could may might must i you he she it we they me him her us them my your his its ' +
    'our their this that these those there here as so than too very just also not no yes ' +
    'about up down out off again once we’re i’m it’s that’s what which who whom whose how why ' +
    'when where all any both each few more most other some such only own same'
  ).split(' ')
);

function splitSentences(text: string): string[] {
  return text
    .replace(/\s+/g, ' ')
    .trim()
    .split(/(?<=[.!?。！？])\s+|\n+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function words(s: string): string[] {
  return s
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s']/gu, ' ')
    .split(/\s+/)
    .filter(Boolean);
}

/**
 * Returns an extractive summary of `text` as up to `maxSentences` sentences,
 * kept in their original order. Short inputs are returned unchanged.
 */
export function summarize(text: string, maxSentences = 3): string {
  const sentences = splitSentences(text);
  if (sentences.length <= maxSentences) return text.trim();

  const freq = new Map<string, number>();
  for (const s of sentences) {
    for (const w of words(s)) {
      if (w.length < 3 || STOPWORDS.has(w)) continue;
      freq.set(w, (freq.get(w) ?? 0) + 1);
    }
  }
  if (freq.size === 0) return sentences.slice(0, maxSentences).join(' ');

  const scored = sentences.map((s, index) => {
    const ws = words(s).filter((w) => w.length >= 3 && !STOPWORDS.has(w));
    if (ws.length === 0) return { index, score: 0 };
    let sum = 0;
    for (const w of ws) sum += freq.get(w) ?? 0;
    // length-normalized so a long rambling sentence doesn't always win
    return { index, score: sum / Math.sqrt(ws.length) };
  });

  const keep = scored
    .slice()
    .sort((a, b) => b.score - a.score)
    .slice(0, maxSentences)
    .map((s) => s.index)
    .sort((a, b) => a - b);

  return keep.map((i) => sentences[i]).join(' ');
}
