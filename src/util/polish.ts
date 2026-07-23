// On-device transcript cleanup, no model, no network. Wispr-style "Flow" formatting.

const FILLERS = /\b(um+|uh+|erm+|uhh+|hmm+|mm+hmm|y'?know)\b/gi;

// Spoken punctuation / layout commands → real symbols. Order matters (longest first).
const COMMANDS: [RegExp, string][] = [
  [/\b(new paragraph|next paragraph)\b/gi, '\n\n'],
  [/\b(new line|next line)\b/gi, '\n'],
  [/\b(bullet point|new bullet|bullet)\b/gi, '\n• '],
  [/\b(numbered list|number list)\b/gi, '\n1. '],
  [/\b(open paren|open parenthesis)\b/gi, '('],
  [/\b(close paren|close parenthesis)\b/gi, ')'],
  [/\b(open quote|quote)\b/gi, '“'],
  [/\b(close quote|unquote|end quote)\b/gi, '”'],
  [/\b(exclamation mark|exclamation point)\b/gi, '!'],
  [/\b(question mark)\b/gi, '?'],
  [/\b(full stop|period)\b/gi, '.'],
  [/\b(comma)\b/gi, ','],
  [/\b(colon)\b/gi, ':'],
  [/\b(semicolon)\b/gi, ';'],
  [/\b(hyphen|dash)\b/gi, '-'],
  [/\b(smiley face|smiley)\b/gi, ':)'],
];

function applyCommands(text: string): string {
  let t = text;
  for (const [re, sym] of COMMANDS) t = t.replace(re, sym);
  return t;
}

// Spoken EDITING commands. Destructive, so only applied to live dictation, never
// to imported recordings (a call participant saying "scratch that" must not
// delete text). No model, on-device.
const SCRATCH = /[^.!?\n]*\b(?:scratch|strike|delete|cross)\s+that\b[.,!?]*/gi;
const LAST_WORD = /(?:\S+)\s+\b(?:scratch|delete|cross)\s+(?:the\s+)?last word\b[.,!?]*/gi;
const LAST_LINE = /\b(?:scratch|delete|cross)\s+(?:this |the |that )?last line\b[.,!?]*/i;

export function applyVoiceCommands(text: string): string {
  let t = text.replace(SCRATCH, '').replace(LAST_WORD, '');
  if (LAST_LINE.test(t)) {
    const out: string[] = [];
    for (const line of t.split('\n')) {
      const m = line.match(LAST_LINE);
      if (m) {
        const before = line.slice(0, m.index).trim();
        if (!before && out.length) out.pop();
        continue;
      }
      out.push(line);
    }
    t = out.join('\n');
  }
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
