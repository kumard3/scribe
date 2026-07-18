import { Directory, File, Paths } from 'expo-file-system';

const TARGET_RATE = 16000;

function concatFloat32(chunks: Float32Array[]): Float32Array {
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Float32Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}

function resample(input: Float32Array, inRate: number, outRate: number): Float32Array {
  if (inRate === outRate || input.length === 0) return input;
  const ratio = inRate / outRate;
  const outLen = Math.max(1, Math.floor(input.length / ratio));
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const pos = i * ratio;
    const i0 = Math.floor(pos);
    const i1 = i0 + 1 < input.length ? i0 + 1 : i0;
    const frac = pos - i0;
    out[i] = input[i0] * (1 - frac) + input[i1] * frac;
  }
  return out;
}

function encodeWav(samples: Float32Array, sampleRate: number): Uint8Array {
  const n = samples.length;
  const buffer = new ArrayBuffer(44 + n * 2);
  const view = new DataView(buffer);
  const writeStr = (off: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i));
  };
  writeStr(0, 'RIFF');
  view.setUint32(4, 36 + n * 2, true);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  view.setUint32(16, 16, true); // PCM subchunk size
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // byte rate = rate * channels * bytesPerSample
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeStr(36, 'data');
  view.setUint32(40, n * 2, true);
  let off = 44;
  for (let i = 0; i < n; i++) {
    let s = samples[i];
    s = s < -1 ? -1 : s > 1 ? 1 : s;
    view.setInt16(off, (s < 0 ? s * 0x8000 : s * 0x7fff) | 0, true);
    off += 2;
  }
  return new Uint8Array(buffer);
}

/**
 * Whisper.rn / sherpa-onnx need a real 16 kHz mono 16-bit WAV. expo-audio's
 * MediaRecorder can't emit PCM on Android, so we capture raw float PCM via
 * useAudioStream and build the WAV here, resampling to 16 kHz if the hardware
 * delivered a different rate.
 */
export async function writeWavFromFloat32(
  chunks: Float32Array[],
  inputRate: number
): Promise<string> {
  const merged = concatFloat32(chunks);
  const resampled = resample(merged, inputRate || TARGET_RATE, TARGET_RATE);
  const wav = encodeWav(resampled, TARGET_RATE);
  const dir = new Directory(Paths.cache, 'rec');
  if (!dir.exists) dir.create({ intermediates: true });
  const file = new File(dir, 'scribe-take.wav');
  if (file.exists) file.delete();
  file.create();
  file.write(wav);
  return file.uri;
}

export function resampleTo16k(input: Float32Array, inRate: number): Float32Array {
  return resample(input, inRate || 16000, TARGET_RATE);
}

/**
 * Decodes a PCM WAV file to mono Float32 samples at 16 kHz, for feeding a
 * streaming recognizer that has no offline file path. Walks the RIFF chunks
 * (fmt + data), downmixes channels, and resamples if the source isn't 16 kHz.
 */
export async function decodeWavTo16kMono(uri: string): Promise<Float32Array> {
  const bytes = await new File(uri).bytes();
  if (bytes.length < 44) return new Float32Array(0);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (o: number) =>
    String.fromCharCode(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]);

  let channels = 1;
  let sampleRate = TARGET_RATE;
  let bits = 16;
  let dataOff = -1;
  let dataLen = 0;
  let off = 12; // skip RIFF<size>WAVE
  while (off + 8 <= bytes.length) {
    const id = tag(off);
    const size = view.getUint32(off + 4, true);
    const body = off + 8;
    if (id === 'fmt ') {
      channels = view.getUint16(body + 2, true) || 1;
      sampleRate = view.getUint32(body + 4, true) || TARGET_RATE;
      bits = view.getUint16(body + 14, true) || 16;
    } else if (id === 'data') {
      dataOff = body;
      dataLen = Math.min(size, bytes.length - body);
      break;
    }
    off = body + size + (size & 1); // chunks are word-aligned
  }
  if (dataOff < 0) return new Float32Array(0);

  const bytesPerSample = Math.max(1, bits >> 3);
  const frames = Math.floor(dataLen / (bytesPerSample * channels));
  const mono = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let acc = 0;
    for (let c = 0; c < channels; c++) {
      const p = dataOff + (i * channels + c) * bytesPerSample;
      if (bits === 16) acc += view.getInt16(p, true) / 0x8000;
      else if (bits === 32) acc += view.getInt32(p, true) / 0x80000000;
      else acc += (bytes[p] - 128) / 128; // 8-bit unsigned
    }
    mono[i] = acc / channels;
  }
  return sampleRate === TARGET_RATE ? mono : resample(mono, sampleRate, TARGET_RATE);
}

export function float32ToInt16Bytes(samples: Float32Array): Uint8Array {
  const out = new Uint8Array(samples.length * 2);
  const view = new DataView(out.buffer);
  for (let i = 0; i < samples.length; i++) {
    let s = samples[i];
    s = s < -1 ? -1 : s > 1 ? 1 : s;
    view.setInt16(i * 2, (s < 0 ? s * 0x8000 : s * 0x7fff) | 0, true);
  }
  return out;
}

export function rms(samples: Float32Array): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / samples.length);
}
