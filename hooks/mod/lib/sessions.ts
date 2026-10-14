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
  // The session's dominant model as the hooks record it, "" when unknown
  model: string;
};

// The current methodology: what the running session is measured with
export const CURRENT_VERSION = 2;

export type Range = "7d" | "30d" | "1y" | "all" | "custom";
// One stripe per day, week or month: picked from the period's length, so the stripes
// always cover the whole period.
export type Step = "day" | "week" | "month";
// A custom range runs from the start of day `from` to the end of day `to`
// ("2026-05-01"), local time.
export type View = { range: Range; from?: string; to?: string };

export const RANGES: readonly Range[] = ["7d", "30d", "1y", "all", "custom"];
export const DEFAULT_VIEW: View = { range: "30d" };
export const HISTORY_FILE = "sessions-history.tsv";
// Below this many past sessions there is no median of one's own: the molecule is coloured
// against a starting reference instead, 0.5 kgCO₂ a session.
export const MIN_SESSIONS = 10;
export const START_MEDIAN_GRAMS = 500;
// Below this many periods with sessions in them the stripes stay uncoloured.
export const MIN_STRIPES = 3;

const DAY_MS = 86_400_000;
const RANGE_DAYS: Record<"7d" | "30d" | "1y", number> = {
  "7d": 7,
  "30d": 30,
  "1y": 365,
};
const DAY_KEY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

export function isView(value: unknown): value is View {
  const v = value as Partial<View> | null | undefined;
  if (typeof v !== "object" || v === null || !RANGES.includes(v.range as Range))
    return false;
  if (v.range !== "custom") return true;
  return (
    typeof v.from === "string" &&
    DAY_KEY.test(v.from) &&
    typeof v.to === "string" &&
    DAY_KEY.test(v.to) &&
    v.from <= v.to
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

// The flag a marketplace install's SessionStart hook writes once a day (check-update.sh):
// the newest released version. In the config's claude-carbon folder, where the hooks keep
// their state, whatever CLAUDE_CARBON_DB says.
export const UPDATE_FILE = "plugin-update-check.json";
export function updateFlagPath(env: {
  configDir?: string;
  home?: string;
  userProfile?: string;
}): string | null {
  const nonEmpty = (v: string | undefined) =>
    v !== undefined && v !== "" ? v : undefined;
  const config = nonEmpty(env.configDir);
  if (config !== undefined) return `${config}/claude-carbon/${UPDATE_FILE}`;
  const home = nonEmpty(env.home) ?? nonEmpty(env.userProfile);
  if (home !== undefined) return `${home}/.claude/claude-carbon/${UPDATE_FILE}`;
  return null;
}

const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;
function isNewer(a: string, b: string): boolean {
  const x = SEMVER.exec(a);
  const y = SEMVER.exec(b);
  if (x === null || y === null) return false;
  for (let i = 1; i <= 3; i++) {
    const d = Number(x[i]) - Number(y[i]);
    if (d !== 0) return d > 0;
  }
  return false;
}

// The released version this install lacks, or null. Compared with the running plugin's
// own version, not the flag's, so an update applied since the last check says nothing;
// a flag older than a week is ignored, as the status line ignores its own.
export function newerRelease(
  flagText: string,
  ownVersion: string | null,
  nowMs: number,
): string | null {
  if (ownVersion === null) return null;
  let flag: unknown;
  try {
    flag = JSON.parse(flagText);
  } catch {
    return null;
  }
  if (typeof flag !== "object" || flag === null) return null;
  const { remote, checked_at } = flag as { remote?: unknown; checked_at?: unknown };
  if (typeof remote !== "string" || typeof checked_at !== "number") return null;
  if (nowMs - checked_at * 1000 > 7 * 86400 * 1000) return null;
  return isNewer(remote, ownVersion) ? remote : null;
}

// One line per session: id, start in epoch seconds, grams, methodology version, project,
// API-price cost, model, tab-separated. Fields an older hook did not write read as the
// current version and as unknown.
// A line that does not read as that is skipped, never guessed.
export function parseHistory(text: string): SessionRow[] {
  const rows: SessionRow[] = [];
  for (const line of text.split(/\r?\n/)) {
    const [id, start, grams, version, project, cost, model] = line.split("\t");
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
      usd: numberOrNull(cost),
      model: model ?? "",
    });
  }
  return rows.sort((a, b) => a.at - b.at);
}

function numberOrNull(field: string | undefined): number | null {
  return field === undefined || field === "" || !Number.isFinite(Number(field))
    ? null
    : Number(field);
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

// What the colours are measured against: the person's own median once there is one, the
// starting reference before, so the molecule has a colour from the first answer.
export function colourMedian(past: readonly SessionRow[]): number {
  return sessionMedian(past) ?? START_MEDIAN_GRAMS;
}

// Where /carbon-panel shows: the band above a terminal's prompt when it was typed there,
// the side pane otherwise. A session run in a terminal and driven from the desktop app
// or a phone (Remote Control, origin "bridge") opens the pane where it was asked for.
export function panelSite(
  surfaces: readonly string[],
  originKind: string,
): "band" | "pane" {
  return surfaces.includes("terminal") && originKind !== "bridge" ? "band" : "pane";
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

export type Bar = {
  // Start of the period, ms since the epoch, local time
  start: number;
  grams: number;
  sessions: number;
};

// Days, weeks and months are built from the date's parts, never by moving an hour:
// where midnight is skipped for summer time, the period still starts at its first
// instant.
function dayStart(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

// Monday 00:00, local time
function weekStart(ms: number): number {
  const d = new Date(ms);
  const offset = (d.getDay() + 6) % 7;
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - offset).getTime();
}

function monthStart(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
}

function startOf(step: Step, ms: number): number {
  return step === "day" ? dayStart(ms) : step === "week" ? weekStart(ms) : monthStart(ms);
}

function nextPeriod(start: number, step: Step): number {
  const d = new Date(start);
  return step === "day"
    ? new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime()
    : step === "week"
      ? new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7).getTime()
      : new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime();
}

// "2026-05-01" for a time, local
export function dayKey(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function dayOf(key: string): number {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y ?? 1970, (m ?? 1) - 1, d ?? 1).getTime();
}

// A date the person typed, "01/05/2026" (day first) or "2026-05-01", as a day key; null
// when it does not read as a real date.
export function parseDay(text: string): string | null {
  const s = text.trim();
  const dmy = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(s);
  const ymd = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s);
  const [y, m, d] = dmy
    ? [Number(dmy[3]), Number(dmy[2]), Number(dmy[1])]
    : ymd
      ? [Number(ymd[1]), Number(ymd[2]), Number(ymd[3])]
      : [NaN, NaN, NaN];
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) return null;
  const date = new Date(y, m - 1, d);
  if (date.getFullYear() !== y || date.getMonth() !== m - 1 || date.getDate() !== d)
    return null;
  return dayKey(date.getTime());
}

export type Window = { start: number; end: number; step: Step };

// The period a view covers and its stripe: a day for up to 45 days, a week for up to
// 400, a month beyond. The presets end now; the whole history starts at the first
// session's period; a custom range covers its days whole, up to now, from its first day
// exactly (its first stripe, a week or a month, is then partial).
export function windowOf(
  view: View,
  rows: readonly SessionRow[],
  now: number,
): Window {
  const stepFor = (span: number): Step =>
    span <= 45 * DAY_MS ? "day" : span <= 400 * DAY_MS ? "week" : "month";
  if (view.range === "custom" && view.from !== undefined && view.to !== undefined) {
    const from = dayOf(view.from);
    const end = Math.min(now, nextPeriod(dayOf(view.to), "day") - 1);
    return { start: from, end, step: stepFor(end - from) };
  }
  if (view.range === "all" || view.range === "custom") {
    const first = rows[0]?.at ?? now;
    const step = stepFor(now - first);
    return { start: startOf(step, first), end: now, step };
  }
  const days = RANGE_DAYS[view.range];
  const step: Step = days <= 45 ? "day" : "week";
  // The current day or week is the last of `days` days, as a calendar reads it. A
  // history younger than the range starts the stripes at its first session: before it
  // there is no data, not a pause.
  const first = rows[0]?.at;
  // Back by calendar days, not by 24-hour spans: a change of clock in between moves
  // neither the first day nor the count of stripes.
  const today = new Date(now);
  const from = startOf(
    step,
    new Date(today.getFullYear(), today.getMonth(), today.getDate() - (days - 1)).getTime(),
  );
  return {
    start: first === undefined ? from : Math.max(from, startOf(step, first)),
    end: now,
    step,
  };
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


// What the stripes cover, summed, as the reports sum it.
export function periodTotal(rows: readonly SessionRow[], w: Window): PeriodTotal {
  return sumOf(rows.filter((r) => r.at >= w.start && r.at <= w.end));
}

// The same length of time just before, for the comparison; null for the whole history.
export function previousTotal(
  rows: readonly SessionRow[],
  w: Window,
  view: View,
): PeriodTotal | null {
  if (view.range === "all") return null;
  const before = w.start - (w.end - w.start);
  return sumOf(rows.filter((r) => r.at >= before && r.at < w.start));
}

// One stripe per period of the window, empty ones included (0 g): a quiet day or week
// shows as a gap, and the stripes always run from the window's start to its end.
export function bars(rows: readonly SessionRow[], w: Window): Bar[] {
  const totals = new Map<number, Bar>();
  for (const r of rows) {
    if (r.at < w.start || r.at > w.end) continue;
    const start = startOf(w.step, r.at);
    const bar = totals.get(start) ?? { start, grams: 0, sessions: 0 };
    bar.grams += r.grams;
    bar.sessions += 1;
    totals.set(start, bar);
  }
  const out: Bar[] = [];
  const last = startOf(w.step, w.end);
  for (let s = startOf(w.step, w.start); s <= last; s = nextPeriod(s, w.step))
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
