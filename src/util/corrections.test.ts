// bun src/util/corrections.test.ts
import assert from 'node:assert';
import { backtrack, cueCount, validateBacktrack } from './corrections';

const ok = (raw: string, out: string) => validateBacktrack(raw, out).ok;

assert.ok(ok("let's meet at 2 actually 3 pm", "let's meet at 3 pm"));
assert.ok(ok('send it to Rahul no wait send it to Priya', 'send it to Priya'));
assert.ok(ok('um send it to Rahul no wait send it to Priya.', 'Send it to Priya.'));

assert.ok(!ok("let's meet at 2 actually 3 pm", "let's meet at three pm"), 'reworded');
assert.ok(!ok("let's meet at 2 actually 3 pm", "let's meet at 3 pm today"), 'added word');
assert.ok(!ok("let's meet at 2 actually 3 pm", ''), 'empty');
assert.ok(!ok("let's meet at 2 actually 3 pm", "let's meet at actually 3 pm"), 'same cue count');
assert.ok(!ok('I actually liked the demo', 'I liked the demo'), 'soft cue only');
assert.ok(!ok('send it to Priya', 'send it to Priya'), 'not shorter');

assert.equal(cueCount('hello there'), 0);
assert.equal(cueCount('no wait, I mean Friday'), 2);

let calls = 0;
const model = async (_i: string, t: string) => {
  calls++;
  return t === "let's meet at 2 actually 3 pm" ? "let's meet at 3 pm" : 'something else entirely';
};
(async () => {
  assert.equal(await backtrack('plain dictation here', model), 'plain dictation here');
  assert.equal(calls, 0, 'no cue, no model call');
  assert.equal(await backtrack("let's meet at 2 actually 3 pm", model), "let's meet at 3 pm");
  assert.equal(await backtrack('sorry I am late', model), 'sorry I am late');
  assert.equal(
    await backtrack('make that two', async () => {
      throw new Error('offline');
    }),
    'make that two'
  );
  console.log('corrections: all assertions passed');
})();
