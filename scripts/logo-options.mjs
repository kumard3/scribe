// Render 3 Vox logo concepts -> PNG previews + a side-by-side contact sheet.
// Usage:
//   node scripts/logo-options.mjs            -> render previews + open contact sheet
//   node scripts/logo-options.mjs apply a    -> make option A the real app icon (a|b|c)
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { mkdirSync, existsSync, readdirSync } from 'node:fs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const optDir = resolve(root, 'assets/logo-options');
const assets = resolve(root, 'assets');
mkdirSync(optDir, { recursive: true });

const S = 1024;
const R = 224; // corner radius (iOS-ish squircle approximation)
const BG = `
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#161618"/>
      <stop offset="1" stop-color="#000000"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="${S}" height="${S}" rx="${R}" ry="${R}" fill="url(#bg)"/>
  <rect x="2" y="2" width="${S - 4}" height="${S - 4}" rx="${R - 2}" ry="${R - 2}"
        fill="none" stroke="#2A2A2E" stroke-width="3"/>`;

// A — Waveform: three bold rounded bars (voice / equalizer)
function glyphA() {
  const bw = 116, gap = 76, h = [320, 540, 400];
  const total = bw * 3 + gap * 2;
  const x0 = (S - total) / 2;
  const cy = S / 2;
  return h
    .map((bh, i) => {
      const x = x0 + i * (bw + gap);
      const y = cy - bh / 2;
      return `<rect x="${x}" y="${y}" width="${bw}" height="${bh}" rx="${bw / 2}" ry="${bw / 2}" fill="#FFFFFF"/>`;
    })
    .join('');
}

// B — V mark: bold rounded "V" monogram
function glyphB() {
  return `<path d="M 300 312 L 512 712 L 724 312"
    fill="none" stroke="#FFFFFF" stroke-width="120"
    stroke-linecap="round" stroke-linejoin="round"/>`;
}

// C — Listening orb: solid capsule + concentric pulse ring
function glyphC() {
  return `
    <circle cx="${S / 2}" cy="${S / 2}" r="300" fill="none" stroke="#FFFFFF" stroke-opacity="0.28" stroke-width="22"/>
    <circle cx="${S / 2}" cy="${S / 2}" r="210" fill="none" stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="22"/>
    <circle cx="${S / 2}" cy="${S / 2}" r="120" fill="#FFFFFF"/>`;
}

const GLYPHS = { a: glyphA, b: glyphB, c: glyphC };

function svg(option) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">${BG}${GLYPHS[option]()}</svg>`;
}

async function renderPreview(option) {
  const dest = resolve(optDir, `option-${option}.png`);
  await sharp(Buffer.from(svg(option))).png().toFile(dest);
  return dest;
}

async function contactSheet() {
  const tile = 360, gap = 48, pad = 64, labelH = 64;
  const w = pad * 2 + tile * 3 + gap * 2;
  const h = pad * 2 + tile + labelH;
  const tiles = await Promise.all(
    ['a', 'b', 'c'].map((o) => sharp(Buffer.from(svg(o))).resize(tile, tile).png().toBuffer())
  );
  const labels = ['A · Waveform', 'B · V mark', 'C · Listening orb'];
  const overlays = ['a', 'b', 'c'].flatMap((_, i) => {
    const x = pad + i * (tile + gap);
    const lbl = Buffer.from(
      `<svg width="${tile}" height="${labelH}"><text x="${tile / 2}" y="42" font-family="Helvetica,Arial" font-size="30" font-weight="600" fill="#FFFFFF" text-anchor="middle">${labels[i]}</text></svg>`
    );
    return [
      { input: tiles[i], top: pad, left: x },
      { input: lbl, top: pad + tile + 8, left: x },
    ];
  });
  const dest = resolve(optDir, 'contact-sheet.png');
  await sharp({ create: { width: w, height: h, channels: 4, background: '#000000' } })
    .composite(overlays)
    .png()
    .toFile(dest);
  return dest;
}

// Build the full app-icon set from the chosen glyph (transparent-bg glyph for adaptive).
async function apply(option) {
  const full = Buffer.from(svg(option));
  // 1024 app icon (iOS marketing + Expo icon.png) and splash
  await sharp(full).resize(1024, 1024).png().toFile(resolve(assets, 'icon.png'));
  await sharp(full).resize(1024, 1024).png().toFile(resolve(assets, 'favicon.png'));
  // Android adaptive foreground = glyph only, centered with safe padding, transparent bg
  const fg = `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">
    <g transform="translate(${S * 0.16},${S * 0.16}) scale(0.68)">${GLYPHS[option]()}</g></svg>`;
  await sharp(Buffer.from(fg)).resize(1024, 1024).png().toFile(resolve(assets, 'android-icon-foreground.png'));
  await sharp(Buffer.from(fg)).resize(1024, 1024).png().toFile(resolve(assets, 'android-icon-monochrome.png'));
  // Android background = solid near-black
  await sharp({ create: { width: 1024, height: 1024, channels: 4, background: '#000000' } })
    .png()
    .toFile(resolve(assets, 'android-icon-background.png'));
  // iOS AppIcon set (single 1024 if Xcode 14+ single-size asset, else fill all)
  const iosSet = findIosAppIconSet();
  if (iosSet) {
    for (const f of readdirSync(iosSet).filter((f) => f.endsWith('.png'))) {
      const m = f.match(/(\d+)x(\d+)|(\d+)/);
      // re-render each at its own size from the file name's leading dimension when possible
    }
    // Simplest robust path: overwrite every png in the set scaled to its current pixel size.
    for (const f of readdirSync(iosSet).filter((f) => f.endsWith('.png'))) {
      const p = resolve(iosSet, f);
      const meta = await sharp(p).metadata();
      const size = meta.width || 1024;
      // iOS app icons must be opaque (no alpha) -> flatten onto the tile bg already in svg
      await sharp(full).resize(size, size).flatten({ background: '#000000' }).png().toFile(p);
    }
  }
  console.log(`Applied option ${option.toUpperCase()} to assets/ (icon, splash, android adaptive)${iosSet ? ' + iOS AppIcon set' : ''}.`);
  console.log('Next: node scripts/android-icons.mjs  (regenerate Android mipmaps)');
}

function findIosAppIconSet() {
  const candidates = [
    resolve(root, 'ios/Vox/Images.xcassets/AppIcon.appiconset'),
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  return null;
}

const [, , cmd, opt] = process.argv;
if (cmd === 'apply') {
  if (!['a', 'b', 'c'].includes(opt)) {
    console.error('Usage: node scripts/logo-options.mjs apply a|b|c');
    process.exit(1);
  }
  await apply(opt);
} else {
  for (const o of ['a', 'b', 'c']) console.log('rendered', await renderPreview(o));
  const sheet = await contactSheet();
  console.log('contact sheet:', sheet);
}
