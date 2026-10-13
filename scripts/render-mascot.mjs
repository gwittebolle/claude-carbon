#!/usr/bin/env node
// render-mascot.mjs: draws the README's molecules from the mod's own frames, faces and
// palette (hooks/mod/lib/mascot.ts), so the pictures match the /carbon-panel pane:
//   docs/mascot-stripes.svg  the banner: eight molecules from dark blue to dark red, each
//                            walking at the pace the pane gives its colour, with the
//                            faces of a light, an ordinary or a heavy session
//   docs/molecule-moods.svg  the eight moods, each with its caption
// CSS animations, no script; still under reduced motion.
// With --gif <file>: the moods as an animated GIF too, for places an SVG does not play
// (a social post). Needs ImageMagick (`magick`).
// Run: node --experimental-strip-types scripts/render-mascot.mjs [--gif out.gif]

import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  IDLE_STEP_MS,
  NEUTRAL,
  OUTLINE,
  PALETTE,
  SPRITE_HEIGHT,
  SPRITE_WIDTH,
  SWEAT,
  ZED,
  eyesFor,
  faceAt,
  faceFrame,
  isStill,
  moleculeCss,
  moleculeHop,
  pixels,
  stepMs,
} from "../hooks/mod/lib/mascot.ts";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const PX = 10;
const W = SPRITE_WIDTH * PX;
const H = SPRITE_HEIGHT * PX;

// One molecule of a drawing: its group, scoped CSS, and where it sits
function molecule(i, { color, mood, walking, step, ox, oy }) {
  const scope = `m${i}`;
  // Out of step with each other, so they do not march or blink in time
  const { css, faces } = moleculeCss(mood, (walking ? step : IDLE_STEP_MS) * 2, {
    scope,
    hopDelay: i * 137,
    faceDelay: i * 1370,
  });
  const g =
    `<g class="${scope}" transform="translate(${ox} ${oy})">` +
    moleculeHop(0, color, faces, PX, 0) +
    moleculeHop(1, color, faces, PX, 0) +
    `</g>`;
  return { css, g };
}

function svgOf(width, height, label, parts, extra = "") {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width / 2}" height="${height / 2}" shape-rendering="crispEdges" role="img" aria-label="${label}">` +
    `<title>${label}</title><style>${parts.map((p) => p.css).join("")}</style>` +
    parts.map((p) => p.g).join("") +
    extra +
    `</svg>\n`
  );
}

// The banner: the eight colours in a row, each with the mood of its weight
const GAP = 2 * PX;
const bannerWidth = PALETTE.length * W + (PALETTE.length - 1) * GAP;
const moodOfClass = (cls) => (cls <= 1 ? "cheerful" : cls >= 6 ? "strained" : "working");
const banner = svgOf(
  bannerWidth,
  H,
  "Eight pixel CO2 molecules, the claude-carbon mascot, walking from dark blue to dark red, the redder the faster: the blue ones smile, the red ones sweat",
  PALETTE.map((color, i) =>
    molecule(i, { color, mood: moodOfClass(i), walking: true, step: stepMs(i), ox: i * (W + GAP), oy: 0 }),
  ),
);
writeFileSync(join(REPO, "docs/mascot-stripes.svg"), banner);
console.log(`docs/mascot-stripes.svg: ${banner.length} bytes`);

// The moods, two rows of four, each over its caption
const MOODS_SHOWN = [
  { mood: "waiting", color: NEUTRAL, cls: 3, caption: "Before the first answer" },
  { mood: "working", color: PALETTE[4], cls: 4, caption: "At work" },
  { mood: "cheerful", color: PALETTE[1], cls: 1, caption: "A light session" },
  { mood: "strained", color: PALETTE[7], cls: 7, caption: "A heavy session" },
  { mood: "pleased", color: PALETTE[3], cls: 3, caption: "After an answer" },
  { mood: "phew", color: PALETTE[6], cls: 6, caption: "After a heavy one" },
  { mood: "idle", color: PALETTE[2], cls: 2, caption: "At rest" },
  { mood: "asleep", color: PALETTE[0], cls: 0, caption: "Five idle minutes" },
];
const COLS = 4;
// Room on each side for a caption wider than its molecule
const PAD = 60;
const CELL = W + 60;
const CAPTION = 56;
const ROW = H + CAPTION + 24;
const movesWidth = COLS * CELL - 60 + 2 * PAD;
const movesHeight = Math.ceil(MOODS_SHOWN.length / COLS) * ROW - 24;
const at = (i) => ({ ox: PAD + (i % COLS) * CELL, oy: Math.floor(i / COLS) * ROW });
const isWalking = (mood) => ["working", "cheerful", "strained"].includes(mood);
const captions = MOODS_SHOWN.map((m, i) => {
  const { ox, oy } = at(i);
  return `<text x="${ox + W / 2}" y="${oy + H + 40}" text-anchor="middle" font-size="26" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif" fill="${OUTLINE}">${m.caption}</text>`;
}).join("");
const moods = svgOf(
  movesWidth,
  movesHeight,
  "The molecule's eight moods: it looks around before the first answer, glances aside at work, smiles through a light session, sweats through a heavy one, smiles or startles after an answer, winks at rest and falls asleep after five idle minutes",
  MOODS_SHOWN.map((m, i) =>
    molecule(i, { color: m.color, mood: m.mood, walking: isWalking(m.mood), step: stepMs(m.cls), ...at(i) }),
  ),
  captions,
);
writeFileSync(join(REPO, "docs/molecule-moods.svg"), moods);
console.log(`docs/molecule-moods.svg: ${moods.length} bytes`);

// ── The GIF: the same moods drawn frame by frame, on white ──────────────────────
const gifAt = process.argv.indexOf("--gif");
if (gifAt !== -1) {
  const out = process.argv[gifAt + 1];
  if (!out) throw new Error("--gif needs a file");
  // A pixel of the molecule is 10 GIF pixels: about 1080 wide, for a post
  const SCALE = 10;
  const FRAME_MS = 50;
  const SECONDS = 12;
  const rgb = (hex) => [1, 3, 5].map((o) => Number.parseInt(hex.slice(o, o + 2), 16));
  const mix = (a, b, t) => a.map((v, i) => Math.round(v * (1 - t) + b[i] * t));
  const WHITE = [255, 255, 255];
  const width = (movesWidth / PX) * SCALE;
  const height = (movesHeight / PX) * SCALE;
  const dir = mkdtempSync(join(tmpdir(), "molecule-gif-"));
  for (let n = 0; n < (SECONDS * 1000) / FRAME_MS; n++) {
    const t = n * FRAME_MS;
    const img = Buffer.alloc(width * height * 3, 255);
    MOODS_SHOWN.forEach((m, i) => {
      const step = isWalking(m.mood) ? stepMs(m.cls) : IDLE_STEP_MS;
      const hop = isStill(m.mood) ? 0 : Math.floor((t + i * 137) / step) % 2;
      const { face } = faceAt(m.mood, t + i * 1370);
      const paint = {
        outline: mix(WHITE, rgb(OUTLINE), 0.45),
        body: rgb(m.color),
        eye: rgb(eyesFor(m.color)),
        sweat: rgb(SWEAT),
        zed: rgb(ZED),
      };
      const { ox, oy } = at(i);
      pixels(faceFrame(hop, face)).forEach((row, y) =>
        row.forEach((kind, x) => {
          if (kind === null) return;
          const c = paint[kind];
          for (let dy = 0; dy < SCALE; dy++)
            for (let dx = 0; dx < SCALE; dx++) {
              const px = (ox / PX) * SCALE + x * SCALE + dx;
              const py = (oy / PX) * SCALE + y * SCALE + dy;
              const o = (py * width + px) * 3;
              img[o] = c[0];
              img[o + 1] = c[1];
              img[o + 2] = c[2];
            }
        }),
      );
    });
    const header = Buffer.from(`P6\n${width} ${height}\n255\n`);
    writeFileSync(join(dir, `f${String(n).padStart(4, "0")}.ppm`), Buffer.concat([header, img]));
  }
  // The captions, drawn once and laid over every frame
  const labels = join(dir, "labels.png");
  const draws = MOODS_SHOWN.flatMap((m, i) => {
    const { ox, oy } = at(i);
    const x = Math.round(((ox + W / 2) / PX) * SCALE);
    const y = Math.round(((oy + H + 40) / PX) * SCALE);
    return ["-draw", `text ${x - Math.round((m.caption.length * 3.3 * SCALE) / 5)},${y} '${m.caption}'`];
  });
  execFileSync("magick", [
    "-size", `${width}x${height}`, "xc:none", "-fill", OUTLINE, "-font", "/System/Library/Fonts/Supplemental/Arial.ttf",
    "-pointsize", String((13 * SCALE) / 5), ...draws, labels,
  ]);
  execFileSync("magick", [
    "-delay", String(FRAME_MS / 10), "-loop", "0", join(dir, "f*.ppm"), "null:", labels,
    "-layers", "composite", "-layers", "Optimize", out,
  ]);
  console.log(`${out}: written`);
}
