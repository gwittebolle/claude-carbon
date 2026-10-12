#!/usr/bin/env node
// run-mod-tests.mjs: checks the pure modules of the claude-carbon mod against the
// plugin's own contract, with no Claude Code API involved.
//   1. CO2 parity: every golden vector (tests/methodology-vectors*.json) replayed
//      through hooks/mod/lib/co2.ts, same 1e-6 relative tolerance as
//      tests/run-vectors.sh, with the CURRENT data/factors.json (the file the mod reads).
//   2. Display rules (hooks/mod/lib/format.ts), French and English.
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
  isCarbonStatusLine,
  isUnusual,
  median,
  pushHistory,
  sessionLine,
  answerLine,
  welcomeText,
  HISTORY_SIZE,
} from "../hooks/mod/lib/format.ts";

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

const nineteen = Array.from({ length: 19 }, () => 9);
const twenty = Array.from({ length: 20 }, () => 9);
check("19 turns of history: never unusual", isUnusual(1000, nineteen), false);
check("38 g against a 9 g median: unusual", isUnusual(38, twenty), true);
check("27 g against a 9 g median: not above 3x", isUnusual(27, twenty), false);
check(
  "floor: 1 g against 0.3 g",
  isUnusual(
    1,
    Array.from({ length: 20 }, () => 0.3),
  ),
  false,
);

const ordinary = buildAnswerCo2(
  { grams: 4.24, subagentGrams: 0, subagents: 0 },
  twenty,
  "fr",
);
check("ordinary answer", ordinary.main.replaceAll(NBSP, " "), "4,2 gCO₂");
check("ordinary answer not unusual", ordinary.isUnusual, false);

const unusual = buildAnswerCo2(
  { grams: 38, subagentGrams: 22, subagents: 3 },
  twenty,
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
  twenty,
  "fr",
);
check(
  "singular subagent",
  oneAgent.sub?.replaceAll(NBSP, " "),
  "dont 1 sous-agent : 10 gCO₂",
);

const smallShare = buildAnswerCo2(
  { grams: 38, subagentGrams: 1.9, subagents: 2 },
  twenty,
  "fr",
);
check("subagents under 10 %: no sub line", smallShare.sub, null);

const english = buildAnswerCo2(
  { grams: 38, subagentGrams: 22, subagents: 3 },
  twenty,
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
    twenty,
    lang,
  );
  shown.push(view.main, view.sub, answerLine(view), welcomeText(lang));
  shown.push(sessionLine(52, lang, 38), sessionLine(52, lang));
  for (const n of [0.02, 4.24, 37.6, 1234]) shown.push(formatGrams(n, lang));
}
for (const text of shown) {
  check(`no plugin name: ${text}`, text.includes("claude-carbon"), false);
  check(`no em dash: ${text}`, text.includes("\u2014"), false);
  check(`no receipt: ${text}`, text.toLowerCase().includes("receipt"), false);
}

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
check("lang empty: system locale", detectLang([undefined, ""], "en-US"), "en");
check("lang nothing: French", detectLang([undefined]), "fr");

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

console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
