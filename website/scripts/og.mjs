// Generates the social/OG image + PWA/app icons for the Scribe site.
// Run once (assets are committed as static files): node scripts/og.mjs
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pub = resolve(root, 'public');

// Scribe app-icon glyph: three rounded pill-bars (heights 320/540/400) on a
// gradient squircle, matching assets/icon.png.
const iconSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#161618"/><stop offset="1" stop-color="#000000"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="224" fill="url(#bg)"/>
  <rect x="2" y="2" width="1020" height="1020" rx="222" fill="none" stroke="#2A2A2E" stroke-width="3"/>
  <g fill="#fff">
    <rect x="262" y="352" width="116" height="320" rx="58"/>
    <rect x="454" y="242" width="116" height="540" rx="58"/>
    <rect x="646" y="312" width="116" height="400" rx="58"/>
  </g>
</svg>`;

// 1200x630 social card.
const W = 1200, H = 630, PAD = 84;
const markBars = [
  { x: PAD, y: 78, w: 11, h: 36 },
  { x: PAD + 17, y: 66, w: 11, h: 60 },
  { x: PAD + 34, y: 72, w: 11, h: 48 },
];
const wave = Array.from({ length: 58 }, (_, i) => {
  const c = 1 - Math.abs(i - 29) / 29;
  const h = 8 + c * 60 + (i % 4) * 5;
  return `<rect x="${PAD + i * 18}" y="${560 - h}" width="6" height="${h}" rx="3" fill="#fff" opacity="${(0.10 + c * 0.30).toFixed(2)}"/>`;
}).join('');

const ogSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <radialGradient id="glow" cx="50%" cy="-10%" r="75%">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.12"/>
      <stop offset="0.6" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="#000000"/>
  <rect width="${W}" height="${H}" fill="url(#glow)"/>
  <rect x="1" y="1" width="${W - 2}" height="${H - 2}" fill="none" stroke="#232327" stroke-width="2"/>
  ${markBars.map((b) => `<rect x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="${b.w / 2}" fill="#fff"/>`).join('')}
  <text x="${PAD + 60}" y="103" font-family="Helvetica,Arial,sans-serif" font-size="38" font-weight="700" fill="#f5f5f7">Scribe</text>
  <text x="${PAD}" y="248" font-family="Helvetica,Arial,sans-serif" font-size="78" font-weight="700" fill="#f5f5f7" letter-spacing="-2">Voice to text that</text>
  <text x="${PAD}" y="338" font-family="Helvetica,Arial,sans-serif" font-size="78" font-weight="700" fill="#76767e" letter-spacing="-2">never leaves your device.</text>
  <text x="${PAD}" y="420" font-family="Helvetica,Arial,sans-serif" font-size="27" fill="#b6b6bd">100% on-device  ·  Free &amp; open source  ·  No account  ·  59 languages</text>
  ${wave}
</svg>`;

async function run() {
  await sharp(Buffer.from(ogSvg)).png().toFile(resolve(pub, 'og.png'));
  await sharp(Buffer.from(iconSvg)).resize(512, 512).png().toFile(resolve(pub, 'icon-512.png'));
  await sharp(Buffer.from(iconSvg)).resize(192, 192).png().toFile(resolve(pub, 'icon-192.png'));
  await sharp(Buffer.from(iconSvg)).resize(180, 180).png().toFile(resolve(pub, 'apple-touch-icon.png'));
  console.log('Wrote og.png (1200x630), icon-512, icon-192, apple-touch-icon to public/');
}
run();
