// On-device transcript cleanup — no model, no network. Wispr-style "Flow" formatting.

const FILLERS = /\b(um+|uh+|erm+|uhh+|hmm+|mm+hmm|y'?know)\b/gi;

// Spoken punctuation / layout commands → real symbols. Order matters (longest first).
const COMMANDS: [RegExp, string][] = [
  [/\b(new paragraph|next paragraph)\b/gi, '\n\n'],
  [/\b(new line|next line)\b/gi, '\n'],
  [/\b(open paren|open parenthesis)\b/gi, '('],
  [/\b(close paren|close parenthesis)\b/gi, ')'],
  [/\b(exclamation mark|exclamation point)\b/gi, '!'],
  [/\b(question mark)\b/gi, '?'],
  [/\b(full stop|period)\b/gi, '.'],
  [/\b(comma)\b/gi, ','],
  [/\b(colon)\b/gi, ':'],
  [/\b(semicolon)\b/gi, ';'],
];

function applyCommands(text: string): string {
  let t = text;
  for (const [re, sym] of COMMANDS) t = t.replace(re, sym);
  return t;
}

function tidy(text: string): string {
  let t = text
    .replace(/[ \t]+([,.!?;:])/g, '$1') // no space before punctuation
    .replace(/([,.!?;:])(?=[^\s\n])/g, '$1 ') // ensure space after punctuation
    .replace(/[ \t]{2,}/g, ' ') // collapse spaces
    .replace(/[ \t]*\n[ \t]*/g, '\n') // trim around newlines
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  // Capitalize sentence starts and line starts.
  t = t.replace(/(^|[.!?]\s+|\n)([a-z])/g, (_m, pre, ch) => pre + ch.toUpperCase());
  // Standalone "i" -> "I"
  t = t.replace(/\bi\b/g, 'I');
  return t;
}

export function polish(text: string): string {
  if (!text.trim()) return text;
  return tidy(applyCommands(text).replace(FILLERS, ' '));
}
