// Regenerate Android launcher mipmaps from assets/ without re-running expo prebuild.
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const resDir = resolve(root, 'android/app/src/main/res');

// adaptive foreground/background/monochrome are 108dp; legacy icons are 48dp.
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
const ADAPTIVE = 108;
const LEGACY = 48;

const src = (f) => resolve(root, 'assets', f);
const out = (d, f) => resolve(resDir, `mipmap-${d}`, f);

async function webp(input, size, dest, { round = false } = {}) {
  let img = sharp(input).resize(size, size, { fit: 'cover' });
  if (round) {
    const mask = Buffer.from(
      `<svg width="${size}" height="${size}"><circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="#fff"/></svg>`,
    );
    img = img.composite([{ input: mask, blend: 'dest-in' }]);
  }
  await img.webp({ lossless: true }).toFile(dest);
}

for (const [d, scale] of Object.entries(densities)) {
  const a = Math.round(ADAPTIVE * scale);
  const l = Math.round(LEGACY * scale);
  await webp(src('android-icon-foreground.png'), a, out(d, 'ic_launcher_foreground.webp'));
  await webp(src('android-icon-background.png'), a, out(d, 'ic_launcher_background.webp'));
  await webp(src('android-icon-monochrome.png'), a, out(d, 'ic_launcher_monochrome.webp'));
  await webp(src('icon.png'), l, out(d, 'ic_launcher.webp'));
  await webp(src('icon.png'), l, out(d, 'ic_launcher_round.webp'), { round: true });
  console.log(`mipmap-${d}: adaptive ${a}px, legacy ${l}px`);
}
console.log('done');
