// The mascot, a pixel CO2 molecule (O=C=O: the carbon in the middle carries the eyes),
// and the warming stripes, drawn for the /carbon-panel pane: an SVG where the surface has one
// (the desktop app), terminal cells (Raster) where it does not. docs/mascot-stripes.svg,
// the README banner, is drawn from the same frames and palette (scripts/render-mascot.mjs).
// Pure: no Claude Code API, so Node runs it directly (tests/run-mod-tests.mjs).

// 18 x 14 pixels: # body, k eyes. Frame B is the hop: the whole molecule one pixel up,
// its legs apart; the two alternate into a bouncing walk. Both frames are the same
// size, as a blit wants.
const BODY: readonly string[] = [
  ".......####.......",
  "......######......",
  ".##...######...##.",
  "#######k##k#######",
  "####..#k##k#..####",
  "##################",
  ".##...######...##.",
  "......######......",
  ".......####.......",
];
const EMPTY_ROW = "..................";
export const FRAME_A: readonly string[] = [
  EMPTY_ROW,
  EMPTY_ROW,
  ...BODY,
  ".......#..#.......",
  ".......#..#.......",
  EMPTY_ROW,
];
export const FRAME_B: readonly string[] = [
  EMPTY_ROW,
  ...BODY,
  "......#....#......",
  "......#....#......",
  EMPTY_ROW,
  EMPTY_ROW,
];
export const FRAMES = [FRAME_A, FRAME_B] as const;

// The terminal's molecule, small enough for an editor's terminal: 13 x 8 pixels, four
// rows of half blocks, about the size of the engine's own welcome mascot. No outline.
// Frame B hops one pixel, half a terminal row, legs apart.
const MINI_BODY: readonly string[] = [
  "....#####....",
  ".##.#k#k#.##.",
  "#############",
  ".##.#####.##.",
  "....#####....",
];
const MINI_EMPTY = ".............";
export const MINI_FRAMES = [
  [MINI_EMPTY, MINI_EMPTY, ...MINI_BODY, ".....#.#....."],
  [MINI_EMPTY, ...MINI_BODY, "....#...#....", MINI_EMPTY],
] as const;

// Dark blue to dark red, one colour per power of two around the median: the bluest under
// an eighth of it, the reddest over eight times it.
export const PALETTE = [
  "#08306b",
  "#2166ac",
  "#6aa6d0",
  "#c6dbef",
  "#fcbba1",
  "#ef6548",
  "#c41a1d",
  "#67000d",
] as const;
// Too little history to compare against: the molecule stays grey.
export const NEUTRAL = "#8b949e";
// The outline that keeps the darkest colours visible on a dark background (the SVGs).
export const OUTLINE = "#8b949e";
const EYES_DARK = "#0b0b0b";
const EYES_LIGHT = "#d9dce3";
// An empty period on the stripes (no session that week or month)
export const EMPTY = "#30363d";

export const SPRITE_WIDTH = 20;
export const SPRITE_HEIGHT = 16;
// The terminal's Raster: two pixel rows per terminal row (half blocks)
export const CELL_COLUMNS = 13;
export const CELL_ROWS = 4;

export function classOf(grams: number, median: number): number {
  if (!(median > 0) || !(grams > 0)) return 0;
  const cls = Math.floor(Math.log2(grams / median)) + 4;
  return Math.min(7, Math.max(0, cls));
}

// At rest the molecule still breathes: a slow bob, one frame every 1.2 s
export const IDLE_STEP_MS = 1200;

// One step of the walk: 460 ms for the bluest, 124 ms for the reddest.
export function stepMs(cls: number): number {
  return 460 - Math.min(7, Math.max(0, cls)) * 48;
}

export function colorOf(cls: number | null): string {
  return cls === null ? NEUTRAL : (PALETTE[cls] ?? NEUTRAL);
}

export function eyesFor(color: string): string {
  return color === PALETTE[0] || color === PALETTE[7] ? EYES_LIGHT : EYES_DARK;
}

type Pixel = "body" | "eye" | "outline" | null;

// The frame on a 20 x 16 grid: one pixel of outline around the 18 x 14 drawing.
export function pixels(frame: readonly string[]): Pixel[][] {
  const grid: Pixel[][] = Array.from({ length: SPRITE_HEIGHT }, () =>
    Array.from({ length: SPRITE_WIDTH }, () => null as Pixel),
  );
  frame.forEach((row, y) =>
    [...row].forEach((c, x) => {
      const line = grid[y + 1];
      if (line === undefined) return;
      if (c === "#") line[x + 1] = "body";
      else if (c === "k") line[x + 1] = "eye";
    }),
  );
  for (let y = 0; y < SPRITE_HEIGHT; y++)
    for (let x = 0; x < SPRITE_WIDTH; x++) {
      if (grid[y]?.[x] !== null) continue;
      const near = [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
      ].some(([dx, dy]) => {
        const v = grid[y + (dy ?? 0)]?.[x + (dx ?? 0)];
        return v === "body" || v === "eye";
      });
      const line = grid[y];
      if (near && line !== undefined) line[x] = "outline";
    }
  return grid;
}

function rects(grid: Pixel[][], kind: Pixel, px: number): string {
  let d = "";
  grid.forEach((row, y) =>
    row.forEach((v, x) => {
      if (v === kind) d += `M${x * px} ${y * px}h${px}v${px}h-${px}z`;
    }),
  );
  return d;
}

function frameGroup(
  frame: readonly string[],
  color: string,
  cls: string,
): string {
  const grid = pixels(frame);
  return (
    `<g class="${cls}">` +
    `<path fill="${OUTLINE}" fill-opacity="0.45" d="${rects(grid, "outline", 10)}"/>` +
    `<path fill="${color}" d="${rects(grid, "body", 10)}"/>` +
    `<path fill="${eyesFor(color)}" d="${rects(grid, "eye", 10)}"/>` +
    `</g>`
  );
}

function escapeXml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

// The molecule alone. Walking, it alternates its two frames at `step` ms; at rest it
// bobs slowly, IDLE_STEP_MS a frame. No script: a CSS animation, still under reduced
// motion.
export function mascotSvg(opts: {
  color: string;
  walking: boolean;
  step: number;
  title: string;
}): string {
  const w = SPRITE_WIDTH * 10;
  const h = SPRITE_HEIGHT * 10;
  const period = (opts.walking ? opts.step : IDLE_STEP_MS) * 2;
  const style =
    `.b{opacity:0}` +
    `@keyframes fa{0%{opacity:1}50%{opacity:0}100%{opacity:0}}` +
    `@keyframes fb{0%{opacity:0}50%{opacity:1}100%{opacity:1}}` +
    `.a{animation:fa ${period}ms steps(1,end) infinite}` +
    `.b{animation:fb ${period}ms steps(1,end) infinite}` +
    `@media (prefers-reduced-motion: reduce){.a,.b{animation:none}.a{opacity:1}.b{opacity:0}}`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" shape-rendering="crispEdges">` +
    `<title>${escapeXml(opts.title)}</title><style>${style}</style>` +
    frameGroup(FRAME_A, opts.color, "a") +
    frameGroup(FRAME_B, opts.color, "b") +
    `</svg>`
  );
}

export type Stripe = {
  // null: an empty period, drawn in the empty colour
  color: string | null;
  // Shown on hover in the desktop app: the period and its total
  title: string;
  // Start of the period, ms since the epoch
  start?: number;
};

// The running session's subagents, a small molecule each, in a row under the big one:
// frame A at 3 px a pixel, each with its own colour and a <title> (its CO2).
export const SUBAGENT_PX = 3;
export function subagentsSvg(
  agents: ReadonlyArray<{ color: string; title: string }>,
  title: string,
): string {
  const w = SPRITE_WIDTH * SUBAGENT_PX;
  const h = SPRITE_HEIGHT * SUBAGENT_PX;
  const gap = 6;
  const grid = pixels(FRAME_A);
  const cells = (kind: Pixel, ox: number) => {
    let d = "";
    grid.forEach((row, y) =>
      row.forEach((v, x) => {
        if (v === kind)
          d += `M${ox + x * SUBAGENT_PX} ${y * SUBAGENT_PX}h${SUBAGENT_PX}v${SUBAGENT_PX}h-${SUBAGENT_PX}z`;
      }),
    );
    return d;
  };
  const items = agents
    .map((a, i) => {
      const ox = i * (w + gap);
      return (
        `<g><title>${escapeXml(a.title)}</title>` +
        `<path fill="${OUTLINE}" fill-opacity="0.45" d="${cells("outline", ox)}"/>` +
        `<path fill="${a.color}" d="${cells("body", ox)}"/>` +
        `<path fill="${eyesFor(a.color)}" d="${cells("eye", ox)}"/></g>`
      );
    })
    .join("");
  const total = Math.max(1, agents.length) * (w + gap) - gap;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${h}" width="${total}" height="${h}" shape-rendering="crispEdges">` +
    `<title>${escapeXml(title)}</title>${items}</svg>`
  );
}

// A small (i) whose tooltip says what a figure means: a grey ring and an i, drawn in
// pixels so no font is needed, the text in its <title>.
export function infoIconSvg(text: string): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 14 14" width="14" height="14">` +
    `<title>${escapeXml(text)}</title>` +
    `<circle cx="7" cy="7" r="6" fill="none" stroke="${OUTLINE}" stroke-width="1.2"/>` +
    `<rect x="6.3" y="3.2" width="1.4" height="1.4" fill="${OUTLINE}"/>` +
    `<rect x="6.3" y="5.6" width="1.4" height="5.2" fill="${OUTLINE}"/></svg>`
  );
}

export const STRIPES_HEIGHT = 72;
// The hovered stripe's label shows over the stripes' foot: no room kept for it
export const STRIPES_SVG_HEIGHT = STRIPES_HEIGHT;

// One rect per stripe across `width` CSS pixels (the viewBox matches the drawn size, so
// labels keep their shape), oldest on the left; an empty period is a faint grey. All the
// stripes come first, then all the labels, hidden, in a layer above them: hovering
// stripe i lights it up and shows label i at once over the stripes' foot, in a dark box
// readable on a light or a dark pane, never under the next stripe. A CSS :hover and the
// sibling selector, no script, and no <title>: the app's own tooltip would show a second
// label late. The Svg's alt says what the drawing is.
export function stripesSvg(
  stripes: readonly Stripe[],
  _title: string,
  width: number,
): string {
  const n = Math.max(1, stripes.length);
  const sw = width / n;
  const h = STRIPES_HEIGHT;
  const rects = stripes
    .map((s, i) => {
      const fill = s.color === null ? `fill="${OUTLINE}" fill-opacity="0.2"` : `fill="${s.color}"`;
      return `<rect id="b${i}" class="b" x="${(i * sw).toFixed(2)}" y="0" width="${sw.toFixed(2)}" height="${h}" ${fill}/>`;
    })
    .join("");
  const labels = stripes
    .map((s, i) => {
      // About 6 px a character at 12 px, kept inside the drawing
      const boxW = Math.min(width, s.title.length * 6 + 14);
      const centre = i * sw + sw / 2;
      const boxX = Math.max(0, Math.min(width - boxW, centre - boxW / 2));
      return (
        `<g id="t${i}" class="t"><rect x="${boxX.toFixed(2)}" y="${h - 26}" width="${boxW.toFixed(2)}" height="22" rx="4" fill="#1f2328" stroke="${OUTLINE}" stroke-opacity="0.6"/>` +
        `<text x="${(boxX + 7).toFixed(2)}" y="${h - 11}" font-size="12" font-family="system-ui,-apple-system,sans-serif" fill="#ffffff">${escapeXml(s.title)}</text></g>`
      );
    })
    .join("");
  const show = stripes.map((_, i) => `#b${i}:hover~#t${i}`).join(",");
  const style =
    `<style>.t{opacity:0;pointer-events:none}` +
    `.b:hover{opacity:.7;stroke:#ffffff;stroke-width:2}` +
    (stripes.length > 0 ? `${show}{opacity:1}` : "") +
    `</style>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${STRIPES_SVG_HEIGHT}" width="${width}" height="${STRIPES_SVG_HEIGHT}">` +
    `${style}${rects}${labels}</svg>`
  );
}

// ── Terminal cells (Raster) ─────────────────────────────────────────────────

const DEFAULT_COLOR = 0x01000000;
const UPPER_HALF = 0x2580; // ▀
const LOWER_HALF = 0x2584; // ▄
const FULL_BLOCK = 0x2588; // █
const SPACE = 0x20;

function rgb(hex: string): number {
  return Number.parseInt(hex.slice(1), 16) & 0xffffff;
}

// Standard padded base64 of little-endian u32 triplets, as RasterProps.cells wants.
// No Uint8Array.toBase64: Node 22, where the pure tests run, does not have it.
export function encodeCells(words: readonly number[]): string {
  const bytes = new Uint8Array(words.length * 4);
  const view = new DataView(bytes.buffer);
  words.forEach((w, i) => view.setUint32(i * 4, w >>> 0, true));
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

// One triplet per cell, two pixels a cell: the top pixel in the foreground of an upper
// half block, the bottom one in its background. A transparent pixel is the terminal's
// default colour, so a cell with only its bottom pixel takes a lower half block instead.
export function mascotWords(frame: readonly string[], color: string): number[] {
  const paint = (c: string | undefined): number | null =>
    c === "#" ? rgb(color) : c === "k" ? rgb(eyesFor(color)) : null;
  const words: number[] = [];
  for (let row = 0; row < CELL_ROWS; row++)
    for (let x = 0; x < CELL_COLUMNS; x++) {
      const top = paint(frame[row * 2]?.[x]);
      const bottom = paint(frame[row * 2 + 1]?.[x]);
      if (top !== null) words.push(UPPER_HALF, top, bottom ?? DEFAULT_COLOR);
      else if (bottom !== null) words.push(LOWER_HALF, bottom, DEFAULT_COLOR);
      else words.push(SPACE, DEFAULT_COLOR, DEFAULT_COLOR);
    }
  return words;
}

export function mascotCells(frame: readonly string[], color: string): string {
  return encodeCells(mascotWords(frame, color));
}

// `width` columns per stripe, `rows` tall, full blocks in the stripe's colour.
export function stripeWords(
  stripes: readonly Stripe[],
  rows: number,
  width = 1,
): number[] {
  const words: number[] = [];
  for (let r = 0; r < rows; r++)
    for (const s of stripes)
      for (let w = 0; w < width; w++)
        words.push(FULL_BLOCK, rgb(s.color ?? EMPTY), DEFAULT_COLOR);
  return words;
}

export function stripeCells(
  stripes: readonly Stripe[],
  rows: number,
  width = 1,
): string {
  return encodeCells(stripeWords(stripes, rows, width));
}
