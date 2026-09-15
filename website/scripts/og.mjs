// Generates the social/OG image + PWA/app icons for the Bolkit site.
// Run once (assets are committed as static files): node scripts/og.mjs
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pub = resolve(root, 'public');

// Bolkit app icon: wave-to-cursor mark on a gradient squircle (marketing/logo/bolkit-icon.svg).
const iconSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#161618"/><stop offset="1" stop-color="#060607"/></linearGradient><linearGradient id="ink" x1="0" y1="323" x2="0" y2="686" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FAFAFA"/><stop offset="1" stop-color="#D4D4D4"/></linearGradient></defs><rect width="1024" height="1024" rx="224" fill="url(#bg)"/><rect x="2" y="2" width="1020" height="1020" rx="222" fill="none" stroke="#2A2A2E" stroke-width="3"/><path d="M180 520 C236 520 236 553 292 553 C342 553 342 343 392 343 C441 343 441 666 490 666 C547.5 666 547.5 469 605 469 C664.5 469 664.5 520 724 520 C757 520 757 520 790 520" fill="none" stroke="url(#ink)" stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/><rect x="821" y="426" width="40" height="170" rx="20" fill="url(#ink)"/></svg>`;

// 1200x630 social card.
const W = 1200, H = 630, PAD = 84;
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
  <g transform="translate(${PAD} 72) scale(0.0826) translate(-160 -323)"><path d="M180 520 C236 520 236 553 292 553 C342 553 342 343 392 343 C441 343 441 666 490 666 C547.5 666 547.5 469 605 469 C664.5 469 664.5 520 724 520 C757 520 757 520 790 520" fill="none" stroke="#fff" stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/><rect x="821" y="426" width="40" height="170" rx="20" fill="#fff"/></g>
  <text x="${PAD + 74}" y="103" font-family="Helvetica,Arial,sans-serif" font-size="38" font-weight="700" fill="#f5f5f7">Bolkit</text>
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
