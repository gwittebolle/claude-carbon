#!/usr/bin/env node
// run-mod-tests.mjs: checks the pure modules of the claude-carbon mod against the
// plugin's own contract, with no Claude Code API involved.
//   1. CO2 and cost parity: every golden vector (tests/methodology-vectors*.json)
//      replayed through hooks/mod/lib/co2.ts and hooks/mod/lib/cost.ts, same 1e-6
//      relative tolerance as tests/run-vectors.sh, with the CURRENT data/factors.json
//      and data/prices.json (the files the mod reads).
//   2. Display rules (hooks/mod/lib/format.ts), French and English.
//   3. Which turn a duration line belongs to (hooks/mod/lib/lines.ts).
//   4. The /carbon-panel pane: the mascot's frames, colours and terminal cells
//      (hooks/mod/lib/mascot.ts), the session history (hooks/mod/lib/sessions.ts)
//      and the pane's texts.
// Runs on Node 22.6+ with --experimental-strip-types (default from Node 23.6).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  co2Grams,
  isExcluded,
  parseFactors,
  family,
} from "../hooks/mod/lib/co2.ts";
import {
  costUsd,
  modelPrices,
  parsePrices,
  priceOverride,
} from "../hooks/mod/lib/cost.ts";
import {
  buildAnswerCo2,
  detectLang,
  formatGrams,
  formatUsd,
  hasLangVariable,
  isCarbonStatusLine,
  isUnusual,
  languageSetting,
  median,
  percentile,
  pushHistory,
  sessionLine,
  answerLine,
  welcomeText,
  HISTORY_SIZE,
  MIN_HISTORY,
  colorNote,
  commandDescription,
  currentLine,
  dateLabel,
  emptyRangeText,
  historyLine,
  mascotAlt,
  methodSwitchNote,
  methodSwitchText,
  noHistoryText,
  paneHint,
  paneTitle,
  paneUnplaced,
  rangeLabel,
  stepLabel,
  stripesAlt,
  stripeTitle,
  uncolouredText,
} from "../hooks/mod/lib/format.ts";
import { lineEntry, BIND_WINDOW_MS } from "../hooks/mod/lib/lines.ts";
import {
  CELL_COLUMNS,
  CELL_ROWS,
  classOf,
  colorOf,
  FRAMES,
  MINI_FRAMES,
  mascotCells,
  mascotSvg,
  mascotWords,
  NEUTRAL,
  PALETTE,
  stepMs,
  stripeColumns,
  stripesSvg,
  stripeWords,
} from "../hooks/mod/lib/mascot.ts";
import {
  barMedian,
  bars,
  historyPath,
  isView,
  legacyMedian,
  parseHistory,
  pastSessions,
  RANGES,
  sessionMedian,
  STEPS,
} from "../hooks/mod/lib/sessions.ts";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const NBSP = " ";
const REL_TOL = 1e-6;

let failures = 0;
let checks = 0;

function check(name, actual, expected) {
  checks += 1;
  if (actual !== expected) {
    failures += 1;
    console.log(
      `FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`,
    );
  }
}

function close(name, actual, expected) {
  checks += 1;
  const ok =
    expected === 0
      ? Math.abs(actual) <= REL_TOL
      : Math.abs(actual - expected) / Math.abs(expected) <= REL_TOL;
  if (!ok) {
    failures += 1;
    console.log(`FAIL ${name}\n  expected: ${expected}\n  actual:   ${actual}`);
  }
}

// ── 1. CO2 and cost parity ───────────────────────────────────────────────────
const factorsRaw = readFileSync(join(REPO, "data/factors.json"), "utf8");
const factors = parseFactors(JSON.parse(factorsRaw));
const pricesRaw = JSON.parse(
  readFileSync(join(REPO, "data/prices.json"), "utf8"),
);
const prices = parsePrices(pricesRaw);
// The family vectors pin the family prices: replayed without model_overrides, as
// tests/run-vectors.sh does.
const familyPrices = parsePrices({ ...pricesRaw, model_overrides: undefined });

for (const [file, vectorPrices] of [
  ["tests/methodology-vectors.json", familyPrices],
  ["tests/methodology-vectors-per-model.json", prices],
]) {
  const { vectors } = JSON.parse(readFileSync(join(REPO, file), "utf8"));
  for (const v of vectors) {
    const usage = {
      input_tokens: v.input_tokens,
      cache_creation_input_tokens: v.cache_creation_tokens,
      cache_read_input_tokens: v.cache_read_tokens,
      output_tokens: v.output_tokens,
    };
    const excluded = isExcluded(v.model, factors.excludeModels);
    if (v.expected_co2_grams === null) {
      // A model left out of accounting carries no expected value: it must be excluded.
      check(`${file} ${v.id} excluded`, excluded, true);
      continue;
    }
    check(`${file} ${v.id} counted`, excluded, false);
    close(
      `${file} ${v.id}`,
      co2Grams(usage, v.model, factors),
      v.expected_co2_grams,
    );
    // The vector's own split of the cache writes, 5-minute tier when it gives none,
    // as tests/run-vectors.sh replays it.
    close(
      `${file} ${v.id} cost`,
      costUsd(usage, v.model, vectorPrices, v.cache_creation_1h_tokens ?? 0),
      v.expected_cost_usd,
    );
  }
}

// The mod sees no split: every cache write at the 1-hour tier, Claude Code's.
const writes = {
  input_tokens: 1000,
  cache_creation_input_tokens: 20000,
  cache_read_input_tokens: 100000,
  output_tokens: 500,
};
check(
  "cost: writes at the 1-hour tier by default",
  costUsd(writes, "claude-opus-5-5", prices),
  costUsd(writes, "claude-opus-5-5", prices, 20000),
);
// Opus 5.5 at 4/20, writes at 2x, reads at 0.05x: 4 000 + 160 000 + 20 000 + 10 000
close(
  "cost: Opus 5.5 request",
  costUsd(writes, "claude-opus-5-5", prices),
  0.194,
);
// The 1-hour part never goes above the total write
close(
  "cost: 1-hour part clamped",
  costUsd(writes, "claude-opus-5-5", prices, 99999),
  0.194,
);
// Same writes at the 5-minute tier, 1.25x: 4 000 + 100 000 + 20 000 + 10 000
close(
  "cost: 5-minute tier",
  costUsd(writes, "claude-opus-5-5", prices, 0),
  0.134,
);

// Model resolution, the same as cc_override / cc_params in scripts/portable-lib.sh
// (each value below is what cc_model_params prints for the id).
const resolved = (model) => {
  const p = modelPrices(model, prices);
  return [p.input, p.output, p.cacheWriteMultiplier, p.cacheWriteMultiplier1h, p.cacheReadMultiplier].join(" ");
};
for (const [model, expected] of [
  ["claude-opus-5-5", "4 20 1.25 2 0.05"],
  ["claude-opus-5-5-20260922", "4 20 1.25 2 0.05"],
  ["claude-opus-5-5[1m]", "4 20 1.25 2 0.05"],
  ["CLAUDE-OPUS-5-5", "4 20 1.25 2 0.05"],
  ["claude-opus-5-50", "4 20 1.25 2 0.1"],
  ["claude-opus-5-5-preview", "4 20 1.25 2 0.1"],
  ["claude-opus-5", "5 25 1.25 2 0.1"],
  ["claude-opus-4-1", "4 20 1.25 2 0.1"],
  ["claude-sonnet-4-6", "3 15 1.25 2 0.1"],
  ["claude-sonnet-5", "2 10 1.25 2 0.1"],
  ["claude-sonnet-5-5", "2 10 1.25 2 0.05"],
  ["claude-haiku-5-5", "0.1 0.5 1.25 2 0.1"],
  ["claude-haiku-4-5-20251001", "1 5 1.25 2 0.1"],
  ["claude-fable-5-1", "10 50 1.25 2 0.025"],
  ["claude-mythos-5", "10 50 1.25 2 0.1"],
]) {
  check(`prices ${model}`, resolved(model), expected);
}
check(
  "prices: longest key wins",
  priceOverride("claude-x-1-20260101", [
    ["claude-x", { input: 1 }],
    ["claude-x-1", { input: 2 }],
  ]).input,
  2,
);
check("prices: not an object", parsePrices([]), null);
check("prices: fallback family", parsePrices({}).models.opus.output, 20);
check("prices: fallback multiplier", parsePrices({}).cacheWriteMultiplier1h, 2);
check(
  "prices: an override leaves the rest to the family",
  modelPrices("claude-a-1", parsePrices({ model_overrides: { "claude-a-1": { output: 7 } } })).input,
  2,
);
check(
  "prices: keys starting with _ are notes",
  parsePrices({ model_overrides: { _note: {} } }).overrides.length,
  0,
);

check("family haiku", family("claude-3-5-haiku-20241022"), "haiku");
check("family opus", family("claude-opus-5-5"), "opus");
check("family fable", family("claude-fable-5-1"), "fable");
check("family mythos", family("claude-mythos-5"), "fable");
check("family default sonnet", family("claude-sonnet-5-5"), "sonnet");
check("excluded non-claude", isExcluded("glm-4.7-flash", []), true);
check("excluded synthetic", isExcluded("<synthetic>", []), true);
check("excluded by pattern", isExcluded("claude-haiku-4", ["HAIKU"]), true);
check("not excluded", isExcluded("claude-opus-5-5", ["haiku"]), false);
check("bad pattern ignored", isExcluded("claude-opus-5-5", ["("]), false);
check("fallback factors", parseFactors({}).models.opus.output, 1652);
check(
  "fallback cache read",
  parseFactors({ models: {} }).cacheReadFactor,
  0.08,
);

// ── 2. Display rules ─────────────────────────────────────────────────────────
const g = (n, lang = "fr") => formatGrams(n, lang).replaceAll(NBSP, " ");

check("0 g", g(0), "< 0,1 gCO₂");
check("0.04 g", g(0.04), "< 0,1 gCO₂");
check("0.1 g", g(0.1), "0,1 gCO₂");
check("4.24 g", g(4.24), "4,2 gCO₂");
check("9.94 g", g(9.94), "9,9 gCO₂");
check("9.96 g rounds into whole grams", g(9.96), "10 gCO₂");
check("37.6 g", g(37.6), "38 gCO₂");
check("999.4 g", g(999.4), "999 gCO₂");
check("999.6 g rounds into kg", g(999.6), "1,0 kgCO₂");
check("1234 g", g(1234), "1,2 kgCO₂");
check("english decimal point", g(4.24, "en"), "4.2 gCO₂");
check("english < 0.1", g(0.02, "en"), "< 0.1 gCO₂");
check("nbsp before unit", formatGrams(38, "fr") === `38${NBSP}gCO₂`, true);
check(
  "nbsp after <",
  formatGrams(0.02, "fr") === `<${NBSP}0,1${NBSP}gCO₂`,
  true,
);

check("median odd", median([5, 1, 3]), 3);
check("median even", median([4, 1, 3, 2]), 2.5);
check("median empty", median([]), 0);

check("percentile median", percentile([4, 1, 3, 2], 0.5), 2.5);
check("percentile min", percentile([4, 1, 3, 2], 0), 1);
check("percentile max", percentile([4, 1, 3, 2], 1), 4);
check(
  "percentile interpolates",
  percentile([10, 20], 0.97),
  10 + 10 * 0.97,
);
check(
  "percentile p97 of 1..101",
  percentile(
    Array.from({ length: 101 }, (_, i) => i + 1),
    0.97,
  ),
  98,
);
check("percentile one value", percentile([7], 0.97), 7);
check("percentile empty", percentile([], 0.97), 0);

check("unusual needs 50 answers", MIN_HISTORY, 50);
const flat = (n, grams) => Array.from({ length: n }, () => grams);
const fortyNine = flat(49, 9);
const fifty = flat(50, 9);
check("49 turns of history: never unusual", isUnusual(1000, fortyNine), false);
check("38 g against a flat 9 g history: unusual", isUnusual(38, fifty), true);
check("27 g against a flat 9 g history: not above 3x", isUnusual(27, fifty), false);
check("floor: 1 g against 0.3 g", isUnusual(1, flat(50, 0.3)), false);
// A history shaped like real use: median 16 g, a few answers far above it.
const realistic = [...flat(60, 16), ...flat(34, 40), ...flat(6, 200)];
check("realistic median", median(realistic), 16);
check("realistic p97", percentile(realistic, 0.97), 200);
check(
  "150 g: 9x the median, under the 97th percentile",
  isUnusual(150, realistic),
  false,
);
check("230 g: above the 97th percentile", isUnusual(230, realistic), true);
check(
  "230 g against the realistic history",
  buildAnswerCo2(
    { grams: 230, subagentGrams: 0, subagents: 0 },
    realistic,
    "fr",
  ).main.replaceAll(NBSP, " "),
  "230 gCO₂ · 14× votre médiane",
);

const ordinary = buildAnswerCo2(
  { grams: 4.24, subagentGrams: 0, subagents: 0 },
  fifty,
  "fr",
);
check("ordinary answer", ordinary.main.replaceAll(NBSP, " "), "4,2 gCO₂");
check("ordinary answer not unusual", ordinary.isUnusual, false);

const unusual = buildAnswerCo2(
  { grams: 38, subagentGrams: 22, subagents: 3 },
  fifty,
  "fr",
);
check(
  "unusual main",
  unusual.main.replaceAll(NBSP, " "),
  "38 gCO₂ · 4× votre médiane",
);
check(
  "unusual sub",
  unusual.sub?.replaceAll(NBSP, " "),
  "dont 3 sous-agents : 22 gCO₂",
);
check(
  "answer line",
  answerLine(unusual).replaceAll(NBSP, " "),
  "38 gCO₂ · 4× votre médiane · dont 3 sous-agents : 22 gCO₂",
);

const oneAgent = buildAnswerCo2(
  { grams: 38, subagentGrams: 10, subagents: 1 },
  fifty,
  "fr",
);
check(
  "singular subagent",
  oneAgent.sub?.replaceAll(NBSP, " "),
  "dont 1 sous-agent : 10 gCO₂",
);

const smallShare = buildAnswerCo2(
  { grams: 38, subagentGrams: 1.9, subagents: 2 },
  fifty,
  "fr",
);
check("subagents under 10 %: no sub line", smallShare.sub, null);

const english = buildAnswerCo2(
  { grams: 38, subagentGrams: 22, subagents: 3 },
  fifty,
  "en",
);
check(
  "english unusual",
  english.main.replaceAll(NBSP, " "),
  "38 gCO₂ · 4× your median",
);
check(
  "english sub",
  english.sub?.replaceAll(NBSP, " "),
  "incl. 3 subagents: 22 gCO₂",
);

const u = (n, lang = "fr") => formatUsd(n, lang).replaceAll(NBSP, " ");
check("$0.12", u(0.1234), "0,12 $");
check("$0.12 en", u(0.1234, "en"), "$0.12");
check("$0.125 rounds up", u(0.126), "0,13 $");
check("$12.5", u(12.5), "12,50 $");
check("$0.01", u(0.01), "0,01 $");
check("under a cent", u(0.004), "< 0,01 $");
check("under a cent en", u(0.004, "en"), "< $0.01");
check("nbsp before $", formatUsd(0.12, "fr") === `0,12${NBSP}$`, true);
check("nbsp after < en", formatUsd(0.001, "en") === `<${NBSP}$0.01`, true);

const sessionCases = [
  ["session line", [3.6, "fr", 0.1234], "Cette session : 3,6 gCO₂ · 0,12 $"],
  ["session line en", [3.6, "en", 0.1234], "This session: 3.6 gCO₂ · $0.12"],
  ["session line, under a cent", [0.4, "fr", 0.003], "Cette session : 0,4 gCO₂ · < 0,01 $"],
  ["session line, under a cent en", [0.4, "en", 0.003], "This session: 0.4 gCO₂ · < $0.01"],
  ["session line over 1 kg", [1234, "fr", 52.4], "Cette session : 1,2 kgCO₂ · 52,40 $"],
  ["session line, no cost", [212.3, "fr", null], "Cette session : 212 gCO₂"],
  ["session line, no cost en", [212.3, "en"], "This session: 212 gCO₂"],
  ["session line, zero cost dropped", [14, "fr", 0], "Cette session : 14 gCO₂"],
];
check(
  "nbsp before the French colon",
  sessionLine(14, "fr").startsWith(`Cette session${NBSP}:`),
  true,
);
const shown = [];
for (const [name, args, expected] of sessionCases) {
  const line = sessionLine(...args);
  shown.push(line);
  check(name, line.replaceAll(NBSP, " "), expected);
}

// Every string the mod puts on screen: never the plugin's name (the surface adds
// it), never an em dash, never the word the mod is not.
for (const lang of ["fr", "en"]) {
  const view = buildAnswerCo2(
    { grams: 38, subagentGrams: 22, subagents: 3 },
    fifty,
    lang,
  );
  shown.push(view.main, view.sub, answerLine(view));
  shown.push(welcomeText(lang));
  shown.push(sessionLine(52, lang, 0.38), sessionLine(52, lang));
  shown.push(formatUsd(0.12, lang), formatUsd(0.001, lang));
  for (const n of [0.02, 4.24, 37.6, 1234]) shown.push(formatGrams(n, lang));
}
for (const text of shown) {
  check(`no plugin name: ${text}`, text.includes("claude-carbon"), false);
  check(`no em dash: ${text}`, text.includes("\u2014"), false);
  check(`no receipt: ${text}`, text.toLowerCase().includes("receipt"), false);
  check(
    `no last answer: ${text}`,
    /dernière réponse|last answer/i.test(text),
    false,
  );
}

check(
  "welcome",
  welcomeText("fr"),
  "Le CO₂ s'affiche maintenant pour chaque réponse.",
);
check("welcome en", welcomeText("en"), "CO₂ now shows for each answer.");

check("lang fr_FR", detectLang(["fr_FR.UTF-8"]), "fr");
check("lang en_US", detectLang(["en_US.UTF-8"]), "en");
check(
  "lang skips C and POSIX",
  detectLang(["C", "POSIX.UTF-8", "en_GB.UTF-8"]),
  "en",
);
check(
  "lang CLAUDE_CARBON_LOCALE first",
  detectLang(["fr", "en_US.UTF-8"]),
  "fr",
);
check("lang empty: setting", detectLang([undefined, ""], "en-US"), "en");
check("lang nothing: French", detectLang([undefined]), "fr");
check("lang variable set", hasLangVariable([undefined, "en_US.UTF-8"]), true);
check("lang only C and empty", hasLangVariable(["", "C.UTF-8", undefined]), false);
// The language setting, free text, read as a locale
for (const [setting, expected] of [
  ["Français", "fr"],
  ["French", "fr"],
  ["french", "fr"],
  ["fr", "fr"],
  ["English", "en"],
  ["Anglais", "en"],
  ["anglais", "en"],
  ["Deutsch", "en"],
]) {
  check(
    `lang setting ${setting}`,
    detectLang([undefined], languageSetting(setting)),
    expected,
  );
}
check("lang setting blank", languageSetting("  "), undefined);
check("lang setting not text", languageSetting(3), undefined);

const full = Array.from({ length: HISTORY_SIZE }, (_, i) => i + 1);
check("history capped", pushHistory(full, 7).length, HISTORY_SIZE);
check("history keeps newest", pushHistory(full, 7).at(-1), 7);
check("history ignores zero", pushHistory([1], 0).length, 1);

check(
  "status line detection",
  isCarbonStatusLine("~/code/claude-carbon/scripts/statusline.sh"),
  true,
);
check(
  "status line detection, other tool",
  isCarbonStatusLine("npx ccusage statusline"),
  false,
);
check("status line detection, missing", isCarbonStatusLine(undefined), false);

// ── 3. Duration lines ────────────────────────────────────────────────────────

const T0 = 1_000_000;
const lineEntries = [
  { turnId: "t1", durationMs: 38000, at: T0 },
  { turnId: "t2", durationMs: 38000, at: T0 + 60000 },
];
const noLines = { turnOf: new Map(), taken: new Set() };
const turnOfLine = (match) => match?.entry.turnId;

check(
  "line first drawn as its turn ends",
  turnOfLine(lineEntry(lineEntries, "b", T0 + 60012, noLines)),
  "t2",
);
check(
  "line first drawn as its turn ends, is new",
  lineEntry(lineEntries, "b", T0 + 60012, noLines)?.isNew,
  true,
);
check(
  "line first drawn just before its entry",
  turnOfLine(lineEntry(lineEntries, "b", T0 + 59990, noLines)),
  "t2",
);
check(
  "line first drawn a second later",
  lineEntry(lineEntries, "b", T0 + 60000 + BIND_WINDOW_MS, noLines),
  undefined,
);
check(
  "bound line keeps its turn, same duration",
  turnOfLine(
    lineEntry(lineEntries, "a", T0 + 60012, {
      turnOf: new Map([["a", "t1"]]),
      taken: new Set(["t1"]),
    }),
  ),
  "t1",
);
check(
  "bound line is not new",
  lineEntry(lineEntries, "a", T0, {
    turnOf: new Map([["a", "t1"]]),
    taken: new Set(["t1"]),
  })?.isNew,
  false,
);
check(
  "bound line whose entry is gone",
  lineEntry(lineEntries, "z", T0 + 60012, {
    turnOf: new Map([["z", "t0"]]),
    taken: new Set(["t0"]),
  }),
  undefined,
);
check(
  "taken entry goes to no second line",
  lineEntry(lineEntries, "c", T0 + 60200, {
    turnOf: new Map([["b", "t2"]]),
    taken: new Set(["t2"]),
  }),
  undefined,
);
check(
  "entry of the earlier format",
  lineEntry([{ durationMs: 38000, co2: null }], "a", T0, noLines),
  undefined,
);

// ── 4. The /carbon-panel pane: mascot, stripes, history (lib/mascot.ts, lib/sessions.ts) ──

check("class at the median", classOf(100, 100), 4);
check("class just under the median", classOf(99, 100), 3);
check("class 2x", classOf(200, 100), 5);
check("class floor", classOf(1, 100), 0);
check("class ceiling", classOf(100000, 100), 7);
check("class with no median", classOf(50, 0), 0);
check("step bluest", stepMs(0), 460);
check("step reddest", stepMs(7), 124);
check("palette bluest", colorOf(0), "#08306b");
check("palette reddest", colorOf(7), "#67000d");
check("no class: grey", colorOf(null), NEUTRAL);
check("frames same height", FRAMES[0].length, FRAMES[1].length);
check("frames same width", FRAMES.every((f) => f.every((r) => r.length === 18)), true);

// The README banner draws the same frames and palette
const banner = readFileSync(join(REPO, "docs/mascot-stripes.svg"), "utf8");
for (const c of PALETTE) check(`banner has ${c}`, banner.includes(c), true);

// Half blocks: 20 x 7 cells, three words each, decodable, never the default colour as
// the foreground of a drawn half
const words = mascotWords(MINI_FRAMES[0], PALETTE[5]);
check("cells count", words.length, CELL_COLUMNS * CELL_ROWS * 3);
let badHalf = 0;
for (let i = 0; i < words.length; i += 3) {
  const [glyph, fg] = [words[i], words[i + 1]];
  if ((glyph === 0x2580 || glyph === 0x2584) && fg === 0x01000000) badHalf += 1;
  if (![0x2580, 0x2584, 0x20].includes(glyph)) badHalf += 1;
}
check("half blocks well formed", badHalf, 0);
const decoded = Buffer.from(mascotCells(MINI_FRAMES[1], PALETTE[2]), "base64");
check("cells decode to the right size", decoded.length, CELL_COLUMNS * CELL_ROWS * 12);
check("cells little-endian", decoded.readUInt32LE(0), mascotWords(MINI_FRAMES[1], PALETTE[2])[0]);
check("mini frames same size", MINI_FRAMES.every((f) => f.length === CELL_ROWS * 2 && f.every((r) => r.length === CELL_COLUMNS)), true);
// The hop is one pixel: frame B is frame A one pixel up, legs aside
check("mini hop one pixel", MINI_FRAMES[0][2], MINI_FRAMES[1][1]);
check("big hop one pixel", FRAMES[0][2], FRAMES[1][1]);
check("stripe cells", stripeWords([{ color: "#ff0000", title: "" }, { color: null, title: "" }], 2).length, 12);
const withDivider = [
  { color: "#ff0000", title: "" },
  { color: null, title: "x", divider: true },
  { color: "#00ff00", title: "" },
];
check("divider takes one column", stripeColumns(withDivider, 3), 7);
check("divider cells", stripeWords(withDivider, 1, 3).length, 21);
check("divider glyph", stripeWords(withDivider, 1, 3)[9], 0x2503);
check("divider in the svg", stripesSvg(withDivider, "t").includes('width="2"'), true);

const svg = mascotSvg({ color: PALETTE[6], walking: true, step: 172, title: "t" });
check("svg no script", /<script|on[a-z]+=/i.test(svg), false);
check("svg walks", svg.includes("@keyframes") && svg.includes("344ms"), true);
check("svg reduced motion", svg.includes("prefers-reduced-motion"), true);
check("svg standing", mascotSvg({ color: NEUTRAL, walking: false, step: 300, title: "t" }).includes("@keyframes"), false);
check("svg size", svg.length < 131072, true);
const stripesDoc = stripesSvg(
  Array.from({ length: 400 }, (_, i) => ({ color: PALETTE[i % 8], title: `<${i}> & "x"` })),
  "t",
);
check("stripes svg size, 400 stripes", stripesDoc.length < 131072, true);
check("stripes svg escapes titles", stripesDoc.includes("&lt;3&gt; &amp; &quot;x&quot;"), true);

// The history file
check(
  "path from CLAUDE_CARBON_DB",
  historyPath({ db: "/data/cc/carbon.db", home: "/h" }),
  "/data/cc/sessions-history.tsv",
);
check(
  "path from a Windows CLAUDE_CARBON_DB",
  historyPath({ db: "C:\\Users\\g\\carbon.db" }),
  "C:\\Users\\g/sessions-history.tsv",
);
check("path from CLAUDE_CONFIG_DIR", historyPath({ configDir: "/cfg", home: "/h" }), "/cfg/claude-carbon/sessions-history.tsv");
check("path from HOME", historyPath({ home: "/h" }), "/h/.claude/claude-carbon/sessions-history.tsv");
check("path from USERPROFILE", historyPath({ userProfile: "C:\\Users\\g" }), "C:\\Users\\g/.claude/claude-carbon/sessions-history.tsv");
check("path empty values skipped", historyPath({ db: "", configDir: "", home: "/h" }), "/h/.claude/claude-carbon/sessions-history.tsv");
check("no path", historyPath({}), null);
check("path at the root", historyPath({ db: "/carbon.db" }), "/sessions-history.tsv");
check(
  "path from a Git Bash CLAUDE_CARBON_DB on Windows",
  historyPath({ db: "/c/Users/g/data/carbon.db", userProfile: "C:\\Users\\g" }),
  "C:/Users/g/data/sessions-history.tsv",
);
check(
  "a POSIX path that looks like a drive stays as it is",
  historyPath({ db: "/c/data/carbon.db", home: "/home/g" }),
  "/c/data/sessions-history.tsv",
);

const parsed = parseHistory("a\t100\t5.5\r\nbroken line\nb\tx\t3\nc\t200\t0\nd\t50\t2\n\n");
check("history parse keeps valid rows", parsed.map((r) => r.id).join(","), "d,a");
check("history parse ms", parsed[1].at, 100000);
check("history empty", parseHistory("").length, 0);
check("past sessions drop the current", pastSessions(parsed, "a").map((r) => r.id).join(","), "d");
check("no median under 10 sessions", sessionMedian(parsed), null);
const ten = Array.from({ length: 10 }, (_, i) => ({ id: `${i}`, at: i, grams: i + 1, version: 2 }));
check("median from 10 sessions", sessionMedian(ten), 5.5);
// Legacy rows: read with their version, kept out of the molecule's median
const mixed = parseHistory("old1\t10\t900\t1\nold2\t20\t700\t1\nold3\t30\t800\t1\nnew\t40\t5\t2\nbare\t50\t6\n");
check("legacy version read", mixed.filter((r) => r.version === 1).length, 3);
check("no version: current", mixed.find((r) => r.id === "bare").version, 2);
check("legacy out of the session median", sessionMedian([...ten, ...mixed.filter((r) => r.version === 1)]), 5.5);
check("legacy median", legacyMedian(mixed), 800);
check("legacy median needs 3", legacyMedian(mixed.slice(0, 2)), null);

// Stripes by session, week and month, local time
const now = new Date(2026, 9, 12, 12).getTime(); // Monday 12 Oct 2026
const day = 86_400_000;
const rows = [
  { id: "s1", at: new Date(2026, 8, 30, 10).getTime(), grams: 10 }, // Wed 30 Sep
  { id: "s2", at: new Date(2026, 9, 1, 10).getTime(), grams: 20 }, // Thu 1 Oct
  { id: "s3", at: new Date(2026, 9, 11, 23).getTime(), grams: 40 }, // Sun 11 Oct
  { id: "old", at: now - 400 * day, grams: 1000 },
];
check("sessions in 30 days", bars(rows, { range: "30d", step: "session" }, now).length, 3);
check("sessions in all", bars(rows, { range: "all", step: "session" }, now).length, 4);
const weeks = bars(rows, { range: "30d", step: "week" }, now);
check("weeks: 28 Sep, 5 Oct (empty), 12 Oct (empty)", weeks.map((b) => b.grams).join(","), "30,40,0");
check("week starts on Monday", new Date(weeks[0].start).getDay(), 1);
const months = bars(rows, { range: "90d", step: "month" }, now);
check("months: Sep, Oct", months.map((b) => b.grams).join(","), "10,60");
check("month starts on the 1st", new Date(months[1].start).getDate(), 1);
check("empty range", bars(rows, { range: "7d", step: "week" }, now - 30 * day).length, 0);
// Legacy weeks stop at their last session, not at now
const legacyWeeks = bars(rows.slice(0, 2), { range: "all", step: "week" }, now, rows[1].at);
check("periods end at until", legacyWeeks.length, 1);
check("bar median needs 3 full bars", barMedian(weeks), null);
check("bar median", barMedian([{ grams: 1 }, { grams: 3 }, { grams: 0 }, { grams: 5 }]), 3);
// Whole periods: a 30-day range seen by month starts on the 1st of its first month
const firstMonth = bars(rows, { range: "30d", step: "month" }, now)[0];
check("range starts at a whole month", new Date(firstMonth.start).getDate(), 1);
check("whole first month keeps its sessions", firstMonth.grams, 10);
// Where midnight is skipped for summer time (Santiago, Sunday 6 Sep 2026), no session
// is lost and the weeks still reach the current one
{
  const tz = process.env.TZ;
  process.env.TZ = "America/Santiago";
  const sun = new Date(2026, 8, 6, 12).getTime();
  const tue = new Date(2026, 8, 8, 12).getTime();
  const at = new Date(2026, 8, 20, 12).getTime();
  const w = bars(
    [
      { id: "a", at: sun, grams: 10 },
      { id: "b", at: tue, grams: 20 },
    ],
    { range: "all", step: "week" },
    at,
  );
  check("DST weeks keep every session", w.reduce((s, b) => s + b.grams, 0), 30);
  check("DST weeks reach the current week", w.at(-1).start <= at && at - w.at(-1).start < 7 * day, true);
  check("DST week starts at the day's first instant", new Date(w.at(-1).start).getHours(), 0);
  if (tz === undefined) delete process.env.TZ;
  else process.env.TZ = tz;
}
check("view check", isView({ range: "90d", step: "month" }), true);
check("view check refuses", isView({ range: "2d", step: "month" }), false);

// Pane texts, French and English, under the same rules as the rest of the mod
const pane = [];
for (const lang of ["fr", "en"]) {
  pane.push(paneTitle(lang), commandDescription(lang), paneHint(lang), paneUnplaced(lang));
  pane.push(currentLine(52, 140, lang), currentLine(800, 140, lang), currentLine(52, null, lang));
  pane.push(colorNote(4, lang), noHistoryText(lang), emptyRangeText(lang), uncolouredText(lang));
  pane.push(mascotAlt(lang), stripesAlt(lang));
  pane.push(methodSwitchText(now, lang), methodSwitchNote(lang));
  for (const r of RANGES) pane.push(rangeLabel(r, lang));
  for (const s of STEPS) {
    pane.push(stepLabel(s, lang));
    pane.push(historyLine("90d", s, 12, 12, 140, lang), historyLine("all", s, 200, 60, null, lang));
    pane.push(dateLabel(now, s, lang), stripeTitle(now, s, 1234, 3, lang), stripeTitle(now, s, 0, 0, lang));
  }
}
for (const text of pane) {
  check(`pane text set: ${text}`, typeof text === "string" && text.length > 0, true);
  check(`pane no plugin name: ${text}`, text.includes("claude-carbon"), false);
  check(`pane no em dash: ${text}`, text.includes("\u2014"), false);
  check(`pane no receipt: ${text}`, text.toLowerCase().includes("receipt"), false);
  check(`pane unit: ${text}`, / g(?!CO₂)\b/.test(text.replaceAll(NBSP, " ")), false);
}
// French puts a no-break space before : ; ! and ?, never a plain one
for (const lang of ["fr"]) {
  const fr = [paneUnplaced(lang), currentLine(52, 140, lang), colorNote(4, lang), noHistoryText(lang), methodSwitchText(now, lang)];
  for (const text of fr) check(`fr punctuation: ${text}`, / [:;!?]/.test(text), false);
}
const plainText = (s) => s.replaceAll(NBSP, " ");
check("current line", plainText(currentLine(52, 140, "fr")), "Cette session : 52 gCO₂ · 0,37× votre médiane");
check("current line high", plainText(currentLine(1400, 140, "en")), "This session: 1.4 kgCO₂ · 10× your median");
check("history line", plainText(historyLine("30d", "session", 42, 42, 143, "fr")), "30 derniers jours · 42 sessions · médiane 143 gCO₂");
check("history line truncated", plainText(historyLine("all", "month", 14, 6, 30000, "fr")), "Depuis le début · 6 mois les plus récents sur 14 · médiane 30,0 kgCO₂ par mois");
check("history line weeks en", plainText(historyLine("1y", "week", 52, 52, 1200, "en")), "Last 12 months · 52 weeks · median 1.2 kgCO₂ a week");
check("stripe title week", plainText(stripeTitle(now, "week", 1234, 3, "fr")), "semaine du 12 oct. · 1,2 kgCO₂ · 3 sessions");

console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
