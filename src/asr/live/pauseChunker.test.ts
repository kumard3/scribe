// bun src/asr/live/pauseChunker.test.ts
import assert from 'node:assert';
import { PauseChunker } from './pauseChunker';

function tone(n: number, amp = 0.2): Float32Array {
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = Math.sin(i / 8) * amp;
  return out;
}

function silence(n: number): Float32Array {
  return new Float32Array(n);
}

{
  const c = new PauseChunker({ sampleRate: 16000, pauseMs: 550 });
  assert.equal(c.feed(silence(16000)).length, 0);
  assert.equal(c.flush(), null);
}

{
  const c = new PauseChunker({ sampleRate: 16000, pauseMs: 550 });
  assert.equal(c.feed(tone(16000)).length, 0, '1s of speech waits for a pause');
  const paused = c.feed(silence(Math.floor((16000 * 6) / 10)));
  assert.equal(paused.length, 1, 'pause after speech closes one chunk');
  assert.ok(paused[0].length >= 16000);
  assert.equal(c.flush(), null, 'overlap-only remainder is not a new utterance');
}

{
  const c = new PauseChunker({ sampleRate: 16000, pauseMs: 550 });
  const long = c.feed(tone(Math.floor(16000 * 3.4)));
  assert.equal(long.length, 1, `hard cap splits run-on speech: ${long.length}`);
  assert.ok(long[0].length >= 16000 * 3);
  assert.ok(c.flush(), 'audio past the cap survives on flush');
}

{
  const c = new PauseChunker({ sampleRate: 16000, pauseMs: 550 });
  c.feed(tone(8000));
  const first = c.feed(silence(Math.floor((16000 * 6) / 10)));
  assert.equal(first.length, 1);
  c.feed(tone(8000));
  const second = c.feed(silence(Math.floor((16000 * 6) / 10)));
  assert.equal(second.length, 1);
  assert.ok(second[0].length >= 8000);
  assert.ok(second[0].length >= 16000 * 0.3, 'second chunk keeps overlap from the first');
}

console.log('pauseChunker: all assertions passed');
