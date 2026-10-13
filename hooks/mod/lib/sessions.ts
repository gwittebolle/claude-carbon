// The session history the /carbon-panel pane draws: read from sessions-history.tsv, which
// the Stop hook writes next to carbon.db (cc_export_sessions in scripts/portable-lib.sh).
// The mod never opens the database. Pure: no Claude Code API, so Node runs it directly
// (tests/run-mod-tests.mjs).

import { median } from "./format.ts";

export type SessionRow = {
  id: string;
  // Start of the session, ms since the epoch
  at: number;
  grams: number;
  // Methodology version: 1 for legacy rows, kept as they were stored (never recomputed)
  version: number;
  // The project's folder name, as the hooks record it; "" when unknown
  project: string;
  // The API-price cost, null when the file does not carry it
  usd: number | null;
};

// The current methodology: what the running session is measured with
export const CURRENT_VERSION = 2;

export type Range = "7d" | "30d" | "90d" | "1y" | "all";
export type Step = "session" | "week" | "month";
export type View = { range: Range; step: Step };

export const RANGES: readonly Range[] = ["7d", "30d", "90d", "1y", "all"];
export const STEPS: readonly Step[] = ["session", "week", "month"];
export const DEFAULT_VIEW: View = { range: "30d", step: "session" };
export const HISTORY_FILE = "sessions-history.tsv";
// Below this many past sessions the molecule has no median to be coloured against.
export const MIN_SESSIONS = 10;
// Below this many periods with sessions in them the stripes stay uncoloured.
export const MIN_STRIPES = 3;

const DAY_MS = 86_400_000;
const RANGE_DAYS: Record<Exclude<Range, "all">, number> = {
  "7d": 7,
  "30d": 30,
  "90d": 90,
  "1y": 365,
};

export function isView(value: unknown): value is View {
  const v = value as Partial<View> | null | undefined;
  return (
    typeof v === "object" &&
    v !== null &&
    RANGES.includes(v.range as Range) &&
    STEPS.includes(v.step as Step)
  );
}

// The file's directory, resolved as the bash hooks resolve carbon.db: CLAUDE_CARBON_DB's
// directory, else CLAUDE_CONFIG_DIR/claude-carbon, else the home directory's
// .claude/claude-carbon (HOME, or USERPROFILE on Windows, where the native process has
// no HOME). Null when nothing names a directory.
export function historyPath(env: {
  db?: string;
  configDir?: string;
  home?: string;
  userProfile?: string;
}): string | null {
  const nonEmpty = (v: string | undefined) =>
    v !== undefined && v !== "" ? v : undefined;
  const db = nonEmpty(env.db);
  if (db !== undefined) {
    const cut = Math.max(db.lastIndexOf("/"), db.lastIndexOf("\\"));
    let dir = cut > 0 ? db.slice(0, cut) : cut === 0 ? "" : ".";
    // A Git Bash spelling (/c/Users/...) as the bash side accepts it, on Windows
    const msys = /^\/([a-zA-Z])(\/.*)?$/.exec(dir);
    if (msys !== null && env.userProfile !== undefined)
      dir = `${(msys[1] ?? "").toUpperCase()}:${msys[2] ?? "/"}`;
    return `${dir}/${HISTORY_FILE}`;
  }
  const config = nonEmpty(env.configDir);
  if (config !== undefined) return `${config}/claude-carbon/${HISTORY_FILE}`;
  const home = nonEmpty(env.home) ?? nonEmpty(env.userProfile);
  if (home !== undefined)
    return `${home}/.claude/claude-carbon/${HISTORY_FILE}`;
  return null;
}

// One line per session: id, start in epoch seconds, grams, methodology version, project,
// API-price cost, tab-separated. Fields an older hook did not write read as the current
// version, no project, no cost.
// A line that does not read as that is skipped, never guessed.
export function parseHistory(text: string): SessionRow[] {
  const rows: SessionRow[] = [];
  for (const line of text.split(/\r?\n/)) {
    const [id, start, grams, version, project, cost] = line.split("\t");
    if (
      id === undefined ||
      id === "" ||
      start === undefined ||
      grams === undefined
    )
      continue;
    const seconds = Number(start);
    const g = Number(grams);
    if (!Number.isFinite(seconds) || !Number.isFinite(g) || !(g > 0)) continue;
    const v = version === undefined || version === "" ? CURRENT_VERSION : Number(version);
    rows.push({
      id,
      at: seconds * 1000,
      grams: g,
      version: Number.isFinite(v) ? v : CURRENT_VERSION,
      project: project ?? "",
      usd:
        cost === undefined || cost === "" || !Number.isFinite(Number(cost))
          ? null
          : Number(cost),
    });
  }
  return rows.sort((a, b) => a.at - b.at);
}

// The past sessions: the one running now is in the file with a partial total, and the
// pane shows it from its live total instead.
export function pastSessions(
  rows: readonly SessionRow[],
  currentId: string | null,
) {
  return currentId === null
    ? [...rows]
    : rows.filter((r) => r.id !== currentId);
}

// The median the molecule's colour is measured against: all past sessions, as the
// reports and the published figures count them, or null with too few of them.
export function sessionMedian(past: readonly SessionRow[]): number | null {
  if (past.length < MIN_SESSIONS) return null;
  const m = median(past.map((r) => r.grams));
  return m > 0 ? m : null;
}

// A folder's name from a path, as the hooks' basename gives it
export function folderName(path: string): string {
  const parts = path.split(/[\\/]/).filter((p) => p !== "");
  return parts.at(-1) ?? "";
}

export type ProjectTotal = { project: string; grams: number; share: number };
export type PeriodTotal = {
  grams: number;
  sessions: number;
  // The API-price cost of the sessions that carry one, null when none does
  usd: number | null;
  // Heaviest first
  projects: ProjectTotal[];
};

// Where the view's range starts: whole weeks or months for those steps.
function viewStart(view: View, now: number): number {
  const from = rangeStart(view.range, now);
  return view.step === "session" || !Number.isFinite(from)
    ? from
    : view.step === "week"
      ? weekStart(from)
      : monthStart(from);
}

function sumOf(rows: readonly SessionRow[]): PeriodTotal {
  const grams = rows.reduce((s, r) => s + r.grams, 0);
  const priced = rows.filter((r) => r.usd !== null);
  const usd = priced.length > 0 ? priced.reduce((s, r) => s + (r.usd ?? 0), 0) : null;
  const byProject = new Map<string, number>();
  for (const r of rows)
    byProject.set(r.project, (byProject.get(r.project) ?? 0) + r.grams);
  const projects = [...byProject.entries()]
    .map(([project, g]) => ({ project, grams: g, share: grams > 0 ? g / grams : 0 }))
    .sort((a, b) => b.grams - a.grams);
  return { grams, sessions: rows.length, usd, projects };
}

// What the stripes cover, summed: the range of the view (whole weeks or months for
// those steps), as the reports sum it.
export function periodTotal(
  rows: readonly SessionRow[],
  view: View,
  now: number,
): PeriodTotal {
  const start = viewStart(view, now);
  return sumOf(rows.filter((r) => r.at >= start && r.at <= now));
}

// The same length of time just before, for the comparison; null for the whole history.
export function previousTotal(
  rows: readonly SessionRow[],
  view: View,
  now: number,
): PeriodTotal | null {
  const start = viewStart(view, now);
  if (!Number.isFinite(start)) return null;
  const before = start - (now - start);
  return sumOf(rows.filter((r) => r.at >= before && r.at < start));
}

export type Bar = {
  // Start of the period (or of the session), ms since the epoch, local time
  start: number;
  grams: number;
  sessions: number;
};

// Monday 00:00, local time. Built from the date's parts, never by moving an hour: where
// midnight is skipped for summer time, the day still starts at its first instant.
function weekStart(ms: number): number {
  const d = new Date(ms);
  const offset = (d.getDay() + 6) % 7;
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - offset).getTime();
}

function monthStart(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
}

function nextPeriod(start: number, step: "week" | "month"): number {
  const d = new Date(start);
  return step === "week"
    ? new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7).getTime()
    : new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime();
}

export function rangeStart(range: Range, now: number): number {
  return range === "all" ? -Infinity : now - RANGE_DAYS[range] * DAY_MS;
}

// The stripes of a view: one bar per session, or one per week or month with the total
// of its sessions. Weeks and months are whole: the range starts at the start of the
// period it falls in. Periods are continuous from the first one with a session to the
// one holding `now`, empty ones included (0 g), so a quiet week shows as a gap.
export function bars(
  rows: readonly SessionRow[],
  view: View,
  now: number,
): Bar[] {
  const from = rangeStart(view.range, now);
  if (view.step === "session")
    return rows
      .filter((r) => r.at >= from && r.at <= now)
      .map((r) => ({ start: r.at, grams: r.grams, sessions: 1 }));
  const step = view.step;
  const startOf = step === "week" ? weekStart : monthStart;
  const whole = Number.isFinite(from) ? startOf(from) : from;
  const inRange = rows.filter((r) => r.at >= whole && r.at <= now);
  const totals = new Map<number, Bar>();
  for (const r of inRange) {
    const start = startOf(r.at);
    const bar = totals.get(start) ?? { start, grams: 0, sessions: 0 };
    bar.grams += r.grams;
    bar.sessions += 1;
    totals.set(start, bar);
  }
  if (totals.size === 0) return [];
  const first = Math.min(...totals.keys());
  const last = startOf(now);
  const out: Bar[] = [];
  for (let s = first; s <= last; s = nextPeriod(s, step))
    out.push(totals.get(s) ?? { start: s, grams: 0, sessions: 0 });
  return out;
}

// The median the stripes' colours are measured against: over the periods that have
// sessions, or null with too few of them.
export function barMedian(list: readonly Bar[]): number | null {
  const full = list.filter((b) => b.grams > 0).map((b) => b.grams);
  if (full.length < MIN_STRIPES) return null;
  const m = median(full);
  return m > 0 ? m : null;
}
