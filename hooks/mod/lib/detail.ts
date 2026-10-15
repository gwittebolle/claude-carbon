// The pane's "Détail" block: a period's tokens, energy and CO2 by kind of token, with two
// stacked bars (the share of the tokens, the share of the CO2). Pure.
//
// The CO2 of each session is the one the hooks stored; it is split over the four kinds
// with the weights the factors give them (input and cache writes 1, cache reads
// cache_read_factor, output output/input of the session's family), so the parts add up
// to what was stored. A session stored with older factors (a frozen month, or a row
// written before cache reads were recorded) is left out: its stored CO2 no longer matches
// its tokens under today's factors (2.3 to 6.4 times them in May and June 2026), so
// today's weights would misplace it. A session that mixed models sits between 0.5 and
// 2 times the CO2 of its dominant model and splits the same way, as every family weighs
// its kinds alike: it is kept.
// The factors start from energy per token (PUE included) and convert it to CO2 with the
// grid intensity (0.287 kgCO2e/kWh, AWS us-east location-based, data/factors.json
// _methodology). The stored CO2 is divided back by that intensity to show the energy.
import { family } from "./co2.ts";
import { HOVER_LABEL_HEIGHT, hoverLabelSvg } from "./mascot.ts";
import type { Factors } from "./co2.ts";
import type { SessionRow, TokenSplit, Window } from "./sessions.ts";

export const KINDS = ["input", "cacheWrite", "cacheRead", "output"] as const;
export type Kind = (typeof KINDS)[number];

export const GRID_G_PER_WH = 0.287;
// How far a stored CO2 may sit from its tokens under today's factors and still be split
const MIN_RATIO = 0.4;
const MAX_RATIO = 2.5;

export type DetailPart = {
  kind: Kind;
  tokens: number;
  grams: number;
  wh: number;
  tokenShare: number;
  gramShare: number;
};

export type Detail = {
  parts: DetailPart[];
  tokens: number;
  grams: number;
  wh: number;
  // Sessions of the period that carry their tokens, out of all of them
  sessions: number;
  sessionsInPeriod: number;
};

export function weightsOf(model: string, factors: Factors): TokenSplit {
  const f = factors.models[family(model)];
  return {
    input: 1,
    cacheWrite: 1,
    cacheRead: factors.cacheReadFactor,
    output: f.input > 0 ? f.output / f.input : 0,
  };
}

// The period's detail, or null when none of its sessions carries its tokens yet
export function periodDetail(
  rows: readonly SessionRow[],
  w: Window,
  factors: Factors,
): Detail | null {
  const inPeriod = rows.filter((r) => r.at >= w.start && r.at <= w.end);
  const tokens: TokenSplit = { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };
  const grams: TokenSplit = { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };
  let sessions = 0;
  for (const r of inPeriod) {
    if (r.tokens === null) continue;
    const wt = weightsOf(r.model, factors);
    const weighted = KINDS.map((k) => r.tokens![k] * wt[k]);
    const sum = weighted.reduce((s, v) => s + v, 0);
    // The CO2 these tokens make with today's factors, in grams
    const expected = (sum * factors.models[family(r.model)].input) / 1e6;
    if (!(expected > 0)) continue;
    const ratio = r.grams / expected;
    if (ratio < MIN_RATIO || ratio > MAX_RATIO) continue;
    sessions += 1;
    KINDS.forEach((k, i) => {
      tokens[k] += r.tokens![k];
      grams[k] += (r.grams * (weighted[i] ?? 0)) / sum;
    });
  }
  if (sessions === 0) return null;
  const totalTokens = KINDS.reduce((s, k) => s + tokens[k], 0);
  const totalGrams = KINDS.reduce((s, k) => s + grams[k], 0);
  return {
    parts: KINDS.map((kind) => ({
      kind,
      tokens: tokens[kind],
      grams: grams[kind],
      wh: grams[kind] / GRID_G_PER_WH,
      tokenShare: totalTokens > 0 ? tokens[kind] / totalTokens : 0,
      gramShare: totalGrams > 0 ? grams[kind] / totalGrams : 0,
    })),
    tokens: totalTokens,
    grams: totalGrams,
    wh: totalGrams / GRID_G_PER_WH,
    sessions,
    sessionsInPeriod: inPeriod.length,
  };
}

// One colour per kind, in the bars' order, from the author's palette: Amethyst for
// uncached input, sand and Pierre for the cache written and re-read, Tangerine for the
// output, which weighs far more than its share of the tokens. A light and a dark step;
// neighbours stay apart for colour-blind readers on both surfaces, and every part is
// also named with its figures in the text under the bars.
export const DETAIL_COLORS = ["#1b0b45", "#c4b8aa", "#7a6e63", "#f55c0f"] as const;
export const DETAIL_COLORS_DARK = ["#8b7fd6", "#6b6158", "#a89c8e", "#f55c0f"] as const;
const BAR_HEIGHT = 12;
// The bar, then a band under it where the hovered part's label shows, a pixel to spare
const LABEL_TOP = BAR_HEIGHT + 4;
export const DETAIL_SVG_HEIGHT = LABEL_TOP + HOVER_LABEL_HEIGHT + 1;
const GAP = 2;

function colorCss(): string {
  const rule = (colors: readonly string[]) =>
    colors.map((c, i) => `.k${i}{fill:${c}}`).join("");
  return `${rule(DETAIL_COLORS)}@media (prefers-color-scheme: dark){${rule(DETAIL_COLORS_DARK)}}`;
}

// A bar split by `shares` (in the kinds' order) across `width` CSS pixels, 2 px apart.
// As on the stripes: all the parts first, then their labels, hidden, in a layer above;
// hovering part i lights it up and shows label i at once in a dark box under the bar,
// readable on a light or a dark pane. A CSS :hover and the sibling selector, no script,
// no <title> (the app's own tooltip would show a second label late). Parts under half a
// pixel are left out; their figures stay in the text under the bars. `name` prefixes
// the ids and the hover classes, so two bars (and the stripes) never answer each other's
// hover should the app put the drawings in one document; the colour classes are the
// swatches' own, with the same rules.
export function splitBarSvg(
  shares: readonly number[],
  labels: readonly string[],
  width: number,
  name = "bar",
): string {
  const drawn = shares
    .map((s, i) => ({ s, i }))
    .filter(({ s }) => s * width >= 0.5);
  const room = width - GAP * Math.max(0, drawn.length - 1);
  const total = drawn.reduce((t, d) => t + d.s, 0) || 1;
  // A part under a pixel is drawn at one; the others share what is left, so the last
  // part still ends at the bar's right edge
  const thin = drawn.filter(({ s }) => (room * s) / total < 1);
  const thick = total - thin.reduce((t, d) => t + d.s, 0) || 1;
  const left = Math.max(0, room - thin.length);
  let x = 0;
  const parts = drawn.map(({ s, i }) => {
    const wd = (room * s) / total < 1 ? 1 : (left * s) / thick;
    const part = { i, x, wd };
    x += wd + GAP;
    return part;
  });
  const rects = parts
    .map(
      ({ i, x: px, wd }) =>
        `<rect id="${name}-p${i}" class="${name}-b k${i}" x="${px.toFixed(2)}" y="0" width="${wd.toFixed(2)}" height="${BAR_HEIGHT}" rx="2"/>`,
    )
    .join("");
  const boxes = parts
    .map(({ i, x: px, wd }) =>
      hoverLabelSvg({
        id: `${name}-t${i}`,
        cls: `${name}-t`,
        text: labels[i] ?? "",
        centre: px + wd / 2,
        y: LABEL_TOP,
        width,
      }),
    )
    .join("");
  const show = parts.map(({ i }) => `#${name}-p${i}:hover~#${name}-t${i}`).join(",");
  const style =
    `<style>${colorCss()}.${name}-t{opacity:0;pointer-events:none}.${name}-b:hover{opacity:.75}` +
    (parts.length > 0 ? `${show}{opacity:1}` : "") +
    `</style>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${DETAIL_SVG_HEIGHT}" width="${width}" height="${DETAIL_SVG_HEIGHT}">` +
    `${style}${rects}${boxes}</svg>`
  );
}

// The colour key of a kind, a small rounded square
export function swatchSvg(index: number): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="10" height="10">` +
    `<style>${colorCss()}</style><rect class="k${index}" x="0" y="0" width="10" height="10" rx="2"/></svg>`
  );
}
