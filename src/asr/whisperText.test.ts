// bun src/asr/whisperText.test.ts
import assert from 'node:assert';
import type { ModelSpec } from './types';
import { decodeLanguage, stripAnnotations } from './whisperText';

const enOnly = { languages: ['en'] } as ModelSpec;
const multi = { languages: 'multilingual' } as ModelSpec;

// The bug from the device: an .en model asked for 'auto' returned this verbatim.
assert.equal(stripAnnotations('[NON-ENGLISH SPEECH]'), '');
assert.equal(stripAnnotations('[BLANK_AUDIO]'), '');
assert.equal(stripAnnotations('[MUSIC] hello there'), 'hello there');
assert.equal(stripAnnotations('hello [SOUND] there'), 'hello there');

// Real transcript must survive untouched.
assert.equal(stripAnnotations('Meet me at [the] cafe'), 'Meet me at [the] cafe');
assert.equal(stripAnnotations('I said NO to that'), 'I said NO to that');

// An English-only model never gets 'auto' or a foreign locale.
assert.equal(decodeLanguage(enOnly, 'auto'), 'en');
assert.equal(decodeLanguage(enOnly, 'hi'), 'en');
assert.equal(decodeLanguage(enOnly, 'en'), 'en');

// A multilingual model keeps what the user asked for; Hinglish decodes as English.
assert.equal(decodeLanguage(multi, 'auto'), 'auto');
assert.equal(decodeLanguage(multi, 'hi'), 'hi');
assert.equal(decodeLanguage(multi, 'hi-en'), 'en');

const oriserve = { languages: 'multilingual', forcedLanguage: 'hi' } as ModelSpec;
assert.equal(decodeLanguage(oriserve, 'auto'), 'hi');
assert.equal(decodeLanguage(oriserve, 'en', 'auto'), 'hi');
assert.equal(decodeLanguage(oriserve, 'hi', 'english'), 'en');
assert.equal(decodeLanguage(oriserve, 'en', 'hinglish'), 'hi');

console.log('whisperText: all assertions passed');
