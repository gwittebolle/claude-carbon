#!/usr/bin/env node
// run-mod-tests.mjs: checks the pure modules of the claude-carbon mod against the
// plugin's own contract, with no Claude Code API involved.
//   1. CO2 parity: every golden vector (tests/methodology-vectors*.json) replayed
//      through hooks/mod/lib/co2.ts, same 1e-6 relative tolerance as
//      tests/run-vectors.sh, with the CURRENT data/factors.json (the file the mod reads).
//   2. Display rules (hooks/mod/lib/format.ts), French and English.
//   3. Which turn a duration line belongs to (hooks/mod/lib/lines.ts).
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
  buildAnswerCo2,
  detectLang,
  formatGrams,
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
} from "../hooks/mod/lib/format.ts";
import { lineEntry, BIND_WINDOW_MS } from "../hooks/mod/lib/lines.ts";

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

// ── 1. CO2 parity ────────────────────────────────────────────────────────────
const factorsRaw = readFileSync(join(REPO, "data/factors.json"), "utf8");
const factors = parseFactors(JSON.parse(factorsRaw));

for (const file of [
  "tests/methodology-vectors.json",
  "tests/methodology-vectors-per-model.json",
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
  }
}

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

const sessionCases = [
  ["session line", [212.3, "fr"], "212 gCO₂ cette session"],
  ["session line en", [212.3, "en"], "212 gCO₂ this session"],
  [
    "session line, last answer",
    [14, "fr", 1.04],
    "14 gCO₂ cette session · dernière réponse 1,0 gCO₂",
  ],
  [
    "session line, last answer en",
    [14, "en", 1.04],
    "14 gCO₂ this session · last answer 1.0 gCO₂",
  ],
  [
    "session line, tiny last answer",
    [3.2, "fr", 0.03],
    "3,2 gCO₂ cette session · dernière réponse < 0,1 gCO₂",
  ],
  [
    "session line over 1 kg",
    [1234, "fr", 6.4],
    "1,2 kgCO₂ cette session · dernière réponse 6,4 gCO₂",
  ],
  ["session line, uncounted last answer", [14, "fr", 0], "14 gCO₂ cette session"],
  ["session line, no last answer", [14, "fr", null], "14 gCO₂ cette session"],
];
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
  shown.push(sessionLine(52, lang, 38), sessionLine(52, lang));
  for (const n of [0.02, 4.24, 37.6, 1234]) shown.push(formatGrams(n, lang));
}
for (const text of shown) {
  check(`no plugin name: ${text}`, text.includes("claude-carbon"), false);
  check(`no em dash: ${text}`, text.includes("\u2014"), false);
  check(`no receipt: ${text}`, text.toLowerCase().includes("receipt"), false);
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

console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
