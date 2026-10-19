import { File, Paths } from 'expo-file-system';

export const PROVIDERS = {
  'azure-speech': 'Azure Speech',
  'azure-speech-realtime': 'Azure Speech (live)',
  'azure-openai-transcribe': 'Azure OpenAI transcription',
  'azure-openai-chat': 'Azure OpenAI chat',
  'openai-transcribe': 'OpenAI transcription',
  'openai-chat': 'OpenAI chat',
} as const;

export type CloudProvider = keyof typeof PROVIDERS;
export type CloudCounts = {
  calls: number;
  failures: number;
  audioSeconds: number;
  inputTokens: number;
  outputTokens: number;
};
export type Day = {
  words: number;
  dictations: number;
  speechSeconds: number;
  cloud: Partial<Record<CloudProvider, CloudCounts>>;
};
export type Usage = { days: Record<string, Day> };
export type CloudResponse = { durationMilliseconds?: unknown; usage?: Record<string, unknown> } | null;

const MAX_DAYS = 400;

function file(): File {
  return new File(Paths.document, 'usage.json');
}

export function loadUsage(): Usage {
  try {
    const f = file();
    if (!f.exists) return { days: {} };
    const parsed = JSON.parse(f.textSync());
    return parsed && parsed.days && typeof parsed.days === 'object' ? parsed : { days: {} };
  } catch {
    return { days: {} };
  }
}

export function clearUsage(): void {
  try {
    const f = file();
    if (f.exists) f.delete();
  } catch {}
}

export function trimDays(u: Usage, max = MAX_DAYS): Usage {
  const keys = Object.keys(u.days).sort();
  for (const k of keys.slice(0, Math.max(0, keys.length - max))) delete u.days[k];
  return u;
}

function update(fn: (d: Day) => void): void {
  try {
    const u = loadUsage();
    const k = dayKey(Date.now());
    const d = u.days[k] ?? (u.days[k] = { words: 0, dictations: 0, speechSeconds: 0, cloud: {} });
    if (!d.cloud) d.cloud = {};
    fn(d);
    const f = file();
    if (!f.exists) f.create();
    f.write(JSON.stringify(trimDays(u)));
  } catch {}
}

export function dayKey(t: number): string {
  const d = new Date(t);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function countWords(text: string): number {
  return text.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;
}

const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0);

export function recordDictation(text: string, speechSeconds: number): void {
  if (!text.trim()) return;
  const words = countWords(text);
  update((d) => {
    d.words += words;
    d.dictations += 1;
    d.speechSeconds += num(speechSeconds);
  });
}

export function recordCloud(
  provider: CloudProvider,
  url: string,
  ok: boolean,
  audioSeconds: number,
  response?: CloudResponse
): void {
  if (/^https?:\/\/(localhost|127\.|\[::1\])/i.test(url.trim())) return;
  const usage = response?.usage;
  update((d) => {
    const c =
      d.cloud[provider] ??
      (d.cloud[provider] = { calls: 0, failures: 0, audioSeconds: 0, inputTokens: 0, outputTokens: 0 });
    c.calls += 1;
    if (!ok) c.failures += 1;
    c.audioSeconds += num(audioSeconds) || num(response?.durationMilliseconds) / 1000 || num(usage?.seconds);
    c.inputTokens += num(usage?.input_tokens ?? usage?.prompt_tokens);
    c.outputTokens += num(usage?.output_tokens ?? usage?.completion_tokens);
  });
}

export type ProviderStats = { provider: CloudProvider; label: string; month: CloudCounts; all: CloudCounts };
export type Stats = {
  wordsToday: number;
  wordsWeek: number;
  wordsAll: number;
  dictations: number;
  wpm: number | null;
  streak: number;
  speechSeconds: number;
  cloud: ProviderStats[];
};

const zero = (): CloudCounts => ({ calls: 0, failures: 0, audioSeconds: 0, inputTokens: 0, outputTokens: 0 });

function add(into: CloudCounts, c: CloudCounts): void {
  into.calls += num(c.calls);
  into.failures += num(c.failures);
  into.audioSeconds += num(c.audioSeconds);
  into.inputTokens += num(c.inputTokens);
  into.outputTokens += num(c.outputTokens);
}

export function usageStats(u: Usage, now = Date.now()): Stats {
  const t = new Date(now);
  const key = (back: number) => dayKey(new Date(t.getFullYear(), t.getMonth(), t.getDate() - back).getTime());
  const week = new Set([0, 1, 2, 3, 4, 5, 6].map(key));
  const month = key(0).slice(0, 8);
  const s: Stats = {
    wordsToday: num(u.days[key(0)]?.words),
    wordsWeek: 0,
    wordsAll: 0,
    dictations: 0,
    wpm: null,
    streak: 0,
    speechSeconds: 0,
    cloud: [],
  };
  const rows = new Map<string, ProviderStats>();
  for (const [k, d] of Object.entries(u.days)) {
    s.wordsAll += num(d.words);
    s.dictations += num(d.dictations);
    s.speechSeconds += num(d.speechSeconds);
    if (week.has(k)) s.wordsWeek += num(d.words);
    for (const [p, c] of Object.entries(d.cloud ?? {})) {
      if (!c || !(p in PROVIDERS)) continue;
      const provider = p as CloudProvider;
      const row = rows.get(p) ?? { provider, label: PROVIDERS[provider], month: zero(), all: zero() };
      rows.set(p, row);
      add(row.all, c);
      if (k.startsWith(month)) add(row.month, c);
    }
  }
  if (s.speechSeconds >= 60) s.wpm = Math.round(s.wordsAll / (s.speechSeconds / 60));
  let back = num(u.days[key(0)]?.dictations) > 0 ? 0 : 1;
  while (num(u.days[key(back)]?.dictations) > 0) {
    s.streak += 1;
    back += 1;
  }
  s.cloud = (Object.keys(PROVIDERS) as CloudProvider[])
    .map((p) => rows.get(p))
    .filter((r): r is ProviderStats => !!r && r.all.calls > 0);
  return s;
}

export function hoursMinutes(sec: number): string {
  const m = Math.floor(num(sec) / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}
