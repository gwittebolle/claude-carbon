// The mascot, a pixel CO2 molecule (O=C=O: the carbon in the middle carries the eyes),
// and the warming stripes, drawn for the /carbon-panel pane: SVGs in the desktop app, the
// molecule alone in terminal cells (Raster) in a terminal. docs/mascot-stripes.svg,
// the README banner, is drawn from the same frames and palette (scripts/render-mascot.mjs).
// Pure: no Claude Code API, so Node runs it directly (tests/run-mod-tests.mjs).

// 18 x 14 pixels: # body. Frame B is the hop: the whole molecule one pixel up, its legs
// apart; the two alternate into a bouncing walk. Both frames are the same size, as a
// blit wants. The face is drawn over the body (FACES): k eyes and mouth, s a drop of
// sweat, z a sleeper's z.
const BODY: readonly string[] = [
  ".......####.......",
  "......######......",
  ".##...######...##.",
  "##################",
  "####..######..####",
  "##################",
  ".##...######...##.",
  "......######......",
  ".......####.......",
];
const EMPTY_ROW = "..................";
// Where BODY's first row sits in each hop frame
const HOP_TOP = [2, 1] as const;
const HOPS: readonly (readonly string[])[] = [
  [EMPTY_ROW, EMPTY_ROW, ...BODY, ".......#..#.......", ".......#..#.......", EMPTY_ROW],
  [EMPTY_ROW, ...BODY, "......#....#......", "......#....#......", EMPTY_ROW, EMPTY_ROW],
];

// The terminal's molecule, small enough for an editor's terminal: 13 x 8 pixels, four
// rows of half blocks, about the size of the engine's own welcome mascot. No outline.
// Frame B hops one pixel, half a terminal row, legs apart.
const MINI_BODY: readonly string[] = [
  "....#####....",
  ".##.#####.##.",
  "#############",
  ".##.#####.##.",
  "....#####....",
];
const MINI_EMPTY = ".............";
const MINI_HOPS: readonly (readonly string[])[] = [
  [MINI_EMPTY, MINI_EMPTY, ...MINI_BODY, ".....#.#....."],
  [MINI_EMPTY, ...MINI_BODY, "....#...#....", MINI_EMPTY],
];

// The molecule's faces. Each is a set of marks in BODY's coordinates (x, y), the same
// names for the big molecule and the terminal's small one.
export type Face =
  | "neutral"
  | "blink"
  | "lookLeft"
  | "lookRight"
  | "lookUp"
  | "wink"
  | "happy"
  | "surprised"
  | "worried"
  | "worriedBlink"
  | "sleep"
  | "doze";
// k eyes and mouth, s sweat, z a Z in pixels; g a cell of the terminal's molecule that
// shows the letter z instead (a Z of a few pixels does not read there)
type Marks = {
  k: readonly (readonly [number, number])[];
  s?: readonly (readonly [number, number])[];
  z?: readonly (readonly [number, number])[];
  g?: readonly (readonly [number, number])[];
};
// A Z of 4 x 4 with its diagonal, above the right oxygen: room the first hop alone has,
// so the molecule asleep does not hop
const Z = [
  [14, -2], [15, -2], [16, -2], [17, -2],
  [16, -1],
  [15, 0],
  [14, 1], [15, 1], [16, 1], [17, 1],
] as const;
const DROP = [[13, 0], [13, 1]] as const;
const SMILE = [[7, 6], [8, 7], [9, 7], [10, 6]] as const;
const FLAT = [[8, 6], [9, 6]] as const;
const EYES = [[7, 3], [7, 4], [10, 3], [10, 4]] as const;
const SHUT = [[7, 4], [10, 4]] as const;
const FACES: Record<Face, Marks> = {
  neutral: { k: EYES },
  blink: { k: SHUT },
  lookLeft: { k: [[6, 3], [6, 4], [9, 3], [9, 4]] },
  lookRight: { k: [[8, 3], [8, 4], [11, 3], [11, 4]] },
  lookUp: { k: [[7, 2], [7, 3], [10, 2], [10, 3]] },
  wink: { k: [[7, 3], [7, 4], [10, 4], ...SMILE] },
  happy: { k: [[7, 3], [6, 4], [8, 4], [10, 3], [9, 4], [11, 4], ...SMILE] },
  surprised: { k: [[7, 2], [7, 3], [7, 4], [10, 2], [10, 3], [10, 4], [8, 6], [9, 6], [8, 7], [9, 7]] },
  worried: { k: [...EYES, ...FLAT], s: DROP },
  worriedBlink: { k: [...SHUT, ...FLAT], s: DROP },
  sleep: { k: SHUT, z: Z },
  doze: { k: SHUT },
};
const MINI_SMILE = [[5, 3], [6, 4], [7, 3]] as const;
const MINI_EYES = [[5, 1], [7, 1]] as const;
const MINI_FACES: Record<Face, Marks> = {
  neutral: { k: MINI_EYES },
  // One row of eyes: shut, they are gone for a moment
  blink: { k: [] },
  lookLeft: { k: [[4, 1], [6, 1]] },
  lookRight: { k: [[6, 1], [8, 1]] },
  lookUp: { k: [[5, 0], [7, 0]] },
  wink: { k: [[5, 1], ...MINI_SMILE] },
  happy: { k: [...MINI_EYES, ...MINI_SMILE] },
  surprised: { k: [[5, 0], [5, 1], [7, 0], [7, 1], [6, 3], [6, 4]] },
  worried: { k: [...MINI_EYES, [5, 3], [6, 3], [7, 3]], s: [[10, 0], [10, -1]] },
  worriedBlink: { k: [[5, 3], [6, 3], [7, 3]], s: [[10, 0], [10, -1]] },
  sleep: { k: [], g: [[10, -2], [12, -2]] },
  doze: { k: [] },
};

function withMarks(hop: readonly string[], top: number, marks: Marks): string[] {
  const rows = hop.map((r) => [...r]);
  const put = (list: Marks["k"] | undefined, c: string) =>
    list?.forEach(([x, y]) => {
      const row = rows[y + top];
      if (row !== undefined && x >= 0 && x < row.length) row[x] = c;
    });
  put(marks.k, "k");
  put(marks.s, "s");
  put(marks.z, "z");
  put(marks.g, "g");
  return rows.map((r) => r.join(""));
}

// A hop frame (0 or 1) with a face, big or small
export function faceFrame(hop: 0 | 1, face: Face): string[] {
  return withMarks(HOPS[hop] ?? HOPS[0]!, HOP_TOP[hop], FACES[face]);
}
export function miniFaceFrame(hop: 0 | 1, face: Face): string[] {
  return withMarks(MINI_HOPS[hop] ?? MINI_HOPS[0]!, HOP_TOP[hop], MINI_FACES[face]);
}

export const FRAME_A: readonly string[] = faceFrame(0, "neutral");
export const FRAME_B: readonly string[] = faceFrame(1, "neutral");
export const FRAMES = [FRAME_A, FRAME_B] as const;
export const MINI_FRAMES = [miniFaceFrame(0, "neutral"), miniFaceFrame(1, "neutral")] as const;

// What the molecule is up to, and the faces it pulls meanwhile, in a loop: each face
// with how long it holds (ms).
export type Mood =
  | "idle"
  | "waiting"
  | "working"
  | "cheerful"
  | "strained"
  | "pleased"
  | "phew"
  | "asleep";
export const MOODS: Record<Mood, ReadonlyArray<readonly [Face, number]>> = {
  idle: [
    ["neutral", 2400], ["blink", 150], ["neutral", 1700], ["lookLeft", 800],
    ["neutral", 250], ["lookRight", 800], ["neutral", 1500], ["wink", 500],
    ["neutral", 1300], ["lookUp", 700], ["neutral", 1900], ["blink", 120],
    ["neutral", 140], ["blink", 120], ["neutral", 1100], ["happy", 1300],
  ],
  // No answer yet: it looks around
  waiting: [
    ["lookLeft", 900], ["neutral", 500], ["lookRight", 900], ["neutral", 600],
    ["lookUp", 700], ["blink", 150], ["neutral", 1200],
  ],
  working: [
    ["neutral", 1300], ["blink", 120], ["neutral", 900], ["lookRight", 450],
    ["neutral", 1100], ["lookLeft", 450], ["neutral", 800], ["blink", 120],
    ["neutral", 600], ["lookUp", 400],
  ],
  // A light session at work
  cheerful: [
    ["happy", 900], ["neutral", 900], ["blink", 120], ["neutral", 700],
    ["happy", 700], ["lookRight", 400], ["neutral", 500],
  ],
  // A heavy session at work: it sweats
  strained: [
    ["worried", 1300], ["worriedBlink", 120], ["worried", 900], ["surprised", 400],
    ["worried", 1100], ["worriedBlink", 120],
  ],
  // Right after an answer
  pleased: [["happy", 2400]],
  phew: [["surprised", 700], ["worriedBlink", 150], ["worried", 1550]],
  asleep: [["sleep", 1400], ["doze", 1000]],
};

// A mood in which the molecule does not hop
export function isStill(mood: Mood): boolean {
  return mood === "asleep";
}

// How long the molecule reacts to an answer, and how long it stays idle before it sleeps
export const REACT_MS = 2400;
export const SLEEP_AFTER_MS = 5 * 60_000;

export function moodOf(o: {
  working: boolean;
  cls: number | null;
  hasAnswer: boolean;
  // Since the last turn started or ended, ms
  idleMs: number;
  // Within REACT_MS of an answer
  reacting: boolean;
}): Mood {
  const heavy = o.cls !== null && o.cls >= 6;
  const light = o.cls !== null && o.cls <= 1;
  if (o.working) return heavy ? "strained" : light ? "cheerful" : "working";
  if (o.reacting) return heavy ? "phew" : "pleased";
  if (!o.hasAnswer) return "waiting";
  return o.idleMs >= SLEEP_AFTER_MS ? "asleep" : "idle";
}

// The face `t` ms into a mood's loop, and how long it holds from there
export function faceAt(mood: Mood, t: number): { face: Face; holdMs: number } {
  const loop = MOODS[mood];
  const total = loop.reduce((sum, [, ms]) => sum + ms, 0);
  let at = ((t % total) + total) % total;
  for (const [face, ms] of loop) {
    if (at < ms) return { face, holdMs: ms - at };
    at -= ms;
  }
  const first = loop[0];
  return { face: first?.[0] ?? "neutral", holdMs: first?.[1] ?? total };
}

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

// A drop of sweat, and a sleeper's z
export const SWEAT = "#4f9fd8";
export const ZED = OUTLINE;

type Pixel = "body" | "eye" | "sweat" | "zed" | "outline" | null;
const KIND: Record<string, Pixel> = { "#": "body", k: "eye", s: "sweat", z: "zed" };

// The frame on a 20 x 16 grid: one pixel of outline around the 18 x 14 drawing (around
// the body and the face, not around a drop or a z).
export function pixels(frame: readonly string[]): Pixel[][] {
  const grid: Pixel[][] = Array.from({ length: SPRITE_HEIGHT }, () =>
    Array.from({ length: SPRITE_WIDTH }, () => null as Pixel),
  );
  frame.forEach((row, y) =>
    [...row].forEach((c, x) => {
      const line = grid[y + 1];
      if (line === undefined) return;
      line[x + 1] = KIND[c] ?? null;
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

function rects(grid: Pixel[][], kind: Pixel, px: number, ox = 0): string {
  let d = "";
  grid.forEach((row, y) =>
    row.forEach((v, x) => {
      if (v === kind) d += `M${ox + x * px} ${y * px}h${px}v${px}h-${px}z`;
    }),
  );
  return d;
}

function escapeXml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function path(fill: string, d: string, extra = ""): string {
  return d === "" ? "" : `<path fill="${fill}"${extra} d="${d}"/>`;
}

// One hop of a molecule: its outline and body, then each face it may pull, stacked and
// hidden but for the one the animation shows. The body is the same under every face.
export function moleculeHop(
  hop: 0 | 1,
  color: string,
  faces: readonly Face[],
  px: number,
  ox: number,
): string {
  const bare = pixels(withMarks(HOPS[hop] ?? HOPS[0]!, HOP_TOP[hop], { k: [] }));
  const face = (f: Face) => {
    const grid = pixels(faceFrame(hop, f));
    return (
      `<g class="f f-${f}">` +
      path(eyesFor(color), rects(grid, "eye", px, ox)) +
      path(SWEAT, rects(grid, "sweat", px, ox)) +
      path(ZED, rects(grid, "zed", px, ox)) +
      `</g>`
    );
  };
  return (
    `<g class="${hop === 0 ? "a" : "b"}">` +
    path(OUTLINE, rects(bare, "outline", px, ox), ` fill-opacity="0.45"`) +
    path(color, rects(bare, "body", px, ox)) +
    faces.map(face).join("") +
    `</g>`
  );
}

// The CSS that walks or breathes (the two hops) and runs a mood's faces in a loop. Under
// reduced motion: the first hop and the mood's first face, still. With a scope (a class
// on the molecule's group), several molecules in one drawing each keep their own mood
// and phase: the README's banner and its row of moods.
export function moleculeCss(
  mood: Mood,
  hopPeriod: number,
  opts: { scope?: string; hopDelay?: number; faceDelay?: number } = {},
): { css: string; faces: Face[] } {
  const loop = MOODS[mood];
  const faces = [...new Set(loop.map(([f]) => f))];
  const total = loop.reduce((sum, [, ms]) => sum + ms, 0);
  const p = opts.scope !== undefined ? `.${opts.scope} ` : "";
  const k = opts.scope !== undefined ? `${opts.scope}-` : "";
  const hopDelay = opts.hopDelay ? ` -${opts.hopDelay}ms` : "";
  const faceDelay = opts.faceDelay ? ` -${opts.faceDelay}ms` : "";
  const css = [`${p}.b{opacity:0}${p}.f{opacity:0}`];
  // Asleep it lies still: its Z takes the room the hop would
  if (!isStill(mood))
    css.push(
      `@keyframes fa{0%{opacity:1}50%{opacity:0}100%{opacity:0}}`,
      `@keyframes fb{0%{opacity:0}50%{opacity:1}100%{opacity:1}}`,
      `${p}.a{animation:fa ${hopPeriod}ms steps(1,end) infinite${hopDelay}}`,
      `${p}.b{animation:fb ${hopPeriod}ms steps(1,end) infinite${hopDelay}}`,
    );
  if (faces.length === 1) {
    css.push(`${p}.f-${faces[0]}{opacity:1}`);
  } else {
    for (const f of faces) {
      let at = 0;
      const stops: string[] = [];
      for (const [g, ms] of loop) {
        stops.push(`${((at / total) * 100).toFixed(3)}%{opacity:${g === f ? 1 : 0}}`);
        at += ms;
      }
      const last = loop[loop.length - 1];
      stops.push(`100%{opacity:${last !== undefined && last[0] === f ? 1 : 0}}`);
      css.push(
        `@keyframes k-${k}${f}{${stops.join("")}}`,
        `${p}.f-${f}{animation:k-${k}${f} ${total}ms steps(1,end) infinite${faceDelay}}`,
      );
    }
  }
  css.push(
    `@media (prefers-reduced-motion: reduce){${p}.a,${p}.b,${p}.f{animation:none}${p}.a{opacity:1}${p}.b{opacity:0}${p}.f{opacity:0}${p}.f-${faces[0] ?? "neutral"}{opacity:1}}`,
  );
  return { css: css.join(""), faces };
}

// The molecule alone. Walking, it alternates its two hops at `step` ms; at rest it bobs
// slowly, IDLE_STEP_MS a hop. Its face follows its mood. No script: CSS animations.
export function mascotSvg(opts: {
  color: string;
  walking: boolean;
  step: number;
  title: string;
  mood?: Mood;
}): string {
  const w = SPRITE_WIDTH * 10;
  const h = SPRITE_HEIGHT * 10;
  const period = (opts.walking ? opts.step : IDLE_STEP_MS) * 2;
  const { css, faces } = moleculeCss(opts.mood ?? (opts.walking ? "working" : "idle"), period);
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" shape-rendering="crispEdges">` +
    `<title>${escapeXml(opts.title)}</title><style>${css}</style>` +
    moleculeHop(0, opts.color, faces, 10, 0) +
    moleculeHop(1, opts.color, faces, 10, 0) +
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

// The running session's subagents, a small molecule each, in a row under the big one,
// at 3 px a pixel, each with its own colour and a <title> (its CO2). They move and pull
// faces like the big one (working or idle, never its sweat), each a little out of step.
export const SUBAGENT_PX = 3;
export function subagentsSvg(
  agents: ReadonlyArray<{ color: string; title: string }>,
  opts: { walking: boolean; step: number },
): string {
  const w = SPRITE_WIDTH * SUBAGENT_PX;
  const h = SPRITE_HEIGHT * SUBAGENT_PX;
  const gap = 6;
  const period = (opts.walking ? opts.step : IDLE_STEP_MS) * 2;
  const { css, faces } = moleculeCss(opts.walking ? "working" : "idle", period);
  const delays: string[] = [];
  const items = agents
    .map((a, i) => {
      const ox = i * (w + gap);
      // Out of step with each other, so they do not move as one
      delays.push(`.m${i} .a,.m${i} .b,.m${i} .f{animation-delay:-${(i * 1170) % 9000}ms}`);
      return (
        `<g class="m${i}"><title>${escapeXml(a.title)}</title>` +
        moleculeHop(0, a.color, faces, SUBAGENT_PX, ox) +
        moleculeHop(1, a.color, faces, SUBAGENT_PX, ox) +
        `</g>`
      );
    })
    .join("");
  const total = Math.max(1, agents.length) * (w + gap) - gap;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${h}" width="${total}" height="${h}" shape-rendering="crispEdges">` +
    `<style>${css}${delays.join("")}</style>${items}</svg>`
  );
}

// The colour scale under the molecule: the eight colours, bluest to reddest, and a marker
// under this session's. No marker while the molecule is grey (no median yet).
export const SCALE_WIDTH = 112;
export const SCALE_HEIGHT = 22;
export function scaleSvg(cls: number | null): string {
  const swatch = SCALE_WIDTH / PALETTE.length;
  const swatches = PALETTE.map(
    (c, i) => `<rect x="${(i * swatch).toFixed(2)}" y="0" width="${swatch.toFixed(2)}" height="8" fill="${c}"/>`,
  ).join("");
  const marker =
    cls === null
      ? ""
      : (() => {
          const x = (Math.min(7, Math.max(0, cls)) + 0.5) * swatch;
          return `<path fill="${OUTLINE}" d="M${x.toFixed(2)} 11l5 8h-10z"/>`;
        })();
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SCALE_WIDTH} ${SCALE_HEIGHT}" width="${SCALE_WIDTH}" height="${SCALE_HEIGHT}" shape-rendering="crispEdges">` +
    `${swatches}${marker}</svg>`
  );
}

export const STRIPES_HEIGHT = 72;
// The hovered stripe's label shows over the stripes' foot: no room kept for it
export const STRIPES_SVG_HEIGHT = STRIPES_HEIGHT;

// A hover label, shared by the stripes and the detail's bars: a dark box with white
// text, readable on a light or a dark pane, centred on `centre` and kept inside `width`
// (half a pixel in, so its outline is not cut). About 6 px a character at 12 px; a text
// too long for the drawing is set smaller, down to 8 px, rather than cut.
export const HOVER_LABEL_HEIGHT = 22;
export function hoverLabelSvg(o: {
  id: string;
  cls: string;
  text: string;
  centre: number;
  y: number;
  width: number;
}): string {
  const natural = o.text.length * 6;
  const size = natural + 14 <= o.width - 1 ? 12 : Math.max(8, (12 * (o.width - 15)) / natural);
  const boxW = Math.min(o.width - 1, (natural * size) / 12 + 14);
  const boxX = Math.max(0.5, Math.min(o.width - 0.5 - boxW, o.centre - boxW / 2));
  return (
    `<g id="${o.id}" class="${o.cls}"><rect x="${boxX.toFixed(2)}" y="${o.y}" width="${boxW.toFixed(2)}" height="${HOVER_LABEL_HEIGHT}" rx="4" fill="#1f2328" stroke="${OUTLINE}" stroke-opacity="0.6"/>` +
    `<text x="${(boxX + 7).toFixed(2)}" y="${o.y + 15}" font-size="${Number(size.toFixed(1))}" font-family="system-ui,-apple-system,sans-serif" fill="#ffffff">${escapeXml(o.text)}</text></g>`
  );
}

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
    .map((s, i) =>
      hoverLabelSvg({ id: `t${i}`, cls: "t", text: s.title, centre: i * sw + sw / 2, y: h - 26, width }),
    )
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
const LETTER_Z = 0x7a; // z
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
    c === "#"
      ? rgb(color)
      : c === "k"
        ? rgb(eyesFor(color))
        : c === "s"
          ? rgb(SWEAT)
          : c === "z"
            ? rgb(ZED)
            : null;
  const words: number[] = [];
  for (let row = 0; row < CELL_ROWS; row++)
    for (let x = 0; x < CELL_COLUMNS; x++) {
      if (frame[row * 2]?.[x] === "g" || frame[row * 2 + 1]?.[x] === "g") {
        words.push(LETTER_Z, rgb(ZED), DEFAULT_COLOR);
        continue;
      }
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
