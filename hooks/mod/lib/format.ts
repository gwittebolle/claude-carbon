// What an answer's CO2 line says and when it raises its voice. Pure: no Claude Code API, so
// Node runs it directly (tests/run-mod-tests.mjs).

export type Lang = "fr" | "en";

export type AnswerCo2View = {
  // "16 gCO₂", or "230 gCO₂ · 14× votre médiane" for an unusual answer
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
// variable set, the language setting decides; with none, French, as in the bash.
export function detectLang(
  envValues: Array<string | undefined>,
  setting?: string,
): Lang {
  const value = envValues.find(isLocaleValue);
  if (value !== undefined) {
    return value.toLowerCase().startsWith("fr") ? "fr" : "en";
  }
  if (setting !== undefined && setting !== "") {
    return setting.toLowerCase().startsWith("fr") ? "fr" : "en";
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

// Two decimals, as the status line rounds it; "< 0,01 $" under a cent. French puts the
// sign after the number, English before it.
export function formatUsd(usd: number, lang: Lang): string {
  const isTiny = usd < 0.01;
  const amount = decimal(isTiny ? 0.01 : usd, 2, lang);
  const money = lang === "fr" ? `${amount}${NBSP}$` : `$${amount}`;
  return isTiny ? `<${NBSP}${money}` : money;
}

// The entry pinned under the prompt. The surface already heads it with the plugin's name.
// The cost is left out when there is none to show (no price list read), never shown as 0.
export function sessionLine(
  sessionGrams: number,
  lang: Lang,
  sessionUsd: number | null = null,
): string {
  const fr = lang === "fr";
  const head = fr ? `Cette session${NBSP}:` : "This session:";
  const total = `${head} ${formatGrams(sessionGrams, lang)}`;
  if (sessionUsd === null || !(sessionUsd > 0)) return total;
  return `${total} · ${formatUsd(sessionUsd, lang)}`;
}

// Shown once per machine, the same on every surface.
export function welcomeText(lang: Lang): string {
  return lang === "fr"
    ? "Le CO₂ s'affiche maintenant pour chaque réponse."
    : "CO₂ now shows for each answer.";
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

// ── The /carbon-panel pane ──────────────────────────────────────────────────

export function paneTitle(lang: Lang): string {
  return lang === "fr" ? "Carbone" : "Carbon";
}

export function commandDescription(lang: Lang): string {
  return lang === "fr"
    ? "Votre molécule de CO₂ et l'historique de vos sessions"
    : "Your CO₂ molecule and the history of your sessions";
}

// Shown once per machine to someone already welcomed before the pane existed.
export function paneHint(lang: Lang): string {
  return lang === "fr"
    ? "Tapez /carbon-panel pour voir votre molécule et l'historique de vos sessions."
    : "Type /carbon-panel to see your molecule and the history of your sessions.";
}

export function paneUnplaced(lang: Lang): string {
  return lang === "fr"
    ? `Le panneau carbone ne peut pas s'ouvrir ici${NBSP}: élargissez la fenêtre ou mettez Claude Code à jour.`
    : "The carbon pane cannot open here: widen the window or update Claude Code.";
}

// The molecule's line: the session so far, and its ratio to the median of past sessions.
export function currentLine(
  grams: number,
  sessionMedian: number | null,
  lang: Lang,
): string {
  const fr = lang === "fr";
  const head = fr ? `Cette session${NBSP}:` : "This session:";
  const total = `${head} ${formatGrams(grams, lang)}`;
  if (sessionMedian === null || !(sessionMedian > 0) || !(grams > 0)) return total;
  const r = grams / sessionMedian;
  const ratio =
    r >= 10 ? `${Math.round(r)}` : decimal(r, r >= 1 ? 1 : 2, lang);
  return `${total} · ${ratio}×${NBSP}${fr ? "votre médiane" : "your median"}`;
}

export function colorNote(pastSessions: number, lang: Lang): string {
  return lang === "fr"
    ? `La couleur arrive après 10 sessions (${pastSessions} pour l'instant).`
    : `The colour comes after 10 sessions (${pastSessions} so far).`;
}

export function noHistoryText(lang: Lang): string {
  return lang === "fr"
    ? "L'historique de vos sessions vient avec l'installation complète (voir le README)."
    : "The history of your sessions comes with the full install (see the README).";
}

export function emptyRangeText(lang: Lang): string {
  return lang === "fr"
    ? "Aucune session sur cette période."
    : "No session in this period.";
}


const RANGE_LABELS: Record<string, [string, string]> = {
  "7d": ["7 j", "7 d"],
  "30d": ["30 j", "30 d"],
  "90d": ["3 mois", "3 months"],
  "1y": ["12 mois", "12 months"],
  all: ["Tout", "All"],
  custom: ["Personnalisée", "Custom"],
};
function pick(pair: [string, string] | undefined, lang: Lang): string {
  return pair === undefined ? "" : lang === "fr" ? pair[0] : pair[1];
}

export function rangeLabel(range: string, lang: Lang): string {
  return pick(RANGE_LABELS[range], lang);
}


function countOf(n: number, step: string, lang: Lang): string {
  const fr = lang === "fr";
  if (step === "week") return fr ? `${n} semaine${n > 1 ? "s" : ""}` : `${n} week${n > 1 ? "s" : ""}`;
  if (step === "month") return fr ? `${n} mois` : `${n} month${n > 1 ? "s" : ""}`;
  return `${n} session${n > 1 ? "s" : ""}`;
}

// Under the stripes: what one stripe is, and the median their colours measure against
const PER: Record<string, [string, string]> = {
  day: ["jour", "day"],
  week: ["semaine", "week"],
  month: ["mois", "month"],
};
export function stripesCaption(step: string, stripeMedian: number | null, lang: Lang): string {
  const fr = lang === "fr";
  const unit = pick(PER[step], lang);
  const one = fr ? `une bande par ${unit}` : `one stripe per ${unit}`;
  if (stripeMedian === null) return one;
  const per = fr ? ` par ${unit}` : ` a ${unit}`;
  return `${one} · ${fr ? "médiane" : "median"} ${formatGrams(stripeMedian, lang)}${per}`;
}

// The period's figure, the pane's main one
export function periodHeadline(grams: number, lang: Lang): string {
  return lang === "fr"
    ? `${formatGrams(grams, lang)} sur la période`
    : `${formatGrams(grams, lang)} over the period`;
}

export function sessionsCount(n: number, lang: Lang): string {
  return countOf(n, "session", lang);
}

// A month for the custom range's lists: "mai 2026", "May 2026"
export function monthLabel(key: string, lang: Lang): string {
  const [y, m] = key.split("-").map(Number);
  const names = lang === "fr" ? MONTHS_FULL_FR : MONTHS_FULL_EN;
  return `${names[(m ?? 1) - 1] ?? ""} ${y ?? ""}`;
}

export function fromLabel(lang: Lang): string {
  return lang === "fr" ? "Du" : "From";
}

export function toLabel(lang: Lang): string {
  return lang === "fr" ? "au" : "to";
}

export function waitingText(lang: Lang): string {
  return lang === "fr"
    ? `Cette session${NBSP}: en attente de la première réponse`
    : "This session: waiting for the first answer";
}

// The colour scale, under the stripes: what the extreme colours mean
export function legendText(lang: Lang): string {
  return lang === "fr"
    ? `bleu${NBSP}: sous la médiane · rouge${NBSP}: au-dessus (÷8 à ×8)`
    : "blue: below the median · red: above it (÷8 to ×8)";
}

const MONTHS_FULL_FR = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"];
const MONTHS_FULL_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

const MONTHS_FR = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."];
const MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// A day ("22 août", "Aug 22", with the year when asked), or a month for monthly
// stripes ("août 2026", "Aug 2026").
export function dateLabel(
  ms: number,
  step: string,
  lang: Lang,
  withYear = false,
): string {
  const d = new Date(ms);
  const month = (lang === "fr" ? MONTHS_FR : MONTHS_EN)[d.getMonth()] ?? "";
  if (step === "month") return `${month}${NBSP}${d.getFullYear()}`;
  const year = withYear ? `${NBSP}${d.getFullYear()}` : "";
  return lang === "fr"
    ? `${d.getDate()}${NBSP}${month}${year}`
    : `${month}${NBSP}${d.getDate()}${withYear ? `,${NBSP}${d.getFullYear()}` : ""}`;
}

// A stripe's tooltip in the desktop app.
export function stripeTitle(
  start: number,
  step: string,
  grams: number,
  sessions: number,
  lang: Lang,
): string {
  const fr = lang === "fr";
  const when =
    step === "week"
      ? `${fr ? "semaine du" : "week of"} ${dateLabel(start, "session", lang)}`
      : dateLabel(start, step, lang);
  const amount = grams > 0 ? formatGrams(grams, lang) : fr ? "aucune session" : "no session";
  return sessions === 0
    ? `${when} · ${amount}`
    : `${when} · ${amount} · ${countOf(sessions, "session", lang)}`;
}

// Against the same length of time just before: "+12 % par rapport aux 30 jours
// d'avant". Nothing when there is nothing before to compare with.
const BEFORE: Record<string, [string, string]> = {
  "7d": ["aux 7 jours d'avant", "the 7 days before"],
  "30d": ["aux 30 jours d'avant", "the 30 days before"],
  "90d": ["aux 90 jours d'avant", "the 90 days before"],
  "1y": ["aux 12 mois d'avant", "the 12 months before"],
  custom: ["à la période d'avant", "the period before"],
};

// The change against the period before, in whole percent; null when there is none
export function changePercent(grams: number, previous: number): number | null {
  return previous > 0 ? Math.round(((grams - previous) / previous) * 100) : null;
}
export function compareText(
  grams: number,
  previous: number,
  range: string,
  lang: Lang,
): string | null {
  const before = BEFORE[range];
  const change = changePercent(grams, previous);
  if (before === undefined || change === null) return null;
  const sign = change > 0 ? "+" : change < 0 ? "-" : "";
  const amount = `${sign}${Math.abs(change)}${NBSP}%`;
  return lang === "fr"
    ? `${amount} par rapport ${before[0]}`
    : `${amount} vs ${before[1]}`;
}

// The API-price value for someone on a Claude subscription, who does not pay it:
// "Valeur au prix API : 27 608 $, couverte par votre abonnement"
export function subscriptionValueText(usd: number, lang: Lang): string {
  const money = costText(usd, lang).replace(lang === "fr" ? " au prix API" : " at API prices", "");
  return lang === "fr"
    ? `Valeur au prix API${NBSP}: ${money}, couverte par votre abonnement (vous ne la payez pas)`
    : `API-price value: ${money}, covered by your subscription (you don't pay it)`;
}

// "12,34 $ au prix API", "$12.34 at API prices"
export function costText(usd: number, lang: Lang): string {
  // Whole dollars from a thousand up, grouped: "27 608 $", "$27,608"
  const money =
    usd >= 1000
      ? lang === "fr"
        ? `${thousands(usd, lang)}${NBSP}$`
        : `$${thousands(usd, lang)}`
      : formatUsd(usd, lang);
  return lang === "fr" ? `${money} au prix API` : `${money} at API prices`;
}

function thousands(n: number, lang: Lang): string {
  const whole = String(Math.round(n));
  const sep = lang === "fr" ? NBSP : ",";
  return whole.replace(/\B(?=(\d{3})+(?!\d))/g, sep);
}

// "≈ 1 680 km en voiture (142 g/km, ADEME 2025)", the reports' and cards' car line
export function equivalenceText(
  grams: number,
  car: { divisor: number; label: string; tag: string },
  lang: Lang,
): string {
  return `≈${NBSP}${thousands(grams / car.divisor, lang)} ${car.label} (${car.tag})`;
}

// The blocks a person can show or hide in the pane
export function customizeLabel(isOpen: boolean, lang: Lang): string {
  if (lang === "fr") return isOpen ? "Fermer les options" : "Personnaliser";
  return isOpen ? "Close options" : "Customize";
}

const BLOCK_LABELS: Record<string, [string, string]> = {
  compare: ["Comparaison", "Comparison"],
  cost: ["Coût API", "API cost"],
  equivalence: ["Équivalence", "Equivalence"],
  projects: ["Projets", "Projects"],
};
export function blockLabel(block: string, lang: Lang): string {
  return pick(BLOCK_LABELS[block], lang);
}

export function showLabel(lang: Lang): string {
  return lang === "fr" ? "Afficher" : "Show";
}


// The button that puts /carbon-card in the prompt, for the person to send
export function cardButtonLabel(lang: Lang): string {
  return lang === "fr" ? "Préparer ma carte" : "Prepare my card";
}

// After the button filled the prompt: what is there and what to do
export function cardReadyText(lang: Lang): string {
  return lang === "fr"
    ? `/carbon-card est dans le prompt${NBSP}: appuyez sur Entrée pour créer la carte.`
    : "/carbon-card is in the prompt: press Enter to make the card.";
}

// The prompt could not take it (a dialog is open, or no prompt box here)
export function cardFillFailed(lang: Lang): string {
  return lang === "fr"
    ? `Le prompt n'a pas pu recevoir /carbon-card${NBSP}: tapez-le vous-même.`
    : "The prompt could not take /carbon-card: type it yourself.";
}

// When the prompt already holds a draft, the button leaves it alone and says why
export function cardDraftBusy(lang: Lang): string {
  return lang === "fr"
    ? `Le prompt contient déjà un brouillon${NBSP}: videz-le pour préparer la carte.`
    : "The prompt already holds a draft: clear it to prepare the card.";
}


function percent(share: number): string {
  const p = Math.round(share * 100);
  return p < 1 ? `<${NBSP}1${NBSP}%` : `${p}${NBSP}%`;
}


// A project as a bar, left-aligned so bars compare whatever the font: "███████ 41 % carbonara"
export function projectBarLine(project: string, share: number, lang: Lang): string {
  const name = project === "" ? (lang === "fr" ? "sans projet" : "no project") : project;
  const bar = "█".repeat(Math.max(1, Math.round(share * 16)));
  return `${bar} ${percent(share)} ${name}`;
}

// The rest after the projects listed
export function otherProjectsLine(count: number, grams: number, share: number, lang: Lang): string {
  const fr = lang === "fr";
  const label = fr
    ? `${count} autre${count > 1 ? "s" : ""} projet${count > 1 ? "s" : ""}`
    : `${count} other project${count > 1 ? "s" : ""}`;
  return `${label} · ${formatGrams(grams, lang)} · ${percent(share)}`;
}

// The terminal's single line: the heaviest projects and their shares
export function topProjectsText(
  projects: ReadonlyArray<{ project: string; share: number }>,
  lang: Lang,
): string {
  const head = lang === "fr" ? "surtout" : "mostly";
  const list = projects
    .map((p) => `${p.project === "" ? "?" : p.project} ${percent(p.share)}`)
    .join(", ");
  return `${head} ${list}`;
}



export function mascotAlt(lang: Lang): string {
  return lang === "fr"
    ? "Molécule de CO₂ en pixels, colorée selon cette session par rapport à votre médiane, du bleu (en dessous) au rouge (au-dessus)"
    : "Pixel CO₂ molecule, coloured by this session against your median, from blue (below) to red (above)";
}

export function stripesAlt(lang: Lang): string {
  return lang === "fr"
    ? "Une bande par période, la plus ancienne à gauche, du bleu (sous la médiane) au rouge (au-dessus)"
    : "One stripe per period, oldest on the left, from blue (below the median) to red (above)";
}
