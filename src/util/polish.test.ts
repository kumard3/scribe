// bun src/util/polish.test.ts
import assert from 'node:assert';
import { applyVoiceCommands } from './polish';

const cases: [string, string][] = [
  ['no no no delete everything that I said till now the meeting is on Friday', 'the meeting is on Friday'],
  ['hello world. Delete everything. New text here', 'New text here'],
  ['first draft scratch all of that second draft', 'first draft scratch all of that second draft'],
  ['first draft, scratch all of that. second draft', 'second draft'],
  ['please delete everything in the downloads folder', 'please delete everything in the downloads folder'],
  ['delete everything before Friday', 'delete everything before Friday'],
  ['delete everything I said before. new start', 'new start'],
  ['wrong stuff start over. right stuff', 'right stuff'],
  ['erase everything I said so far okay take two', 'okay take two'],
  ['delete everything', ''],
  ["okay wait, clear it all and start over. take three", 'take three'],
  ["forget everything I've dictated before let's go", "let's go"],
  ['we need to start over with the design', 'we need to start over with the design'],
];
for (const [input, want] of cases) assert.equal(applyVoiceCommands(input), want, input);

assert.equal(applyVoiceCommands('send the report scratch that'), '');
assert.equal(applyVoiceCommands('call mom. send the report scratch that'), 'call mom.');

console.log('polish: all assertions passed');
