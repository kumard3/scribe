import sharp from 'sharp';

const TEAL = '#14B8A6';
const TEAL_HI = '#2DD4BF';
const DARK = '#0E0F13';

// Bold "V" with a small 3-bar voice/waveform accent in the notch.
function mark(S, color, accent) {
  const sw = S * 0.13;
  const v = `<path d="M ${0.26 * S} ${0.30 * S} L ${0.50 * S} ${0.74 * S} L ${0.74 * S} ${0.30 * S}" fill="none" stroke="${color}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
  const bw = S * 0.05;
  const r = bw / 2;
  const cyc = 0.205 * S;
  const bars = [
    [-1, 0.07],
    [0, 0.135],
    [1, 0.07],
  ]
    .map(([k, hf]) => {
      const h = S * hf;
      const x = 0.5 * S + k * (bw * 2.3) - bw / 2;
      const y = cyc - h / 2;
      return `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="${r.toFixed(1)}" fill="${accent}"/>`;
    })
    .join('');
  return v + bars;
}

function svg({ S, bg, color, accent, scale = 1 }) {
  const t = (S * (1 - scale)) / 2;
  const inner = `<g transform="translate(${t}, ${t}) scale(${scale})">${mark(S, color, accent)}</g>`;
  const bgEl = bg === 'none' ? '' : `<rect width="${S}" height="${S}" fill="${bg}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">${bgEl}${inner}</svg>`;
}

async function render(svgStr, size, out) {
  await sharp(Buffer.from(svgStr)).resize(size, size).png().toFile(out);
  console.log('wrote', out);
}

const A = 'assets';
// iOS app icon — full-bleed dark, teal V + bright-teal accent
await render(svg({ S: 1024, bg: DARK, color: TEAL, accent: TEAL_HI, scale: 1 }), 1024, `${A}/icon.png`);
// Android adaptive foreground — transparent, mark in the safe zone
await render(svg({ S: 1024, bg: 'none', color: TEAL, accent: TEAL_HI, scale: 0.62 }), 1024, `${A}/android-icon-foreground.png`);
// Android adaptive background — solid dark
await render(
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="${DARK}"/></svg>`,
  1024,
  `${A}/android-icon-background.png`
);
// Android monochrome — white
await render(svg({ S: 1024, bg: 'none', color: '#ffffff', accent: '#ffffff', scale: 0.62 }), 1024, `${A}/android-icon-monochrome.png`);
// Splash mark — transparent so it sits on the splash background color
await render(svg({ S: 1024, bg: 'none', color: TEAL, accent: TEAL_HI, scale: 0.7 }), 1024, `${A}/splash-icon.png`);
// Web favicon
await render(svg({ S: 512, bg: DARK, color: TEAL, accent: TEAL_HI, scale: 1 }), 64, `${A}/favicon.png`);
console.log('done');
