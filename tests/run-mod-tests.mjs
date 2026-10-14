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
  mascotAlt,
  cardButtonLabel,
  cardDraftBusy,
  cardFillFailed,
  cardReadyText,
  blockLabel,
  compareText,
  costText,
  equivalenceText,
  carValue,
  showLabel,
  noHistoryText,
  otherProjectsLine,
  paneHint,
  paneTitle,
  paneUnplaced,
  rangeLabel,
  stripesAlt,
  stripeTitle,
  changePercent,
  periodHeadline,
  sessionsCount,
  projectBarLine,
  waitingText,
  carTag,
  contextText,
  moreAgentsText,
  subagentsAlt,
  subagentTitle,
  fromLabel,
  toLabel,
  dateInvalid,
  datePlaceholder,
  dayInputValue,
  stripesCaption,
  stripesWaitText,
  apiValueNote,
  AUTHOR_URL,
  builtByLabel,
  METHODOLOGY_URL,
  methodologyLabel,
  scaleAlt,
  forTeamLabel,
  teamUrl,
  blockTitle,
  sessionStatsText,
  changeValue,
  moneyValue,
  tileLabel,
} from "../hooks/mod/lib/format.ts";
import { lineEntry, BIND_WINDOW_MS } from "../hooks/mod/lib/lines.ts";
import {
  CELL_COLUMNS,
  CELL_ROWS,
  classOf,
  colorOf,
  FRAMES,
  MINI_FRAMES,
  faceFrame,
  miniFaceFrame,
  moodOf,
  isStill,
  faceAt,
  MOODS,
  mascotCells,
  mascotSvg,
  scaleSvg,
  mascotWords,
  NEUTRAL,
  PALETTE,
  stepMs,
  stripesSvg,
  subagentsSvg,
} from "../hooks/mod/lib/mascot.ts";
import {
  barMedian,
  bars,
  folderName,
  panelSite,
  historyPath,
  isView,
  dayKey,
  parseDay,
  parseHistory,
  pastSessions,
  periodTotal,
  previousTotal,
  RANGES,
  sessionMedian,
  colourMedian,
  windowOf,
} from "../hooks/mod/lib/sessions.ts";
import { carEquivalence, equivalenceSet } from "../hooks/mod/lib/equiv.ts";

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

const svg = mascotSvg({ color: PALETTE[6], walking: true, step: 172, title: "t" });
check("svg no script", /<script|on[a-z]+=/i.test(svg), false);
check("svg walks", svg.includes("@keyframes") && svg.includes("344ms"), true);
check("svg reduced motion", svg.includes("prefers-reduced-motion"), true);
check("svg at rest breathes slowly", mascotSvg({ color: NEUTRAL, walking: false, step: 300, title: "t" }).includes("2400ms"), true);
check("svg size", svg.length < 131072, true);

// Faces: every one fits both hops, big and small, and changes only the face
const ALL_FACES = ["neutral", "blink", "lookLeft", "lookRight", "lookUp", "wink", "happy", "surprised", "worried", "worriedBlink", "sleep", "doze"];
for (const f of ALL_FACES) {
  for (const hop of [0, 1]) {
    const big = faceFrame(hop, f);
    const mini = miniFaceFrame(hop, f);
    check(`face ${f} hop ${hop}: big size`, big.length === FRAMES[0].length && big.every((r) => r.length === 18), true);
    check(`face ${f} hop ${hop}: small size`, mini.length === CELL_ROWS * 2 && mini.every((r) => r.length === CELL_COLUMNS), true);
    // The body's outline never moves: a face only repaints inside it, or beside it (a drop, a z)
    const bodyOf = (rows) => rows.map((r) => r.replace(/k/g, "#").replace(/[szg]/g, "."));
    check(`face ${f} hop ${hop}: same body`, bodyOf(big).join(), bodyOf(faceFrame(hop, "neutral")).join());
  }
}
check("neutral is the README's face", faceFrame(0, "neutral").join(), FRAMES[0].join());
check("happy smiles", faceFrame(0, "happy").join("\n").split("k").length - 1 > faceFrame(0, "neutral").join("\n").split("k").length - 1, true);
check("worried sweats", faceFrame(0, "worried").join("").includes("s"), true);
check("asleep: a Z of ten pixels", faceFrame(0, "sleep").join("").split("z").length - 1, 10);
// Its diagonal: one pixel on each of the two middle rows, the upper one further right
{
  const rows = faceFrame(0, "sleep").filter((r) => r.includes("z"));
  check("asleep: the Z has a diagonal", rows[1].indexOf("z") > rows[2].indexOf("z") && rows[1].split("z").length === 2, true);
}
{
  const sleepWords = mascotWords(miniFaceFrame(0, "sleep"), PALETTE[3]);
  check("asleep in a terminal: the letter z", sleepWords.filter((w, i) => i % 3 === 0 && w === 0x7a).length, 2);
}
check("asleep: no hop", isStill("asleep") && !isStill("idle"), true);
check("asleep svg: no hop animation", mascotSvg({ color: PALETTE[3], walking: false, step: 300, title: "t", mood: "asleep" }).includes("@keyframes fa"), false);
check("small blink shuts the eyes", miniFaceFrame(0, "blink").join("").includes("k"), false);

// Moods
const mood = (o) => moodOf({ working: false, cls: 3, hasAnswer: true, idleMs: 0, reacting: false, ...o });
check("mood idle", mood({}), "idle");
check("mood waiting", mood({ hasAnswer: false }), "waiting");
check("mood working", mood({ working: true }), "working");
check("mood light work cheerful", mood({ working: true, cls: 1 }), "cheerful");
check("mood heavy work strained", mood({ working: true, cls: 6 }), "strained");
check("mood grey work", mood({ working: true, cls: null }), "working");
check("mood after an answer", mood({ reacting: true }), "pleased");
check("mood after a heavy answer", mood({ reacting: true, cls: 7 }), "phew");
check("mood asleep after 5 min", mood({ idleMs: 5 * 60_000 }), "asleep");
check("mood still awake before", mood({ idleMs: 5 * 60_000 - 1 }), "idle");
check("face at start", faceAt("idle", 0).face, "neutral");
check("face hold", faceAt("idle", 400).holdMs, 2000);
check("face blink", faceAt("idle", 2450).face, "blink");
const idleLoop = MOODS.idle.reduce((sum, [, ms]) => sum + ms, 0);
check("face loops", faceAt("idle", idleLoop + 10).face, "neutral");
check("one-face mood holds", faceAt("pleased", 999_999).face, "happy");
{
  const idleSvg = mascotSvg({ color: PALETTE[3], walking: false, step: 300, title: "t", mood: "idle" });
  check("svg: a layer per face", ["f-neutral", "f-blink", "f-lookLeft", "f-wink", "f-happy"].every((c) => idleSvg.includes(c)), true);
  check("svg: faces loop", idleSvg.includes(`${idleLoop}ms steps(1,end) infinite`), true);
  check("svg: still face under reduced motion", idleSvg.includes(".f-neutral{opacity:1}}"), true);
  const pleasedSvg = mascotSvg({ color: PALETTE[3], walking: false, step: 300, title: "t", mood: "pleased" });
  check("svg: one face, no face animation", pleasedSvg.includes("@keyframes k-"), false);
  const strainedSvg = mascotSvg({ color: PALETTE[7], walking: true, step: 124, title: "t", mood: "strained" });
  check("svg: sweat drawn", strainedSvg.includes("#4f9fd8"), true);
  check("svg: faces keep it small", strainedSvg.length < 131072, true);
}
// The desktop pane draws at most 180 stripes, each with its hover label
const stripesDoc = stripesSvg(
  Array.from({ length: 180 }, (_, i) => ({
    color: i % 9 === 0 ? null : PALETTE[i % 8],
    title: `<${i}> & "x" semaine du 12 oct. · 1 234,5 kgCO₂ · 12 sessions`,
  })),
  "t",
  720,
);
check("stripes svg keeps its shape", stripesDoc.includes('viewBox="0 0 720 72"'), true);
check("stripes hover label shown by CSS", stripesDoc.includes("#b3:hover~#t3"), true);
check("stripes labels drawn above every stripe", stripesDoc.lastIndexOf('class="b"') < stripesDoc.indexOf('class="t"'), true);
check("stripes: no native tooltip", stripesDoc.includes("<title>"), false);
check("stripes svg no script", /<script|on[a-z]+=/i.test(stripesDoc), false);
check("stripes svg size, 180 stripes", stripesDoc.length < 131072, true);
check("stripes svg escapes labels", stripesDoc.includes("&lt;3&gt; &amp; &quot;x&quot;"), true);

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
check("colours against 0.5 kgCO₂ under 10 sessions", colourMedian(parsed), 500);
check("colours against one's own median from 10", colourMedian(ten), 5.5);
check("a first session of 0.5 kgCO₂ is mid-scale", classOf(500, colourMedian([])), classOf(5.5, 5.5));
// Legacy rows: read with their version, kept out of the molecule's median
const mixed = parseHistory("old1\t10\t900\t1\nold2\t20\t700\t1\nold3\t30\t800\t1\nnew\t40\t5\t2\nbare\t50\t6\n");
check("legacy version read", mixed.filter((r) => r.version === 1).length, 3);
check("no version: current", mixed.find((r) => r.id === "bare").version, 2);
// One series: legacy rows count in the median like the others
check("legacy in the session median", sessionMedian([...ten, ...mixed.filter((r) => r.version === 1)]), 7);
check("cost read", parseHistory("a\t10\t5\t2\tsite\t0.4565\n")[0].usd, 0.4565);
check("no cost field", parseHistory("a\t10\t5\t2\tsite\n")[0].usd, null);
check("project read", parseHistory("a\t10\t5\t2\tcarbonara\n")[0].project, "carbonara");
check("no project field", parseHistory("a\t10\t5\t2\n")[0].project, "");
check("folder name", folderName("/Users/g/code/claude-carbon/"), "claude-carbon");
check("folder name Windows", folderName("C:\\Users\\g\\site"), "site");

// Windows and stripes: one stripe per day, week or month across the whole period
const now = new Date(2026, 9, 12, 12).getTime(); // Monday 12 Oct 2026
const day = 86_400_000;
const row = (id, at, grams, extra = {}) => ({ id, at, grams, version: 2, project: "", usd: null, ...extra });
const rows = [
  row("old", now - 400 * day, 1000),
  row("s1", new Date(2026, 8, 30, 10).getTime(), 10), // Wed 30 Sep
  row("s2", new Date(2026, 9, 1, 10).getTime(), 20), // Thu 1 Oct
  row("s3", new Date(2026, 9, 11, 23).getTime(), 40), // Sun 11 Oct
];
{
  const w7 = windowOf({ range: "7d" }, rows, now);
  check("7 days by day", w7.step, "day");
  check("7 days, 7 stripes", bars(rows, w7).length, 7);
  check("7 days start at midnight", new Date(w7.start).getHours(), 0);
  const w30 = windowOf({ range: "30d" }, rows, now);
  const b30 = bars(rows, w30);
  check("30 days, 30 stripes", b30.length, 30);
  check("a younger history starts at its first session", bars(rows.slice(1), windowOf({ range: "30d" }, rows.slice(1), now)).length, 13);
  check("30 days keep the 3 recent sessions", b30.reduce((s, b) => s + b.sessions, 0), 3);
  check("an empty day is 0 g", b30.filter((b) => b.grams === 0).length, 27);
  const w1y = windowOf({ range: "1y" }, rows, now);
  check("weeks start on Monday", new Date(bars(rows, w1y)[0].start).getDay(), 1);
  check("12 months by week", windowOf({ range: "1y" }, rows, now).step, "week");
  const wAll = windowOf({ range: "all" }, rows, now);
  check("400 days of history by week", wAll.step, "week");
  check("over 400 days by month", windowOf({ range: "all" }, [row("older", now - 500 * day, 1), ...rows], now).step, "month");
  check("all starts at the first session's week", wAll.start <= now - 400 * day && now - 400 * day - wAll.start < 7 * day, true);
  check("all keeps every session", bars(rows, wAll).reduce((s, b) => s + b.sessions, 0), 4);
  const wShort = windowOf({ range: "all" }, rows.slice(1), now);
  check("a short history by day", wShort.step, "day");
  const custom = windowOf({ range: "custom", from: "2026-09-01", to: "2026-09-30" }, rows, now);
  check("a custom month by day", custom.step, "day");
  check("a custom month starts on the 1st", new Date(custom.start).getDate(), 1);
  check("a custom month, 30 stripes", bars(rows, custom).length, 30);
  check("a custom month sums its sessions", periodTotal(rows, custom).grams, 10);
  const longCustom = windowOf({ range: "custom", from: "2025-01-01", to: "2026-10-31" }, rows, now);
  check("a custom range over a year by month", longCustom.step, "month");
  check("a custom range ends now at the latest", longCustom.end, now);
  check("day key", dayKey(new Date(2026, 4, 3).getTime()), "2026-05-03");
  check("date day first", parseDay("1/5/2026"), "2026-05-01");
  check("date with dots", parseDay(" 01.05.2026 "), "2026-05-01");
  check("date iso", parseDay("2026-05-01"), "2026-05-01");
  check("not a real date", parseDay("31/02/2026"), null);
  check("not a date", parseDay("mai 2026"), null);
  check("date back in its field", dayInputValue("2026-05-01"), "01/05/2026");
  // A custom range by week counts from its first day, not from that week's Monday
  const byWeek = [row("before", new Date(2026, 3, 28, 10).getTime(), 7), row("in", new Date(2026, 4, 2, 10).getTime(), 5)];
  const weekly = windowOf({ range: "custom", from: "2026-05-01", to: "2026-08-31" }, byWeek, now);
  check("a custom range by week", weekly.step, "week");
  check("a custom range starts on its first day", dayKey(weekly.start), "2026-05-01");
  check("a custom range leaves out the days before it", periodTotal(byWeek, weekly).grams, 5);
  check("its first stripe is the week it starts in", new Date(bars(byWeek, weekly)[0].start).getDay(), 1);
  check("its first stripe holds only its own days", bars(byWeek, weekly)[0].grams, 5);
}
// The same length of time before, for the comparison; none for the whole history
{
  // Oldest first, as the history file reads
  const r = [row("b", now - 10 * day, 20), row("c", now - 9 * day, 10, { usd: 2 }), row("a", now - 2 * day, 30, { usd: 1 })];
  const w = windowOf({ range: "7d" }, r, now);
  const prev = previousTotal(r, w, { range: "7d" });
  check("previous window", prev.grams, 30);
  check("previous cost, priced rows only", prev.usd, 2);
  check("no previous for all", previousTotal(r, windowOf({ range: "all" }, r, now), { range: "all" }), null);
  check("total cost", periodTotal(r, w).usd, 1);
  check("no cost known", periodTotal([row("x", now - day, 5)], w).usd, null);
}
// The car equivalence, the reports' set and row
const factorsDoc = JSON.parse(readFileSync(join(REPO, "data/factors.json"), "utf8"));
check("equivalence set fr", equivalenceSet(["fr_FR.UTF-8"], "fr"), "fr");
check("equivalence set us", equivalenceSet([undefined, "en_US.UTF-8"], "en"), "us");
check("equivalence set world", equivalenceSet(["de_DE.UTF-8"], "en"), "world");
check("equivalence set skips C", equivalenceSet(["C", "fr_FR"], "en"), "fr");
check("equivalence no variable, French", equivalenceSet([undefined], "fr"), "fr");
check("equivalence no variable, English", equivalenceSet([], "en"), "world");
check("car fr divisor", carEquivalence(factorsDoc, "fr")?.divisor, 142);
check("car us unit", carEquivalence(factorsDoc, "us")?.unit, "miles");
check("car unknown set", carEquivalence(factorsDoc, "xx"), null);
check("car no file", carEquivalence(null, "fr"), null);
check("compare up", compareText(150, 100, "30d", "fr").replaceAll(NBSP, " "), "+50 % par rapport aux 30 jours d'avant");
check("compare down en", compareText(80, 100, "1y", "en").replaceAll(NBSP, " "), "-20 % vs the 12 months before");
check("compare custom", compareText(80, 100, "custom", "fr").replaceAll(NBSP, " "), "-20 % par rapport à la période d'avant");
check("compare nothing before", compareText(80, 0, "30d", "fr"), null);
check("compare all", compareText(80, 100, "all", "fr"), null);
check("change percent", changePercent(150, 100), 50);
check("car tile value", carValue(240000, carEquivalence(factorsDoc, "fr"), "fr").replaceAll(NBSP, " "), "≈ 1 690 km");
check("card button names the card's year", cardButtonLabel(2026, "fr"), "Obtenir ma carte 2026");
check("equivalence text", equivalenceText(240000, carEquivalence(factorsDoc, "fr"), "fr").replaceAll(NBSP, " "), "≈ 1 690 km en voiture (142 gCO₂/km, ADEME 2025)");
check("cost grouped", costText(27608.16, "fr").replaceAll(NBSP, " "), "27 608 $ au prix API");
check("cost grouped en", costText(27608.16, "en"), "$27,608 at API prices");
check("cost small", costText(12.3, "fr").replaceAll(NBSP, " "), "12,30 $ au prix API");
const plainText = (s) => s.replaceAll(NBSP, " ");
check("session stats", sessionStatsText(1, 3, "opus", "fr"), "1 réponse · 3 sous-agents · Opus");
check("session stats en", sessionStatsText(2, 1, null, "en"), "2 answers · 1 subagent");
{
  const parsed8 = parseHistory("a\t10\t5\t2\tsite\t0.5\tclaude-opus-5-5\t1234\n")[0];
  check("model read", parsed8.model, "claude-opus-5-5");
}
check("money value", moneyValue(27608.16, "fr").replaceAll(NBSP, " "), "27 608 $");
check("money value en", moneyValue(12.3, "en"), "$12.30");
check("change value", changeValue(-18).replaceAll(NBSP, " "), "-18 %");
check("api value note", apiValueNote("fr").replaceAll(NBSP, " "), "Le prix de cet usage facturé à l'API ; un abonnement Pro ou Max en couvre tout ou partie.");
check("bar median needs 3 full bars", barMedian([{ grams: 1 }, { grams: 0 }, { grams: 3 }]), null);
check("bar median", barMedian([{ grams: 1 }, { grams: 3 }, { grams: 0 }, { grams: 5 }]), 3);
// Where midnight is skipped for summer time (Santiago, Sunday 6 Sep 2026), no session
// is lost and the weeks still reach the current one
{
  const tz = process.env.TZ;
  process.env.TZ = "America/Santiago";
  const sun = new Date(2026, 8, 6, 12).getTime();
  const tue = new Date(2026, 8, 8, 12).getTime();
  const at = new Date(2026, 8, 20, 12).getTime();
  const dst = [row("a", sun, 10), row("b", tue, 20)];
  const w = bars(dst, windowOf({ range: "1y" }, dst, at));
  check("DST weeks keep every session", w.reduce((s, b) => s + b.grams, 0), 30);
  check("DST weeks reach the current week", w.at(-1).start <= at && at - w.at(-1).start < 7 * day, true);
  check("DST week starts at the day's first instant", new Date(w.at(-1).start).getHours(), 0);
  const days = bars(dst, windowOf({ range: "30d" }, dst, at));
  check("DST days keep every session", days.reduce((s, b) => s + b.grams, 0), 30);
  // From the first session (6 Sep) to the day of `at` (20 Sep)
  check("DST days from the first session", days.length, 15);
  if (tz === undefined) delete process.env.TZ;
  else process.env.TZ = tz;
}
// Just after the clocks go forward (Paris, Sunday 29 Mar 2026), 7 days are 7 stripes
{
  const tz = process.env.TZ;
  process.env.TZ = "Europe/Paris";
  const at = new Date(2026, 3, 2, 0, 30).getTime(); // Thursday 2 Apr, 00:30
  const w = windowOf({ range: "7d" }, [row("a", at - 20 * day, 1)], at);
  check("DST: 7 days start 6 days back", dayKey(w.start), "2026-03-27");
  check("DST: 7 days, 7 stripes", bars([], w).length, 7);
  if (tz === undefined) delete process.env.TZ;
  else process.env.TZ = tz;
}
// The period summed, by project, heaviest first
{
  const r = [row("a", now - 2 * day, 30, { project: "x" }), row("b", now - day, 60, { project: "y" }), row("c", now - 400 * day, 999, { project: "z" })];
  const sum = periodTotal(r, windowOf({ range: "30d" }, r, now));
  check("total grams", sum.grams, 90);
  check("total sessions", sum.sessions, 2);
  check("projects heaviest first", sum.projects.map((q) => q.project).join(","), "y,x");
  check("project share", Math.round(sum.projects[0].share * 100), 67);
}
check("view check", isView({ range: "1y" }), true);
check("view check custom", isView({ range: "custom", from: "2026-05-01", to: "2026-10-13" }), true);
check("view check custom backwards", isView({ range: "custom", from: "2026-10-13", to: "2026-05-01" }), false);
check("view check months only", isView({ range: "custom", from: "2026-05", to: "2026-10" }), false);
check("view check 3 months is gone", isView({ range: "90d" }), false);
check("view check custom no months", isView({ range: "custom" }), false);
check("view check refuses", isView({ range: "2d" }), false);

// Pane texts, French and English, under the same rules as the rest of the mod
const pane = [];
for (const lang of ["fr", "en"]) {
  // The tab title is the plugin's name on purpose (asked for), so it is checked apart
  pane.push(commandDescription(lang), paneHint(lang), paneUnplaced(lang));
  pane.push(currentLine(52, 140, lang), currentLine(800, 140, lang), currentLine(52, null, lang));
  pane.push(colorNote(4, lang), noHistoryText(lang), emptyRangeText(lang));
  pane.push(mascotAlt(lang), stripesAlt(lang));
  pane.push(cardButtonLabel(2026, lang), cardDraftBusy(lang), cardReadyText(lang), cardFillFailed(lang));
  pane.push(compareText(120, 100, "30d", lang), compareText(80, 100, "1y", lang), costText(12.3, lang), showLabel(lang));
  pane.push(equivalenceText(240000, carEquivalence(factorsDoc, lang === "fr" ? "fr" : "us"), lang));
  for (const b of ["compare", "cost", "equivalence", "projects"]) pane.push(blockLabel(b, lang));
  pane.push(periodHeadline(84900, lang), sessionsCount(91, lang), projectBarLine("site", 6000, 0.07, lang), projectBarLine("", 50, 0.001, lang));
  pane.push(subagentsAlt(1, lang), subagentsAlt(3, lang), subagentTitle(1, 12, lang), contextText(42, lang), builtByLabel(lang), forTeamLabel(lang), apiValueNote(lang), moneyValue(27608, lang), changeValue(29));
  for (const k of ["period", "change", "sessions", "cost"]) pane.push(tileLabel(k, lang));
  pane.push(sessionStatsText(3, 2, "fable", lang), blockTitle("usage", lang), blockTitle("session", lang));
  pane.push(waitingText(lang), fromLabel(lang), toLabel(lang), datePlaceholder(lang), dateInvalid(lang));
  pane.push(otherProjectsLine(4, 900, 0.01, lang));
  for (const r of RANGES) pane.push(rangeLabel(r, lang));
  for (const s of ["day", "week", "month"]) {
    pane.push(stripesCaption(s, 1234, lang), stripesCaption(s, null, lang));
    pane.push(dateLabel(now, s, lang), dateLabel(now, s, lang, true), stripeTitle(now, s, 1234, 3, lang), stripeTitle(now, s, 0, 0, lang));
  }
}
for (const text of pane) {
  check(`pane text set: ${text}`, typeof text === "string" && text.length > 0, true);
  check(`pane no plugin name: ${text}`, text.includes("claude-carbon"), false);
  check(`pane no em dash: ${text}`, text.includes("\u2014"), false);
  check(`pane no receipt: ${text}`, text.toLowerCase().includes("receipt"), false);
  // Always gCO₂, the car factor's rate included ("142 gCO₂/km")
  check(`pane unit: ${text}`, / g(?!CO₂)\b/.test(text.replaceAll(NBSP, " ")), false);
}
// French puts a no-break space before : ; ! and ?, never a plain one
for (const lang of ["fr"]) {
  const fr = [paneUnplaced(lang), currentLine(52, 140, lang), colorNote(4, lang), stripesWaitText("day", 2, lang), noHistoryText(lang), cardDraftBusy(lang), periodHeadline(900, lang), waitingText(lang), cardReadyText(lang), cardFillFailed(lang), compareText(120, 100, "30d", lang), dateInvalid(lang)];
  for (const text of fr) check(`fr punctuation: ${text}`, / [:;!?]/.test(text), false);
}
check("current line", plainText(currentLine(52, 140, "fr")), "Cette session : 52 gCO₂ · 0,37× votre médiane");
check("current line high", plainText(currentLine(1400, 140, "en")), "This session: 1.4 kgCO₂ · 10× your median");
check("pane title", paneTitle("fr"), "claude-carbon");
// Pages checked live on 2026-10-13: the French site is at the root, /fr is a 404
check("team url fr", teamUrl("fr"), "https://tokenclimate.com/?ref=carbon-panel");
check("team url en", teamUrl("en"), "https://tokenclimate.com/en?ref=carbon-panel");
check("author url", AUTHOR_URL, "https://www.linkedin.com/in/gwittebolle/");
check("built by", plainText(builtByLabel("fr")), "Développé par :");
check("methodology link", METHODOLOGY_URL, "https://github.com/gwittebolle/claude-carbon/blob/main/METHODOLOGY.md");
// The colour scale under the molecule
{
  const scale = scaleSvg(3);
  check("scale: eight colours", (scale.match(/<rect /g) ?? []).length, 8);
  check("scale: bluest to reddest", scale.indexOf(PALETTE[0]) < scale.indexOf(PALETTE[7]), true);
  check("scale: a marker under the session's colour", /<path [^>]*d="M49\.00 11/.test(scale), true);
  check("scale: no marker while grey", scaleSvg(null).includes("<path"), false);
  check("scale: no script", /<script|on[a-z]+=/i.test(scale), false);
  check("scale alt fr", plainText(scaleAlt(5, "fr")), "Échelle des couleurs, du bleu au rouge : cette session est en 6e position sur 8");
  check("scale alt grey", plainText(scaleAlt(null, "en")), "Colour scale, from blue (under your median) to red (over it)");
}
check("methodology label", methodologyLabel("fr"), "Comment c'est calculé");
check("car tag in gCO₂", plainText(carTag("142 g/km, ADEME 2025")), "142 gCO₂/km, ADEME 2025");
check("car tag in miles", plainText(carTag("393 g/mile, EPA US")), "393 gCO₂/mile, EPA US");
check("panel: typed in a terminal, the band", panelSite(["terminal"], "composer"), "band");
check("panel: a terminal session driven from the app, the pane", panelSite(["terminal", "desktop"], "bridge"), "pane");
check("panel: the desktop app's own session, the pane", panelSite(["desktop"], "composer"), "pane");
check("panel: another plugin's run in a terminal, the band", panelSite(["terminal"], "plugin"), "band");
check("context", plainText(contextText(41.6, "fr")), "Contexte 42 %");
{
  const row = subagentsSvg([{ color: PALETTE[2], title: "a" }, { color: PALETTE[7], title: "<b>" }], { walking: true, step: 172 });
  check("subagents: one molecule each", (row.match(/<g class="m\d+">/g) ?? []).length, 2);
  check("subagents: they walk", row.includes("344ms"), true);
  check("subagents: out of step", row.includes(".m1 .a,.m1 .b,.m1 .f{animation-delay:-1170ms}"), true);
  check("subagents: they pull faces", row.includes("f-blink"), true);
  check("subagents: at rest they breathe", subagentsSvg([{ color: NEUTRAL, title: "a" }], { walking: false, step: 172 }).includes("2400ms"), true);
  check("subagents: reduced motion", row.includes("prefers-reduced-motion"), true);
  check("subagents: no script", /<script|on[a-z]+=/i.test(row), false);
  check("subagents: titles escaped", row.includes("&lt;b&gt;"), true);
  check("subagent title", plainText(subagentTitle(2, 12, "fr")), "Sous-agent 2 · 12 gCO₂");
}
check("for a team", plainText(forTeamLabel("fr")), "Découvrez la version entreprise :");
check("car under a unit", plainText(carValue(100, { divisor: 142, unit: "km" }, "fr")), "< 1 km");
check("car from a unit", plainText(carValue(1000, { divisor: 142, unit: "km" }, "fr")), "≈ 7 km");
check("stripes wait by week", plainText(stripesWaitText("week", 1, "en")), "Your colour stripes show after 3 weeks of use (1 so far): one per period, blue to red by its CO₂.");
check("caption", plainText(stripesCaption("week", 1200, "fr")), "une bande par semaine · médiane 1,2 kgCO₂ par semaine");
check("caption en", plainText(stripesCaption("day", null, "en")), "one stripe per day");
check("headline", plainText(periodHeadline(901200, "fr")), "901,2 kgCO₂ sur la période");
check("date with year", plainText(dateLabel(now, "day", "fr", true)), "12 oct. 2026");
check("project bar", plainText(projectBarLine("carbonara", 103500, 0.41, "fr")), "███████ 41 % carbonara · 103,5 kgCO₂");
check("stripe title week", plainText(stripeTitle(now, "week", 1234, 3, "fr")), "semaine du 12 oct. · 1,2 kgCO₂ · 3 sessions");

console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
