#!/usr/bin/env node
// render-diagram.mjs — Render docs/data-flow.excalidraw to docs/data-flow.svg.
//
// Why this exists: docs/data-flow.png used to be a PNG with no versioned source, so
// the diagram silently drifted away from the code it documents (the status-line branch
// stayed wrong for a whole release). The .excalidraw file is now the source of truth
// and this script regenerates the image from it, with no round trip through
// excalidraw.com and no manual export step.
//
// Usage:  node docs/render-diagram.mjs [--png]
//   --png also rasterizes the SVG through headless Chrome (macOS/Linux paths probed).
//
// Docs tooling, not runtime: it lives in docs/ so it stays out of the RUNTIME_PATHS
// that check-versions.sh and release.sh watch.
//
// Supports the subset of the Excalidraw format this diagram uses: rectangles (rounded,
// filled, dashed), multi-point arrows with arrowheads, standalone text, and text bound
// to a container. Shapes get a light deterministic jitter so the result keeps the
// hand-drawn feel of the original; text is rendered in a plain system stack, because a
// handwriting font would not be available to whoever opens the README.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, 'data-flow.excalidraw');
const OUT_SVG = join(HERE, 'data-flow.svg');
const OUT_PNG = join(HERE, 'data-flow.png');

const PAD = 24;
const FONT = "ui-sans-serif, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";
const JITTER = 1.6;        // px of hand-drawn wobble
const PNG_SCALE = 2;

// Deterministic PRNG (mulberry32) seeded per element, so re-running produces a
// byte-identical SVG and the diff stays empty when nothing changed.
const rng = (seed) => () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const n = (v) => Number(v.toFixed(2));

// A straight run drawn as a slightly bowed curve, the way a hand would.
function wobble(x1, y1, x2, y2, r) {
  const mx = (x1 + x2) / 2 + (r() - 0.5) * JITTER * 2;
  const my = (y1 + y2) / 2 + (r() - 0.5) * JITTER * 2;
  return `M${n(x1)} ${n(y1)} Q${n(mx)} ${n(my)} ${n(x2)} ${n(y2)}`;
}

function strokeAttrs(el) {
  const o = (el.opacity ?? 100) / 100;
  const w = el.strokeWidth ?? 2;
  const dash = el.strokeStyle === 'dashed' ? ` stroke-dasharray="${w * 4} ${w * 3}"` : '';
  return { o, w, dash, color: el.strokeColor ?? '#1e1e1e' };
}

function rect(el) {
  const { o, w, dash, color } = strokeAttrs(el);
  const { x, y, width: W, height: H } = el;
  const r = rng(el.seed ?? 1);
  const rad = el.roundness ? Math.min(32, Math.min(W, H) * 0.25) : 0;
  const out = [];

  const bg = el.backgroundColor && el.backgroundColor !== 'transparent' ? el.backgroundColor : null;
  if (bg) {
    out.push(`<rect x="${n(x)}" y="${n(y)}" width="${n(W)}" height="${n(H)}" rx="${n(rad)}" `
      + `fill="${bg}" fill-opacity="${o}"/>`);
  }
  // Outline as four wobbled runs, insetting the corners by the radius.
  const d = [
    wobble(x + rad, y, x + W - rad, y, r),
    wobble(x + W, y + rad, x + W, y + H - rad, r),
    wobble(x + W - rad, y + H, x + rad, y + H, r),
    wobble(x, y + H - rad, x, y + rad, r),
  ].join(' ');
  const corners = rad
    ? ` M${n(x + W - rad)} ${n(y)} A${n(rad)} ${n(rad)} 0 0 1 ${n(x + W)} ${n(y + rad)}`
      + ` M${n(x + W)} ${n(y + H - rad)} A${n(rad)} ${n(rad)} 0 0 1 ${n(x + W - rad)} ${n(y + H)}`
      + ` M${n(x + rad)} ${n(y + H)} A${n(rad)} ${n(rad)} 0 0 1 ${n(x)} ${n(y + H - rad)}`
      + ` M${n(x)} ${n(y + rad)} A${n(rad)} ${n(rad)} 0 0 1 ${n(x + rad)} ${n(y)}`
    : '';
  out.push(`<path d="${d}${corners}" fill="none" stroke="${color}" stroke-width="${w}" `
    + `stroke-opacity="${o}" stroke-linecap="round"${dash}/>`);
  return out.join('\n');
}

function arrow(el) {
  const { o, w, dash, color } = strokeAttrs(el);
  const r = rng(el.seed ?? 1);
  const pts = el.points.map(([dx, dy]) => [el.x + dx, el.y + dy]);
  const segs = [];
  for (let i = 1; i < pts.length; i++) {
    segs.push(wobble(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], r));
  }
  const out = [`<path d="${segs.join(' ')}" fill="none" stroke="${color}" stroke-width="${w}" `
    + `stroke-opacity="${o}" stroke-linecap="round"${dash}/>`];

  if (el.endArrowhead) {
    const [px, py] = pts[pts.length - 2];
    const [qx, qy] = pts[pts.length - 1];
    const a = Math.atan2(qy - py, qx - px);
    const L = 14, S = 0.45;
    out.push(`<path d="M${n(qx - L * Math.cos(a - S))} ${n(qy - L * Math.sin(a - S))} L${n(qx)} ${n(qy)} `
      + `L${n(qx - L * Math.cos(a + S))} ${n(qy - L * Math.sin(a + S))}" fill="none" stroke="${color}" `
      + `stroke-width="${w}" stroke-opacity="${o}" stroke-linecap="round" stroke-linejoin="round"/>`);
  }
  return out.join('\n');
}

// Half-way along an arrow measured by arc length. Taking a vertex instead drops the
// label on an elbow, where it collides with whatever the route was bending around.
function midpointOf(a) {
  const pts = a.points.map(([dx, dy]) => [a.x + dx, a.y + dy]);
  const seg = [];
  let total = 0;
  for (let i = 1; i < pts.length; i++) {
    const d = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    seg.push(d); total += d;
  }
  let run = total / 2;
  for (let i = 0; i < seg.length; i++) {
    if (run <= seg[i]) {
      const t = seg[i] === 0 ? 0 : run / seg[i];
      return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t,
              pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t];
    }
    run -= seg[i];
  }
  return pts[pts.length - 1];
}

// Bound labels are centred on their container at render time rather than trusting the
// stored x/y: the real font is not the one the widths were computed with, so anchoring
// is the only thing that survives a different font stack.
function text(el, byId) {
  const o = (el.opacity ?? 100) / 100;
  const lines = el.text.split('\n');
  const lh = (el.lineHeight ?? 1.25) * el.fontSize;
  let x = el.x, anchor = 'start', top = el.y;

  const box = el.containerId ? byId.get(el.containerId) : null;
  if (box) {
    anchor = 'middle';
    if (box.type === 'arrow') {
      const [mx, my] = midpointOf(box);
      x = mx;
      top = my - (lines.length * lh) / 2;
    } else {
      x = box.x + box.width / 2;
      top = box.y + box.height / 2 - (lines.length * lh) / 2;
    }
  }

  // A label on an arrow needs the line behind it knocked out to stay readable.
  const plate = box && box.type === 'arrow'
    ? `<rect x="${n(x - (el.width ?? 60) / 2 - 4)}" y="${n(top)}" width="${n((el.width ?? 60) + 8)}" `
      + `height="${n(lines.length * lh)}" fill="#ffffff" rx="3"/>\n`
    : '';

  const spans = lines.map((l, i) =>
    `<tspan x="${n(x)}" y="${n(top + lh * (i + 0.78))}">${esc(l)}</tspan>`).join('');
  return `${plate}<text font-family="${FONT}" font-size="${el.fontSize}" fill="${el.strokeColor ?? '#1e1e1e'}" `
    + `fill-opacity="${o}" text-anchor="${anchor}">${spans}</text>`;
}

// --- render -----------------------------------------------------------------

if (!existsSync(SRC)) {
  console.error(`render-diagram: missing ${SRC}`);
  process.exit(1);
}
const scene = JSON.parse(readFileSync(SRC, 'utf8'));
const els = scene.elements.filter((e) => !e.isDeleted);
const byId = new Map(els.map((e) => [e.id, e]));

let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
for (const e of els) {
  x0 = Math.min(x0, e.x); y0 = Math.min(y0, e.y);
  x1 = Math.max(x1, e.x + (e.width ?? 0)); y1 = Math.max(y1, e.y + (e.height ?? 0));
}
const W = x1 - x0 + PAD * 2, H = y1 - y0 + PAD * 2;

const body = [];
for (const e of els) {
  if (e.type === 'rectangle') body.push(rect(e));
  else if (e.type === 'arrow') body.push(arrow(e));
}
for (const e of els) if (e.type === 'text') body.push(text(e, byId));

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${n(W)}" height="${n(H)}" `
  + `viewBox="${n(x0 - PAD)} ${n(y0 - PAD)} ${n(W)} ${n(H)}" role="img" `
  + `aria-label="claude-carbon data flow">\n`
  + `<rect x="${n(x0 - PAD)}" y="${n(y0 - PAD)}" width="${n(W)}" height="${n(H)}" fill="#ffffff"/>\n`
  + body.join('\n') + `\n</svg>\n`;

writeFileSync(OUT_SVG, svg);
console.log(`wrote ${OUT_SVG} (${els.length} elements, ${n(W)}x${n(H)})`);

if (process.argv.includes('--png')) {
  const chrome = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ].find(existsSync);
  if (!chrome) {
    console.error('render-diagram: no Chrome/Chromium found, skipping --png');
    process.exit(1);
  }
  execFileSync(chrome, [
    '--headless', '--disable-gpu', '--hide-scrollbars',
    `--screenshot=${OUT_PNG}`,
    `--window-size=${Math.ceil(W)},${Math.ceil(H)}`,
    `--force-device-scale-factor=${PNG_SCALE}`,
    `--default-background-color=FFFFFFFF`,
    `file://${OUT_SVG}`,
  ], { stdio: 'ignore' });
  console.log(`wrote ${OUT_PNG} (${PNG_SCALE}x)`);
}
