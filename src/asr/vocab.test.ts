// bun src/asr/vocab.test.ts
import assert from 'node:assert';
import { mergeVocab } from './vocab';

// The bug from the device: "Scribe" came back as "Chris" with an empty vocabulary.
assert.deepEqual(mergeVocab([]).slice(0, 3), ['Bolkit', 'Gemma', 'E2B']);
assert.ok(mergeVocab([]).includes('Hinglish'));

// User terms ride along, base first.
assert.equal(mergeVocab(['Assistable'])[0], 'Bolkit');
assert.ok(mergeVocab(['Assistable']).includes('Assistable'));

// A user who typed the base term themselves does not get it twice.
assert.equal(mergeVocab(['scribe']).filter((t) => t.toLowerCase() === 'scribe').length, 1);
assert.equal(mergeVocab(['Lumbox', 'lumbox']).filter((t) => t.toLowerCase() === 'lumbox').length, 1);

// Blank and padded entries never reach the recognizer.
assert.ok(mergeVocab(['  ', '', ' Neon ']).includes('Neon'));
assert.ok(!mergeVocab(['  ', '', ' Neon ']).includes(''));

console.log('vocab: all assertions passed');
