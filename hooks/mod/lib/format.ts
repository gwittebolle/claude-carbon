// What an answer's CO2 line says and when it raises its voice. Pure: no Claude Code API, so
// Node runs it directly (tests/run-mod-tests.mjs).

export type Lang = "fr" | "en";

export type AnswerCo2View = {
  // "4,2 gCO₂", or "38 gCO₂ · 4× votre médiane" for an unusual answer
  main: string;
  // "dont 3 sous-agents : 22 gCO₂", only on an unusual answer the subagents weighed on
  sub: string | null;
  isUnusual: boolean;
};

export type TurnTotals = {
  grams: number;
  subagentGrams: number;
  subagents: number;
};

export const HISTORY_SIZE = 200;
export const MIN_HISTORY = 50;
// About 1 answer in 27 stands out: above the 97th percentile of the history. The 3x
// median and the 10 g floor stay as guards: over a flat history the percentile is
// the median itself.
export const UNUSUAL_PERCENTILE = 0.97;
export const UNUSUAL_RATIO = 3;
export const UNUSUAL_FLOOR_GRAMS = 10;
export const SUBAGENT_SHARE = 0.1;

const NBSP = " ";
const UNIT = "CO₂";

// Unset, empty, C and POSIX say nothing about the language.
function isLocaleValue(value: string | undefined): value is string {
  return (
    value !== undefined &&
    value !== "" &&
    value !== "C" &&
    !value.startsWith("C.") &&
    value !== "POSIX" &&
    !value.startsWith("POSIX.")
  );
}

// Same order and sentinels as detect_equiv_set (scripts/equiv-lib.sh). With no
// variable set, the language setting or else the system locale decides (the
// caller picks it); with neither, French, as in the bash.
export function detectLang(
  envValues: Array<string | undefined>,
  systemLocale?: string,
): Lang {
  const value = envValues.find(isLocaleValue);
  if (value !== undefined) {
    return value.toLowerCase().startsWith("fr") ? "fr" : "en";
  }
  if (systemLocale !== undefined && systemLocale !== "") {
    return systemLocale.toLowerCase().startsWith("fr") ? "fr" : "en";
  }
  return "fr";
}

// Whether one of the variables decides alone, so nothing else needs to be asked.
export function hasLangVariable(envValues: Array<string | undefined>): boolean {
  return envValues.some(isLocaleValue);
}

// The `language` setting is free text ("Français", "English", "japanese"). It goes
// to detectLang as a locale would: French when it starts with "fr", English otherwise.
export function languageSetting(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text === "" ? undefined : text;
}

// What `defaults read -g AppleLocale` ("fr_FR\n") or `reg query ... /v LocaleName`
// ("    LocaleName    REG_SZ    en-US") prints, down to the locale.
export function parseSystemLocale(stdout: string): string | undefined {
  const reg = /LocaleName\s+REG_SZ\s+(\S+)/.exec(stdout);
  if (reg) return reg[1];
  const line = stdout.trim().split(/\r?\n/)[0]?.trim() ?? "";
  return /^\S+$/.test(line) ? line : undefined;
}

function decimal(value: number, digits: number, lang: Lang): string {
  const text = value.toFixed(digits);
  return lang === "fr" ? text.replace(".", ",") : text;
}

// < 0.1 g, one decimal under 10 g, whole grams under 1 kg, then kg with one decimal.
// Rounding keeps the figure readable; the estimate itself is far less precise than one
// decimal.
export function formatGrams(grams: number, lang: Lang): string {
  if (grams < 0.1) return `<${NBSP}${decimal(0.1, 1, lang)}${NBSP}g${UNIT}`;
  const tenths = Math.round(grams * 10) / 10;
  if (tenths < 10) return `${decimal(tenths, 1, lang)}${NBSP}g${UNIT}`;
  const whole = Math.round(grams);
  if (whole < 1000) return `${whole}${NBSP}g${UNIT}`;
  const kilos = Math.round(grams / 100) / 10;
  return `${decimal(kilos, 1, lang)}${NBSP}kg${UNIT}`;
}

export function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const upper = sorted[mid] ?? 0;
  return sorted.length % 2 === 1 ? upper : ((sorted[mid - 1] ?? 0) + upper) / 2;
}

// Linear interpolation between the two closest ranks, q from 0 to 1.
export function percentile(values: number[], q: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (sorted.length - 1) * Math.min(Math.max(q, 0), 1);
  const lower = Math.floor(rank);
  const low = sorted[lower] ?? 0;
  const high = sorted[Math.min(lower + 1, sorted.length - 1)] ?? low;
  return low + (high - low) * (rank - lower);
}

// The current answer is compared before it joins the history.
export function isUnusual(grams: number, history: number[]): boolean {
  if (history.length < MIN_HISTORY || grams < UNUSUAL_FLOOR_GRAMS) return false;
  const m = median(history);
  return (
    m > 0 &&
    grams > UNUSUAL_RATIO * m &&
    grams > percentile(history, UNUSUAL_PERCENTILE)
  );
}

export function buildAnswerCo2(
  turn: TurnTotals,
  history: number[],
  lang: Lang,
): AnswerCo2View {
  const amount = formatGrams(turn.grams, lang);
  if (!isUnusual(turn.grams, history))
    return { main: amount, sub: null, isUnusual: false };
  const ratio = Math.round(turn.grams / median(history));
  const main = `${amount} · ${ratio}× ${lang === "fr" ? "votre médiane" : "your median"}`;
  const share = turn.grams > 0 ? turn.subagentGrams / turn.grams : 0;
  if (turn.subagents === 0 || share < SUBAGENT_SHARE)
    return { main, sub: null, isUnusual: true };
  const n = turn.subagents;
  const grams = formatGrams(turn.subagentGrams, lang);
  const sub =
    lang === "fr"
      ? `dont ${n} sous-agent${n > 1 ? "s" : ""}${NBSP}: ${grams}`
      : `incl. ${n} subagent${n > 1 ? "s" : ""}: ${grams}`;
  return { main, sub, isUnusual: true };
}

// The single line drawn under the answer where the turn duration line is not
// (the Desktop app): only ever for an unusual answer.
export function answerLine(view: AnswerCo2View): string {
  return view.sub === null
    ? view.main
    : `${view.main} · ${view.sub}`;
}

// The entry pinned under the prompt. The surface already heads it with the plugin's name.
// lastAnswerGrams is given only where the turn duration line is not drawn.
export function sessionLine(
  sessionGrams: number,
  lang: Lang,
  lastAnswerGrams: number | null = null,
): string {
  const fr = lang === "fr";
  const total = `${formatGrams(sessionGrams, lang)} ${fr ? "cette session" : "this session"}`;
  if (lastAnswerGrams === null || !(lastAnswerGrams > 0)) return total;
  return `${total} · ${fr ? "dernière réponse" : "last answer"} ${formatGrams(lastAnswerGrams, lang)}`;
}

// Shown once. Where no terminal draws the session (the Desktop app), the figure is in
// the pinned entry and only an unusual answer gets a line of its own.
export function welcomeText(lang: Lang, isRemoteOnly = false): string {
  if (isRemoteOnly)
    return lang === "fr"
      ? "Le total CO₂ de la session reste sous le prompt. Une réponse bien plus lourde que d'habitude le signale."
      : "The session's CO₂ total stays under the prompt. An answer much heavier than usual says so.";
  return lang === "fr"
    ? `Le CO₂ de chaque réponse s'affiche en fin de réponse. Les plus lourdes ressortent après ${MIN_HISTORY} réponses.`
    : `Each answer's CO₂ shows when it ends. The heaviest stand out after ${MIN_HISTORY} answers.`;
}

export function pushHistory(history: number[], grams: number): number[] {
  if (!(grams > 0)) return history;
  return [...history, grams].slice(-HISTORY_SIZE);
}

// The claude-carbon status line already shows the session total: no second one.
export function isCarbonStatusLine(command: unknown): boolean {
  return (
    typeof command === "string" &&
    command.includes("claude-carbon") &&
    command.includes("statusline.sh")
  );
}
