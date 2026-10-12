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

// The molecule alone, 200 x 140 user units. Walking, it alternates its two frames at
// `step` ms; standing, it shows frame A. No script: a CSS animation, still under
// reduced motion.
export function mascotSvg(opts: {
  color: string;
  walking: boolean;
  step: number;
  title: string;
}): string {
  const w = SPRITE_WIDTH * 10;
  const h = SPRITE_HEIGHT * 10;
  const period = opts.step * 2;
  const style = opts.walking
    ? `.b{opacity:0}` +
      `@keyframes fa{0%{opacity:1}50%{opacity:0}100%{opacity:0}}` +
      `@keyframes fb{0%{opacity:0}50%{opacity:1}100%{opacity:1}}` +
      `.a{animation:fa ${period}ms steps(1,end) infinite}` +
      `.b{animation:fb ${period}ms steps(1,end) infinite}` +
      `@media (prefers-reduced-motion: reduce){.a,.b{animation:none}.a{opacity:1}.b{opacity:0}}`
    : `.b{opacity:0}`;
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
};

// One rect per stripe, oldest on the left, each with its own tooltip.
export function stripesSvg(stripes: readonly Stripe[], title: string): string {
  const n = Math.max(1, stripes.length);
  const w = n * 10;
  const h = 60;
  const bars = stripes
    .map(
      (s, i) =>
        `<rect x="${i * 10}" y="0" width="10" height="${h}" fill="${s.color ?? EMPTY}"><title>${escapeXml(s.title)}</title></rect>`,
    )
    .join("");
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" shape-rendering="crispEdges">` +
    `<title>${escapeXml(title)}</title>${bars}</svg>`
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
