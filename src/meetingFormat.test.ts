// bun src/meetingFormat.test.ts
import assert from 'node:assert';
import { durationLabel, speakerName, turnsToText } from './meetingFormat';

assert.equal(speakerName(0), 'Speaker 1');
assert.equal(speakerName(0, { 0: 'Kumar' }), 'Kumar');
assert.equal(speakerName(0, { 1: 'Jamie' }), 'Speaker 1');

// One speaker: no label, which is what the existing transcript UI expects.
assert.equal(turnsToText([{ speaker: 0, text: 'hello there' }]), 'hello there');
assert.equal(turnsToText([]), '');

// Several speakers: labels, renames applied, blank line between turns.
assert.equal(
  turnsToText(
    [
      { speaker: 0, text: 'we ship friday' },
      { speaker: 1, text: 'i need one more day' },
    ],
    { 0: 'Kumar' }
  ),
  'Kumar: we ship friday\n\nSpeaker 2: i need one more day'
);

assert.equal(durationLabel(0), '0:00');
assert.equal(durationLabel(65), '1:05');
assert.equal(durationLabel(3600), '1h 0m');
assert.equal(durationLabel(5400), '1h 30m');
assert.equal(durationLabel(-5), '0:00');

console.log('meetingFormat ok');
