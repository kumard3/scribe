// bun src/util/usage.test.ts
import assert from 'node:assert';

const disk = new Map<string, string>();
const bin = new Map<string, Uint8Array>();
(globalThis as any).Bun.plugin({
  name: 'expo-file-system-stub',
  setup(build: any) {
    build.module('expo-file-system', () => ({
      loader: 'object',
      exports: {
        Paths: { document: 'doc' },
        Directory: class {},
        FileMode: { ReadOnly: 'r' },
        File: class {
          path: string;
          constructor(...parts: string[]) {
            this.path = parts.join('/');
          }
          get exists() {
            return disk.has(this.path);
          }
          create() {
            disk.set(this.path, '');
          }
          write(s: string) {
            disk.set(this.path, s);
          }
          textSync() {
            return disk.get(this.path) ?? '';
          }
          delete() {
            disk.delete(this.path);
          }
          get size() {
            return bin.get(this.path)?.length ?? 0;
          }
          open() {
            const bytes = bin.get(this.path);
            if (!bytes) throw new Error('missing');
            return { readBytes: (len: number) => bytes.slice(0, len), close() {} };
          }
        },
      },
    }));
  },
});

const {
  clearUsage,
  countWords,
  dayKey,
  hoursMinutes,
  loadUsage,
  recordCloud,
  recordDictation,
  trimDays,
  usageStats,
} = await import('./usage');
const { wavSeconds } = await import('../audio/wav');
type Usage = import('./usage').Usage;
type Day = import('./usage').Day;

const day = (p: Partial<Day>): Day => ({ words: 0, dictations: 0, speechSeconds: 0, cloud: {}, ...p });
const cc = (p: Partial<Record<string, number>>) => ({
  calls: 0,
  failures: 0,
  audioSeconds: 0,
  inputTokens: 0,
  outputTokens: 0,
  ...p,
});

assert.equal(countWords('Hello, world!'), 2);
assert.equal(countWords('hello - world ... ! ?'), 2, 'punctuation-only tokens');
assert.equal(countWords('meet at 3 pm'), 4, 'digits count');
assert.equal(countWords('नमस्ते दुनिया'), 2, 'Devanagari');
assert.equal(countWords('  \n '), 0);

const now = new Date(2026, 9, 18, 15, 30).getTime();
assert.equal(dayKey(now), '2026-10-18');
assert.equal(dayKey(new Date(2026, 0, 5, 0, 1).getTime()), '2026-01-05');

const base: Usage = {
  days: {
    '2026-10-18': day({ words: 10, dictations: 1, speechSeconds: 30 }),
    '2026-10-17': day({ words: 20, dictations: 2, speechSeconds: 20 }),
    '2026-10-12': day({ words: 5, dictations: 1 }),
    '2026-10-11': day({ words: 7, dictations: 1 }),
    '2026-09-30': day({
      words: 100,
      dictations: 3,
      cloud: { 'azure-speech': cc({ calls: 2, failures: 1, audioSeconds: 120 }) },
    }),
    '2026-10-01': day({
      cloud: {
        'azure-speech': cc({ calls: 1, audioSeconds: 60 }),
        'openai-chat': cc({ calls: 3, inputTokens: 30, outputTokens: 12 }),
        'azure-openai-chat': cc({ calls: 0 }),
      },
    }),
  },
};
(base.days['2026-10-01'].cloud as Record<string, unknown>)['made-up'] = cc({ calls: 9 });
const s = usageStats(base, now);
assert.equal(s.wordsToday, 10);
assert.equal(s.wordsWeek, 35, 'last 7 local days incl. today, 10-11 excluded');
assert.equal(s.wordsAll, 142);
assert.equal(s.dictations, 8);
assert.equal(s.speechSeconds, 50);
assert.equal(s.wpm, null, 'under 60 s of speech');
assert.equal(s.streak, 2);
assert.deepEqual(
  s.cloud.map((r) => r.provider),
  ['azure-speech', 'openai-chat'],
  'zero-call and unknown providers hidden, stable order'
);
assert.deepEqual(s.cloud[0].month, cc({ calls: 1, audioSeconds: 60 }));
assert.deepEqual(s.cloud[0].all, cc({ calls: 3, failures: 1, audioSeconds: 180 }));
assert.deepEqual(s.cloud[1].month, cc({ calls: 3, inputTokens: 30, outputTokens: 12 }));
assert.equal(s.cloud[0].label, 'Azure Speech');

const yesterdayStreak: Usage = {
  days: {
    '2026-10-18': day({ cloud: { 'openai-chat': cc({ calls: 1 }) } }),
    '2026-10-17': day({ words: 3, dictations: 1 }),
    '2026-10-16': day({ words: 3, dictations: 4 }),
    '2026-10-14': day({ words: 3, dictations: 1 }),
  },
};
assert.equal(usageStats(yesterdayStreak, now).streak, 2, 'streak ending yesterday');
assert.equal(usageStats({ days: { '2026-10-16': day({ dictations: 1 }) } }, now).streak, 0);
assert.equal(
  usageStats({ days: { '2026-10-01': day({ dictations: 1 }), '2026-09-30': day({ dictations: 1 }) } }, new Date(2026, 9, 1, 9).getTime()).streak,
  2,
  'streak across a month boundary'
);
assert.equal(usageStats({ days: {} }, now).streak, 0);

assert.equal(usageStats({ days: { '2026-10-18': day({ words: 150, speechSeconds: 59 }) } }, now).wpm, null);
assert.equal(usageStats({ days: { '2026-10-18': day({ words: 150, speechSeconds: 60 }) } }, now).wpm, 150);
assert.equal(usageStats({ days: { '2026-10-18': day({ words: 250, speechSeconds: 120 }) } }, now).wpm, 125);

const many: Usage = { days: {} };
for (let i = 0; i < 405; i++) many.days[dayKey(new Date(2024, 0, 1 + i).getTime())] = day({ words: 1 });
trimDays(many);
const kept = Object.keys(many.days).sort();
assert.equal(kept.length, 400);
assert.equal(kept[0], dayKey(new Date(2024, 0, 6).getTime()), 'oldest days dropped first');

const today = dayKey(Date.now());
disk.set('doc/usage.json', JSON.stringify({ days: { ...many.days } }));
recordDictation('Hello world.', 12);
let stored = loadUsage();
assert.equal(Object.keys(stored.days).length, 400, 'trimmed on write');
assert.ok(stored.days[today], 'today kept after trim');

clearUsage();
assert.deepEqual(loadUsage(), { days: {} });
recordDictation('Hello world.', 12);
recordDictation('   ', 5);
recordDictation('...', 3);
stored = loadUsage();
assert.deepEqual(stored.days[today], day({ words: 2, dictations: 2, speechSeconds: 15 }));

const api = 'https://api.openai.com/v1';
recordCloud('openai-chat', `${api}/chat/completions`, true, 0, {
  usage: { prompt_tokens: 13, completion_tokens: 18, total_tokens: 31 },
});
recordCloud('openai-transcribe', `${api}/audio/transcriptions`, true, 5, {
  usage: { type: 'tokens', input_tokens: 14, output_tokens: 45, total_tokens: 59 },
});
recordCloud('openai-transcribe', `${api}/audio/transcriptions`, true, 0, { usage: { type: 'duration', seconds: 4 } });
recordCloud('azure-speech', 'https://x.cognitiveservices.azure.com/speechtotext', true, 0, { durationMilliseconds: 2500 });
recordCloud('azure-speech', 'https://x.cognitiveservices.azure.com/speechtotext', true, 10, { durationMilliseconds: 2500 });
recordCloud('azure-speech', 'https://x.cognitiveservices.azure.com/speechtotext', false, 7);
recordCloud('openai-chat', 'http://localhost:11434/v1/chat/completions', true, 0, { usage: { prompt_tokens: 99 } });
recordCloud('openai-chat', 'http://127.0.0.1:11434/v1/chat/completions', false, 0);
const cloud = loadUsage().days[today].cloud;
assert.deepEqual(cloud['openai-chat'], cc({ calls: 1, inputTokens: 13, outputTokens: 18 }), 'localhost not counted');
assert.deepEqual(cloud['openai-transcribe'], cc({ calls: 2, audioSeconds: 9, inputTokens: 14, outputTokens: 45 }));
assert.deepEqual(cloud['azure-speech'], cc({ calls: 3, failures: 1, audioSeconds: 19.5 }));

disk.set('doc/usage.json', '{not json');
assert.deepEqual(loadUsage(), { days: {} }, 'corrupt file reads as empty');
recordDictation('still works', 1);
assert.equal(loadUsage().days[today].words, 2);

const wav = new Uint8Array(44 + 48000);
const view = new DataView(wav.buffer);
wav.set([...'RIFF'].map((c) => c.charCodeAt(0)), 0);
wav.set([...'WAVE'].map((c) => c.charCodeAt(0)), 8);
view.setUint32(28, 32000, true);
bin.set('file:///take.wav', wav);
bin.set('file:///talk.m4a', new Uint8Array(4000));
assert.equal(wavSeconds('file:///take.wav'), 1.5, '16 kHz mono 16-bit WAV length');
assert.equal(wavSeconds('file:///talk.m4a'), 0, 'non-WAV falls back to the response');
assert.equal(wavSeconds('file:///missing.wav'), 0);

assert.equal(hoursMinutes(0), '0m');
assert.equal(hoursMinutes(59 * 60 + 59), '59m');
assert.equal(hoursMinutes(3600), '1h 0m');
assert.equal(hoursMinutes(3725), '1h 2m');

console.log('usage: all assertions passed');
