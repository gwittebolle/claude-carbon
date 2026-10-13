// The claude-carbon mod: the CO2 of each Claude Code answer, at the moment the answer ends.
//
// Terminal: at the right end of the turn duration line ("✻ Worked for 4s · done 10:32 PM
// ... 1,1 gCO₂"). Desktop app, where that line is not drawn: a line under the answer, for
// unusual answers only. The session total, CO2 and API-price cost, is pinned under the
// prompt, unless a status line already shows it on this surface (the claude-carbon
// one, or showSessionTotal off).
//
// /carbon-panel opens a pane: the mascot, a pixel CO2 molecule coloured by this session against
// the median of past sessions, which walks while Claude works, and the warming stripes
// of past sessions, by session, week or month. The history comes from the file the Stop
// hook writes next to carbon.db (lib/sessions.ts); the mod never opens the database.
//
// One request at a time through turn.step, the formulas, factors and prices of the bash
// plugin (lib/co2.ts, lib/cost.ts). Writes no database, starts no process, calls no
// network, never changes what Claude does.

import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type {
  AnswerCo2Entry,
  PaneBlocks,
  PaneView,
  SessionTotal,
} from "../../types";
import {
  co2Grams,
  DEFAULT_FACTORS,
  isExcluded,
  parseFactors,
} from "./lib/co2.ts";
import type { Factors } from "./lib/co2.ts";
import { costUsd, parsePrices } from "./lib/cost.ts";
import type { Prices } from "./lib/cost.ts";
import {
  answerLine,
  blockLabel,
  buildAnswerCo2,
  cardButtonLabel,
  cardDraftBusy,
  cardFillFailed,
  cardReadyText,
  changePercent,
  colorNote,
  commandDescription,
  compareText,
  costText,
  currentLine,
  customizeLabel,
  dateLabel,
  detectLang,
  emptyRangeText,
  equivalenceText,
  fromLabel,
  hasLangVariable,
  isCarbonStatusLine,
  languageSetting,
  legendText,
  mascotAlt,
  monthLabel,
  noHistoryText,
  otherProjectsLine,
  paneHint,
  paneTitle,
  paneUnplaced,
  periodHeadline,
  projectBarLine,
  pushHistory,
  rangeLabel,
  sessionLine,
  sessionsCount,
  showLabel,
  stripesAlt,
  stripesCaption,
  stripeTitle,
  toLabel,
  topProjectsText,
  waitingText,
  welcomeText,
} from "./lib/format.ts";
import type { Lang } from "./lib/format.ts";
import { lineEntry } from "./lib/lines.ts";
import {
  CELL_COLUMNS,
  CELL_ROWS,
  classOf,
  colorOf,
  MINI_FRAMES,
  mascotCells,
  mascotSvg,
  NEUTRAL,
  stepMs,
  stripeCells,
  stripesSvg,
} from "./lib/mascot.ts";
import type { Stripe } from "./lib/mascot.ts";
import {
  availableMonths,
  barMedian,
  bars,
  CURRENT_VERSION,
  DEFAULT_VIEW,
  folderName,
  historyPath,
  isView,
  monthKey,
  parseHistory,
  pastSessions,
  periodTotal,
  previousTotal,
  RANGES,
  sessionMedian,
  windowOf,
} from "./lib/sessions.ts";
import type { SessionRow } from "./lib/sessions.ts";
import { carEquivalence, equivalenceSet } from "./lib/equiv.ts";
import type { CarEquivalence } from "./lib/equiv.ts";

// One entry per main-loop turn, oldest first, uncounted turns included (co2 null) so
// a duration line never borrows another turn's figure (lib/lines.ts).
const answers = atom(
  { plugin: "claude-carbon", key: "answers" } as const,
  [] as AnswerCo2Entry[],
);
const session = atom(
  { plugin: "claude-carbon", key: "session" } as const,
  { grams: 0, usd: 0, turns: 0 } as SessionTotal,
);

const working = atom(
  { plugin: "claude-carbon", key: "working" } as const,
  false,
);
const paneView = atom(
  { plugin: "claude-carbon", key: "view" } as const,
  DEFAULT_VIEW as PaneView,
);
// What the pane shows under the stripes, besides the total: the person's choice
const DEFAULT_BLOCKS: PaneBlocks = {
  compare: true,
  cost: true,
  equivalence: true,
  projects: false,
};
const BLOCKS = ["compare", "cost", "equivalence", "projects"] as const;
const paneBlocks = atom(
  { plugin: "claude-carbon", key: "blocks" } as const,
  DEFAULT_BLOCKS,
);

const PANE_ID = "carbon";
const COMMAND = "carbon-panel";
// The pane's last range and step, and the blocks shown, kept for the next session
const VIEW_KEY = "pane.view";
const BLOCKS_KEY = "pane.blocks";
// The one-time "/carbon-panel" hint, for someone welcomed before the pane existed
const HINT_KEY = "pane.hinted";
// The middle of the palette, for a walk with no colour to set its pace
const NEUTRAL_CLASS = 3;
// The most stripes drawn, the most recent kept: in the desktop app few enough to stay
// readable in a side pane (and far under the Svg's 131072 characters), in a terminal
// what the line holds, up to a Raster's 512 columns.
const DESKTOP_MAX_STRIPES = 180;
const RASTER_MAX_COLUMNS = 512;
// How long the pane says that /carbon-card waits in the prompt
const CARD_NOTE_MS = 10_000;

// v2: the values of v1 counted background subagents in the answer that started them.
// The v1 key is left as it is and never read again.
const HISTORY_KEY = "history.v2";
const KEEP_ANSWERS = 100;

type History = {
  values: number[];
  welcomed: boolean;
};

// The answer being written: from the main loop's turn.start to its turn.complete.
type OpenTurn = {
  turnId: string;
  grams: number;
  subagentGrams: number;
  // Subagents started in the foreground during this turn, and those that made a request
  spawned: Set<string>;
  stepped: Set<string>;
};

function openTurn(turnId: string): OpenTurn {
  return {
    turnId,
    grams: 0,
    subagentGrams: 0,
    spawned: new Set(),
    stepped: new Set(),
  };
}

// $.store is shared by every session on the machine and has no conditional write: two
// sessions ending a turn at once can lose one value of the history. The median tolerates it.
async function loadHistory($: EngineInterface): Promise<History> {
  const raw = (await $.store.get(HISTORY_KEY)) as Partial<History> | undefined;
  const values = Array.isArray(raw?.values)
    ? raw.values.filter((v): v is number => typeof v === "number" && v > 0)
    : [];
  return { values, welcomed: raw?.welcomed === true };
}

// No terminal draws this session: the duration line never shows here.
function isRemoteOnly(surfaces: readonly string[]): boolean {
  return surfaces.length > 0 && !surfaces.includes("terminal");
}

// /clear and /resume go on in another conversation: its total and per-answer figures start over.
async function resetSessionState($: EngineInterface) {
  await $.state.set(
    { plugin: "claude-carbon", key: "session" },
    { grams: 0, usd: 0, turns: 0 },
  );
  await $.state.set({ plugin: "claude-carbon", key: "answers" }, []);
  $.ui.status(undefined);
}

// The pane. Where the history file is, this session's id (its own row in the file holds
// a partial total), and the history as last read: undefined until read, null when there
// is no file to read (no database: an install without the bash hooks). The walk in the
// terminal: the frame shown, and the timer that steps it, read by the drawing so a
// redraw for another reason (a new request's total) keeps the step.
const pane: {
  historyFile: string | null;
  sessionId: string | null;
  rows: SessionRow[] | null | undefined;
  walkFrame: number;
  walkTimer: { cancel: () => void } | null;
  // Bumped by every start and stop of the walk: a step begun under an older one stops,
  // so two chains never run at once and a stopped walk never draws again.
  walkRun: number;
  // This session's project, its folder's name, as the hooks will record it
  project: string;
  // Until when the pane confirms that /carbon-card waits in the prompt (ms)
  cardReadyUntil: number;
  // The row of block switches is open
  customizing: boolean;
} = {
  historyFile: null,
  sessionId: null,
  rows: undefined,
  walkFrame: 0,
  walkTimer: null,
  walkRun: 0,
  project: "",
  cardReadyUntil: 0,
  customizing: false,
};

async function loadPaneHistory($: EngineInterface) {
  if (pane.historyFile === null) {
    pane.rows = null;
    return;
  }
  try {
    const text = await $.fs.read(pane.historyFile);
    pane.rows = typeof text === "string" ? parseHistory(text) : null;
  } catch {
    pane.rows = null;
  }
}

async function isPaneOpen($: EngineInterface): Promise<boolean> {
  try {
    return (await $.ui.panes()).some((open) => open.id === PANE_ID);
  } catch {
    return false;
  }
}

// The molecule's class: this session against the median of past sessions, null without
// enough of them.
async function currentClass($: EngineInterface): Promise<number | null> {
  const total = await read($, session);
  const m = sessionMedian(pastSessions(pane.rows ?? [], pane.sessionId));
  return m === null ? null : classOf(total.grams, m);
}

function isBlocks(value: unknown): value is PaneBlocks {
  const v = value as Partial<Record<string, unknown>> | null | undefined;
  return (
    typeof v === "object" &&
    v !== null &&
    BLOCKS.every((block) => typeof v[block] === "boolean")
  );
}

function stopWalk() {
  pane.walkTimer?.cancel();
  pane.walkTimer = null;
  pane.walkFrame = 0;
  pane.walkRun += 1;
}

// One step of the terminal's molecule while a turn runs and the pane is open: a blit of
// the next frame, no redraw, then the next step at the pace of the current colour. A
// blit the surface refuses (the pane in a hidden tab) is left be. Each await may see the
// walk stopped or restarted: the step then ends without drawing.
async function walkStep($: EngineInterface, run: number) {
  const isCurrent = () => run === pane.walkRun;
  try {
    const surfaces = await $.session.surfaces();
    const goOn =
      surfaces.includes("terminal") &&
      (await read($, working)) &&
      (await isPaneOpen($));
    if (!isCurrent()) return;
    if (!goOn) {
      stopWalk();
      return;
    }
    const cls = await currentClass($);
    if (!isCurrent()) return;
    pane.walkFrame = 1 - pane.walkFrame;
    await $.ui
      .blit({
        requestId: PANE_ID,
        key: "mascot",
        cells: mascotCells(MINI_FRAMES[pane.walkFrame] ?? MINI_FRAMES[0], colorOf(cls)),
        columns: CELL_COLUMNS,
        rows: CELL_ROWS,
      })
      .catch(() => undefined);
    if (!isCurrent()) return;
    pane.walkTimer = $.clock.after(stepMs(cls ?? NEUTRAL_CLASS), () => {
      void walkStep($, run);
    });
  } catch {
    if (isCurrent()) stopWalk();
  }
}

function ensureWalk($: EngineInterface) {
  if (pane.walkTimer !== null) return;
  pane.walkRun += 1;
  const run = pane.walkRun;
  pane.walkTimer = $.clock.after(stepMs(NEUTRAL_CLASS), () => {
    void walkStep($, run);
  });
}

export const register: Register = (on, options) => {
  const showPerTurn = options.showPerTurn !== false;
  // Off where a status line already shows the total (ccstatusline with the
  // claude-carbon segment): read like the claude-carbon status line, so the
  // desktop app, which draws no status line, keeps it.
  const showSessionTotal = options.showSessionTotal !== false;
  let factors: Factors = DEFAULT_FACTORS;
  // The car equivalence of the pane, from the same file and set as the reports
  let factorsJson: unknown = null;
  let car: CarEquivalence | null = null;
  // Null when data/prices.json cannot be read: the entry then shows the CO2 alone.
  let prices: Prices | null = null;
  let lang: Lang = "fr";
  let hasCarbonStatusLine = false;
  let current: OpenTurn | null = null;
  // Background subagents: their requests count in the session total only, since they
  // can go on after the answer that started them has ended. Kept across /clear: an
  // agent started before it may still be running.
  const background = new Set<string>();
  // The turn each foreground subagent was started in. Its requests count in that
  // answer only, even when it outlives it.
  const owner = new Map<string, string>();
  // The history as this session last read or wrote it: an answer's figure is ready
  // before the engine draws its line, with no store read in between.
  let known: History | null = null;
  // When each duration line was first drawn, by requestId: only a line first drawn
  // as a turn ends takes that turn's figure, never one drawn again later. Kept here,
  // since a drawing never writes $.state.
  const firstDrawn = new Map<string, number>();
  const turnOf = new Map<string, string>();
  const taken = new Set<string>();

  on("session.start", async ($, e, next) => {
    try {
      const text = await $.fs.read(`${$.plugin.root}/data/factors.json`);
      factorsJson = typeof text === "string" ? JSON.parse(text) : null;
      factors =
        factorsJson !== null ? parseFactors(factorsJson) : DEFAULT_FACTORS;
    } catch {
      factors = DEFAULT_FACTORS;
    }
    try {
      const text = await $.fs.read(`${$.plugin.root}/data/prices.json`);
      prices = typeof text === "string" ? parsePrices(JSON.parse(text)) : null;
    } catch {
      prices = null;
    }

    let settings: Record<string, unknown> = {};
    try {
      settings = await $.settings.read();
    } catch {
      settings = {};
    }
    const statusLine = settings.statusLine as { command?: unknown } | undefined;
    hasCarbonStatusLine = isCarbonStatusLine(statusLine?.command);

    // Same variables, order and sentinels as the reports. The desktop app and a
    // Windows session usually set none: then the language setting, then French.
    const envValues = [
      await $.env.get("CLAUDE_CARBON_LOCALE"),
      await $.env.get("LC_ALL"),
      await $.env.get("LC_MESSAGES"),
      await $.env.get("LANG"),
    ];
    lang = detectLang(
      envValues,
      hasLangVariable(envValues)
        ? undefined
        : languageSetting(settings.language),
    );
    car = carEquivalence(factorsJson, equivalenceSet(envValues, lang));

    // Once per machine. A session nothing draws yet is welcomed at its first
    // answer instead.
    const history = await loadHistory($);
    known = history;
    if (!history.welcomed && e.isInteractive) {
      const surfaces = await $.session.surfaces();
      if (surfaces.length > 0) {
        $.ui.toast(welcomeText(lang), { timeoutMs: 10000 });
        known = { ...history, welcomed: true };
        await $.store.set(HISTORY_KEY, known);
      }
    }

    // The pane: where its history is, this session's id, the last range and step.
    try {
      pane.historyFile = historyPath({
        db: await $.env.get("CLAUDE_CARBON_DB"),
        configDir: await $.env.get("CLAUDE_CONFIG_DIR"),
        home: await $.env.get("HOME"),
        userProfile: await $.env.get("USERPROFILE"),
      });
      pane.sessionId = await $.session.id().catch(() => null);
      pane.project = folderName(e.cwd ?? "");
      pane.rows = undefined;
      stopWalk();
      await $.state.set({ plugin: "claude-carbon", key: "working" }, false);
      const kept = await $.store.get(VIEW_KEY);
      if (isView(kept)) {
        await $.state.set({ plugin: "claude-carbon", key: "view" }, kept);
      }
      const keptBlocks = await $.store.get(BLOCKS_KEY);
      if (isBlocks(keptBlocks)) {
        await $.state.set({ plugin: "claude-carbon", key: "blocks" }, keptBlocks);
      }
    } catch {
      // The pane opens on what could be read.
    }

    // Last: a taken name throws, and nothing above depends on it. Someone welcomed
    // before the pane existed then hears of /carbon-panel once, if it is ours; a welcome
    // shown in this very session waits for the next one: one toast at a time.
    try {
      await $.command.register({
        name: COMMAND,
        description: commandDescription(lang),
        immediate: true,
      });
      if (history.welcomed && e.isInteractive) {
        const hinted = (await $.store.get(HINT_KEY)) === true;
        const surfaces = await $.session.surfaces();
        if (!hinted && surfaces.length > 0) {
          $.ui.toast(paneHint(lang), { timeoutMs: 10000 });
          await $.store.set(HINT_KEY, true);
        }
      }
    } catch {
      // /carbon-panel is someone else's here: the rest of the mod works without it.
    }

    return next(e);
  });

  on("agent.spawn", async ($, e, next) => {
    const started = await next(e);
    const id = started.agentId;
    if (id !== undefined) {
      const parent = e.parentAgentId;
      // A subagent of a background subagent is in the background too, and one of a
      // foreground subagent belongs to its parent's answer.
      if (e.background || (parent !== undefined && background.has(parent))) {
        background.add(id);
      } else {
        const turnId =
          (parent !== undefined ? owner.get(parent) : undefined) ??
          current?.turnId;
        if (turnId !== undefined) owner.set(id, turnId);
        if (current !== null && turnId === current.turnId) {
          current.spawned.add(id);
        }
      }
    }
    return started;
  }).catch(($, e, next) => next(e));

  // A foreground subagent sent to the background (ctrl+b) ends its Agent call with
  // this status: from then on it counts like one started there.
  // @ts-ignore TS2589 under TypeScript 5.6, which gives up on this matcher's types
  on("tool.call", { tool: "Agent" }, async ($, e, next) => {
    const called = await next(e);
    const record = called.result as
      { status?: unknown; agentId?: unknown } | undefined;
    if (
      record?.status === "async_launched" &&
      typeof record.agentId === "string"
    ) {
      background.add(record.agentId);
      current?.spawned.delete(record.agentId);
    }
    return called;
  }).catch(($, e, next) => next(e));

  on("turn.start", async ($, e, next) => {
    // The main loop alone raises turn.start; a subagent's run does not.
    current = openTurn(e.turnId);
    try {
      await $.state.set({ plugin: "claude-carbon", key: "working" }, true);
      if (await isPaneOpen($)) ensureWalk($);
    } catch {
      // The molecule stands still; the turn goes on.
    }
    return next(e);
  });

  on("turn.step", async function* ($, e, next) {
    const result = yield* next(e);
    try {
      const usage = result.usage;
      if (usage !== null) {
        const model = usage.model !== "" ? usage.model : e.model;
        if (!isExcluded(model, factors.excludeModels)) {
          const grams = co2Grams(usage, model, factors);
          const usd = prices !== null ? costUsd(usage, model, prices) : null;
          await update($, session, ({ usd: spent, ...total }) => ({
            ...total,
            grams: total.grams + grams,
            // A request with no price, or a total kept from code that counted no cost,
            // leaves the cost out until the total starts over.
            ...(usd !== null && spent !== undefined ? { usd: spent + usd } : {}),
          }));
          const agent = e.agentId;
          // Outside an open answer, from a background subagent or from a subagent of
          // an earlier answer: session total only. An agent no spawn named (the
          // engine's own work, a compaction) counts in the open answer.
          if (
            current !== null &&
            (agent === undefined ||
              (!background.has(agent) &&
                (owner.get(agent) ?? current.turnId) === current.turnId))
          ) {
            current.grams += grams;
            // Work the engine runs on its own (a compaction) is in the answer's
            // total but is not named as a subagent.
            if (agent !== undefined && current.spawned.has(agent)) {
              current.subagentGrams += grams;
              current.stepped.add(agent);
            }
          }
        }
      }
    } catch {
      // A failed measure never touches the response.
    }
    return result;
  });

  on("turn.complete", async ($, e, next) => {
    if (e.agentId !== undefined) return next(e);
    // Before anything that may return early: a module reloaded during the turn has no
    // open answer, and the molecule must still stop.
    stopWalk();
    // No history file yet (an update installed in this very session): the Stop hook
    // writes one after this answer, and the pane's next drawing reads it again.
    if (pane.rows === null) pane.rows = undefined;
    try {
      await $.state.set({ plugin: "claude-carbon", key: "working" }, false);
    } catch {
      // The next session start sets it again.
    }
    // Only the turn that opened the answer closes it.
    const done = current;
    if (done === null || e.turnId !== done.turnId) return next(e);
    current = null;
    const isCounted = done.grams > 0;
    let co2: AnswerCo2Entry["co2"] = null;
    try {
      // Written before the engine draws the turn's duration line, which takes the
      // entry written within a second of its first draw.
      if (known === null) known = await loadHistory($);
      co2 = isCounted
        ? buildAnswerCo2(
            {
              grams: done.grams,
              subagentGrams: done.subagentGrams,
              subagents: done.stepped.size,
            },
            known.values,
            lang,
          )
        : null;
      const at = await $.clock.now();
      await update($, answers, (all) =>
        [
          ...all,
          { turnId: done.turnId, durationMs: e.durationMs, at, co2 },
        ].slice(-KEEP_ANSWERS),
      );
    } catch {
      // The line stays as the engine draws it.
    }
    const result = await next(e);
    try {
      const history = await loadHistory($);
      const surfaces = await $.session.surfaces();
      const remoteOnly = isRemoteOnly(surfaces);
      const isWelcome = !history.welcomed && surfaces.length > 0;
      if (isWelcome) {
        $.ui.toast(welcomeText(lang), { timeoutMs: 10000 });
      }
      known = history;
      if (isCounted || isWelcome) {
        known = {
          ...history,
          ...(isCounted
            ? { values: pushHistory(history.values, done.grams) }
            : {}),
          welcomed: history.welcomed || isWelcome,
        };
        await $.store.set(HISTORY_KEY, known);
      }
      await update($, session, (total) => ({
        ...total,
        turns: total.turns + 1,
      }));
      const { value: total } = await $.state.get({
        plugin: "claude-carbon",
        key: "session",
      });
      // A status line only shows in a terminal.
      if (
        ((showSessionTotal && !hasCarbonStatusLine) || remoteOnly) &&
        total !== undefined &&
        total.grams > 0
      ) {
        $.ui.status(sessionLine(total.grams, lang, total.usd ?? null));
      }
      // The figure becomes a line under the answer, for unusual answers only.
      if (co2 !== null && co2.isUnusual && showPerTurn && remoteOnly) {
        return { ...result, text: answerLine(co2) };
      }
    } catch {
      // A failure here leaves the answer as it was.
    }
    return result;
  });

  on("session.end", async ($, e, next) => {
    // /clear and /resume (and /branch, reported as resume) go on in another conversation.
    if (e.reason === "clear" || e.reason === "resume") {
      current = null;
      await resetSessionState($);
    }
    return next(e);
  });

  // /carbon-panel opens the pane, or closes it when it is open. Opened without the keyboard:
  // the pane has nothing to type into, and Escape must still interrupt a turn.
  on("command.run", { command: COMMAND }, async ($) => {
    try {
      if (await isPaneOpen($)) {
        stopWalk();
        await $.ui.close({ id: PANE_ID });
        return {};
      }
      pane.rows = undefined;
      await loadPaneHistory($);
      // Inline above the prompt (the classic renderer, or a narrow terminal): tall
      // enough for the molecule, the stripes and the buttons. Docked beside the
      // transcript (fullscreen rendering, from 110 columns): a sidebar wide enough
      // for a line of buttons. A size the person gave the pane wins.
      const opened = await $.ui.open({
        id: PANE_ID,
        title: paneTitle(lang),
        closeOnEscape: true,
        rows: 10,
        columns: 48,
      });
      if (!opened.isPlaced) {
        $.ui.toast(paneUnplaced(lang), { timeoutMs: 8000 });
      } else if (await read($, working)) {
        ensureWalk($);
      }
    } catch {
      // Nothing opened: the command ends quietly.
    }
    return {};
  }).catch(() => ({}));

  on("ui.close", ($, e, next) => {
    if (e.id === PANE_ID) stopWalk();
    return next(e);
  }).catch(($, e, next) => next(e));

  on("ui.render", { component: "Pane", requestId: PANE_ID }, async ($, e, next) => {
    try {
      if (pane.rows === undefined) await loadPaneHistory($);
      if (pane.sessionId === null)
        pane.sessionId = await $.session.id().catch(() => null);
      const total = await read($, session);
      const isWorking = await read($, working);
      const view = await read($, paneView);
      const now = await $.clock.now();
      const past = pastSessions(pane.rows ?? [], pane.sessionId);
      const sm = sessionMedian(past);
      // Grey until there is a median, and until this session has counted something
      const cls = sm === null || !(total.grams > 0) ? null : classOf(total.grams, sm);
      const color = colorOf(cls);
      // The running session joins the stripes with its live total, as the newest, at
      // the start its own row in the file gives.
      const own = (pane.rows ?? []).find((r) => r.id === pane.sessionId);
      const isLive = total.grams > 0;
      const rows = isLive
        ? [
            ...past,
            {
              id: pane.sessionId ?? "current",
              at: own?.at ?? now,
              grams: total.grams,
              version: CURRENT_VERSION,
              project: own?.project ?? pane.project,
              usd: total.usd ?? null,
            },
          ]
        : past;
      // The window the view covers, and one stripe per day, week or month across all of
      // it: the stripes always match the period picked.
      const w = windowOf(view, rows, now);
      const list = pane.rows === null ? [] : bars(rows, w);
      // The stripes measure the periods against each other, the one still filling (today,
      // this week, this month) left out of the median.
      const bm = barMedian(list.slice(0, -1));
      const isTerminal = e.surface === "terminal";
      const room = isTerminal
        ? Math.min(RASTER_MAX_COLUMNS, Math.max(10, e.props.bodyColumns - 2))
        : DESKTOP_MAX_STRIPES;
      // A window longer than the room (years by month in a narrow terminal) keeps its
      // most recent periods
      const shown = list.slice(-room);
      const stripes: Stripe[] = shown.map((b) => ({
        color: b.grams > 0 ? (bm === null ? NEUTRAL : colorOf(classOf(b.grams, bm))) : null,
        title: stripeTitle(b.start, w.step, b.grams, b.sessions, lang),
        start: b.start,
      }));
      const blocks = await read($, paneBlocks);
      const months = availableMonths(rows, now);
      const setView = (chosen: PaneView) => {
        void (async () => {
          await $.state.set({ plugin: "claude-carbon", key: "view" }, chosen);
          await $.store.set(VIEW_KEY, chosen);
        })().catch(() => undefined);
      };

      const ui = $.ui.resolve(e);
      const { Box, Text, Button } = ui;
      const mascot = isTerminal ? (
        <ui.Raster
          key="mascot"
          columns={CELL_COLUMNS}
          rows={CELL_ROWS}
          cells={mascotCells(MINI_FRAMES[pane.walkFrame] ?? MINI_FRAMES[0], color)}
        />
      ) : (
        <ui.Svg
          source={mascotSvg({
            color,
            walking: isWorking,
            step: stepMs(cls ?? NEUTRAL_CLASS),
            title: mascotAlt(lang),
          })}
          alt={mascotAlt(lang)}
          width={112}
          height={90}
          isInteractive
        />
      );
      // A terminal draws a plain button as its label alone: the choice in full
      // strength, the others dim. The desktop app draws its own buttons.
      const choice = (isChosen: boolean) =>
        isTerminal
          ? { plain: true as const, ...(isChosen ? {} : { dimColor: true }) }
          : isChosen
            ? { variant: "primary" as const }
            : { dimColor: true };
      const sessionText = total.grams > 0 ? currentLine(total.grams, sm, lang) : waitingText(lang);
      const hasStripes = pane.rows !== null && stripes.length > 0;
      const withYear = w.end - w.start > 300 * 86_400_000;
      const firstShown = shown[0];
      const dates =
        firstShown === undefined
          ? ""
          : `${dateLabel(Math.max(w.start, firstShown.start), w.step, lang, withYear)} → ${dateLabel(w.end, w.step, lang, withYear)}`;

      const rangeButtons = RANGES.map((range, i) => (
        <Button
          key={`range-${range}`}
          label={rangeLabel(range, lang)}
          // A terminal shows the digit before a plain label; the desktop app would draw
          // a key badge on every button, so it gets none.
          {...(isTerminal ? { hotkey: String(i + 1) } : {})}
          {...choice(view.range === range)}
          onPress={() => {
            if (range !== "custom") return setView({ range });
            // A custom range opens on the last three months, then the lists move it
            const to = months.at(-1) ?? monthKey(now);
            const from = months.at(-3) ?? months[0] ?? to;
            setView({ range, from: view.from ?? from, to: view.to ?? to });
          }}
        />
      ));
      const monthOptions = months.map((m) => ({ value: m, label: monthLabel(m, lang) }));
      const customRange = view.range === "custom" && monthOptions.length > 0 && (
        <Box flexDirection="row" columnGap={1} flexWrap="wrap" alignItems="center">
          <Text dimColor>{fromLabel(lang)}</Text>
          <ui.Select
            key="from"
            value={view.from ?? monthOptions[0]?.value ?? ""}
            options={monthOptions}
            onSelect={(value: string) => {
              const to = view.to !== undefined && view.to >= value ? view.to : value;
              setView({ range: "custom", from: value, to });
            }}
          />
          <Text dimColor>{toLabel(lang)}</Text>
          <ui.Select
            key="to"
            value={view.to ?? monthOptions.at(-1)?.value ?? ""}
            options={monthOptions}
            onSelect={(value: string) => {
              const from = view.from !== undefined && view.from <= value ? view.from : value;
              setView({ range: "custom", from, to: value });
            }}
          />
        </Box>
      );

      // Puts /carbon-card in an empty prompt, never sends it: the card is a skill, a
      // model turn the person starts themselves. A draft in progress is left alone.
      const prepareCard = () => {
        void (async () => {
          const box = await $.prompt.read();
          if (box.text.trim() !== "") {
            $.ui.toast(cardDraftBusy(lang), { timeoutMs: 6000 });
            return;
          }
          const filled = await $.prompt.fill({ text: "/carbon-card" });
          if (!filled.isFilled) {
            $.ui.toast(cardFillFailed(lang), { timeoutMs: 6000 });
            return;
          }
          // Said twice, since a prompt filled from a side pane is easy to miss: a toast,
          // and a line under the button for ten seconds.
          $.ui.toast(cardReadyText(lang), { timeoutMs: 8000 });
          pane.cardReadyUntil = (await $.clock.now()) + CARD_NOTE_MS;
          $.ui.invalidate("ui.render");
          $.clock.after(CARD_NOTE_MS, () => {
            $.ui.invalidate("ui.render");
          });
        })().catch(() => undefined);
      };
      const isCardReady = now < pane.cardReadyUntil;
      const cardButton = (
        <Button
          key="card"
          label={cardButtonLabel(lang)}
          {...(isTerminal ? { hotkey: "c", plain: true as const } : { variant: "primary" as const })}
          onPress={prepareCard}
        />
      );

      // In a terminal each stripe widens to fill the line: three months read as three
      // wide bands, not three cells.
      const stripeWidth = Math.max(1, Math.min(8, Math.floor(room / Math.max(1, stripes.length))));
      const stripesDrawing = isTerminal ? (
        <ui.Raster
          key="stripes"
          columns={stripes.length * stripeWidth}
          rows={2}
          cells={stripeCells(stripes, 2, stripeWidth)}
        />
      ) : (
        <ui.Svg
          source={stripesSvg(stripes, stripesAlt(lang))}
          alt={stripesAlt(lang)}
          width={Math.min(720, Math.max(200, e.props.bodyColumns * 8))}
          height={72}
          isInteractive
        />
      );

      // The period summed, its change against the same length of time before (green
      // when it fell, red when it rose), then what the person chose to see with it.
      const totals = pane.rows === null ? null : periodTotal(rows, w);
      const hasTotals = totals !== null && totals.sessions > 0;
      const previous = blocks.compare ? previousTotal(rows, w, view) : null;
      const change =
        hasTotals && totals !== null && previous !== null
          ? compareText(totals.grams, previous.grams, view.range, lang)
          : null;
      const delta =
        totals !== null && previous !== null ? changePercent(totals.grams, previous.grams) : null;
      const secondary: string[] = [];
      if (hasTotals && totals !== null) {
        secondary.push(sessionsCount(totals.sessions, lang));
        if (blocks.cost && totals.usd !== null && totals.usd > 0)
          secondary.push(costText(totals.usd, lang));
        if (blocks.equivalence && car !== null)
          secondary.push(equivalenceText(totals.grams, car, lang));
      }
      const listed = blocks.projects ? (totals?.projects.slice(0, 5) ?? []) : [];
      const rest = blocks.projects ? (totals?.projects.slice(5) ?? []) : [];
      const restGrams = rest.reduce((s, p) => s + p.grams, 0);
      const changeText =
        change === null ? null : (
          <Text color={delta !== null && delta > 0 ? "error" : delta !== null && delta < 0 ? "success" : "inactive"}>
            {change}
          </Text>
        );

      const setBlocks = (chosen: PaneBlocks) => {
        void (async () => {
          await $.state.set({ plugin: "claude-carbon", key: "blocks" }, chosen);
          await $.store.set(BLOCKS_KEY, chosen);
        })().catch(() => undefined);
      };
      const customizeButton = (
        <Button
          key="customize"
          label={customizeLabel(pane.customizing, lang)}
          {...(isTerminal ? { hotkey: "o", plain: true as const, dimColor: true } : {})}
          onPress={() => {
            pane.customizing = !pane.customizing;
            $.ui.invalidate("ui.render");
          }}
        />
      );
      const options = pane.customizing && (
        <Box flexDirection="row" columnGap={1} flexWrap="wrap" alignItems="center">
          <Text dimColor>{showLabel(lang)}</Text>
          {BLOCKS.map((block) => (
            <Button
              key={`block-${block}`}
              label={blockLabel(block, lang)}
              {...choice(blocks[block])}
              onPress={() => setBlocks({ ...blocks, [block]: !blocks[block] })}
            />
          ))}
        </Box>
      );
      const noHistory = pane.rows === null && <Text dimColor>{noHistoryText(lang)}</Text>;
      const empty =
        pane.rows !== null && !hasTotals && <Text dimColor>{emptyRangeText(lang)}</Text>;

      // The terminal packs everything beside a small molecule, for a short block above the
      // prompt; the desktop app's side pane stacks it, the period's figure first.
      return isTerminal ? (
        <Box flexDirection="column">
          <Box flexDirection="row">
            {mascot}
            <Box flexDirection="column" marginLeft={2} flexShrink={1}>
              <Text bold>{sessionText}</Text>
              {sm === null && <Text dimColor>{colorNote(past.length, lang)}</Text>}
              <Box flexDirection="row" columnGap={2} flexWrap="wrap">
                {rangeButtons}
                <Text dimColor>·</Text>
                {cardButton}
                {customizeButton}
              </Box>
            </Box>
          </Box>
          {customRange}
          {options}
          {noHistory}
          {empty}
          {hasStripes && stripesDrawing}
          {hasStripes && (
            <Text dimColor>{`${dates} · ${stripesCaption(w.step, bm, lang)}`}</Text>
          )}
          {hasTotals && totals !== null && (
            <Box flexDirection="row" columnGap={1} flexWrap="wrap">
              <Text bold>{periodHeadline(totals.grams, lang)}</Text>
              {changeText}
              <Text dimColor>
                {[
                  ...secondary,
                  ...(blocks.projects
                    ? [topProjectsText(totals.projects.slice(0, 3), lang)]
                    : []),
                ].join(" · ")}
              </Text>
            </Box>
          )}
          {isCardReady && <Text bold>{cardReadyText(lang)}</Text>}
        </Box>
      ) : (
        <Box flexDirection="column" rowGap={1}>
          <Box flexDirection="row" alignItems="center">
            {mascot}
            <Box flexDirection="column" marginLeft={2} flexShrink={1}>
              <Text bold>{sessionText}</Text>
              {sm === null && <Text dimColor>{colorNote(past.length, lang)}</Text>}
            </Box>
          </Box>
          <Box flexDirection="column" rowGap={1}>
            <Box flexDirection="row" columnGap={1} flexWrap="wrap">
              {rangeButtons}
            </Box>
            {customRange}
          </Box>
          {noHistory}
          {empty}
          {hasStripes && (
            <Box flexDirection="column">
              {stripesDrawing}
              <Text dimColor>{dates}</Text>
              <Text dimColor>{`${stripesCaption(w.step, bm, lang)} · ${legendText(lang)}`}</Text>
            </Box>
          )}
          {hasTotals && totals !== null && (
            <Box flexDirection="column">
              <Text bold>{periodHeadline(totals.grams, lang)}</Text>
              {changeText}
              <Text dimColor>{secondary.join(" · ")}</Text>
              {listed.length > 0 && (
                <Box flexDirection="column" marginTop={1}>
                  {listed.map((p) => (
                    <Text key={`project-${p.project}`}>
                      {projectBarLine(p.project, p.share, lang)}
                    </Text>
                  ))}
                  {rest.length > 0 && (
                    <Text dimColor>
                      {otherProjectsLine(
                        rest.length,
                        restGrams,
                        totals.grams > 0 ? restGrams / totals.grams : 0,
                        lang,
                      )}
                    </Text>
                  )}
                </Box>
              )}
            </Box>
          )}
          <Box flexDirection="column" rowGap={1}>
            <Box flexDirection="row" columnGap={1}>
              {cardButton}
              {customizeButton}
            </Box>
            {isCardReady && <Text bold>{cardReadyText(lang)}</Text>}
            {options}
          </Box>
        </Box>
      );
    } catch {
      return next(e);
    }
  });

  on("ui.render", { component: "TurnDuration" }, async ($, e, next) => {
    if (!showPerTurn) return next(e);
    // A line is bound to its turn by its requestId, which stays the same through a
    // resize, a scroll or ctrl+o. A line with no entry (an older turn, a resumed
    // transcript, one first drawn later) is left as the engine draws it.
    let drawnAt = firstDrawn.get(e.requestId);
    if (drawnAt === undefined) {
      drawnAt = await $.clock.now();
      firstDrawn.set(e.requestId, drawnAt);
    }
    const match = lineEntry(await read($, answers), e.requestId, drawnAt, {
      turnOf,
      taken,
    });
    if (match?.isNew) {
      turnOf.set(e.requestId, match.entry.turnId);
      taken.add(match.entry.turnId);
    }
    const co2 = match?.entry.co2;
    if (co2 === undefined || co2 === null) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    const engineLine = await next(e);
    return (
      <Box flexDirection="column">
        {/* The engine's line fills the row and carries a blank row above it: the
            figure sits at the right end of its last row and never moves or wraps
            the engine's own text. */}
        <Box flexDirection="row" alignItems="flex-end">
          <Box flexGrow={1} flexShrink={1}>
            {engineLine}
          </Box>
          <Box flexShrink={0} marginLeft={2}>
            {co2.isUnusual ? (
              <Text color="warning">{co2.main}</Text>
            ) : (
              <Text dimColor>{co2.main}</Text>
            )}
          </Box>
        </Box>
        {co2.sub !== null && (
          <Box justifyContent="flex-end">
            <Text dimColor>{co2.sub}</Text>
          </Box>
        )}
      </Box>
    );
  });
};
