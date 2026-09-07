// Terms every engine biases toward, whether or not the user added any.
// Apple's recognizer hears the product's own name as "Chris" without it.
export const BASE_VOCAB = [
  'Scribe',
  'Gemma',
  'E2B',
  'E4B',
  'chunking',
  'on-device',
  'whisper.cpp',
  'Hinglish',
  'Oriserve',
  'Apex',
  'Swift',
];

export function mergeVocab(user: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const term of [...BASE_VOCAB, ...user]) {
    const value = term.trim();
    const key = value.toLowerCase();
    if (!value || seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
}
