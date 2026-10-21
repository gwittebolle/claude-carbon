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
import type { EngineInterface, Register, RenderInputOf } from "claude-code";

import type {
  AnswerCo2Entry,
  PaneBlocks,
  PaneView,
  SessionTotal,
} from "../../types";
import {
  co2Grams,
  family,
  DEFAULT_FACTORS,
  isExcluded,
  parseFactors,
} from "./lib/co2.ts";
import type { Factors, Family } from "./lib/co2.ts";
import { costUsd, parsePrices } from "./lib/cost.ts";
import { DETAIL_SVG_HEIGHT, periodDetail, splitBarSvg, swatchSvg } from "./lib/detail.ts";
import type { Prices } from "./lib/cost.ts";
import {
  answerLine,
  builtByLabel,
  REPO_URL,
  repoLabel,
  updateText,
  forTeamLabel,
  AUTHOR_URL,
  datePlaceholder,
  dateInvalid,
  dayInputValue,
  teamUrl,
  apiValueNote,
  blockTitle,
  sessionStatsText,
  changeValue,
  formatGrams,
  moneyValue,
  tileLabel,
  blockLabel,
  detailAlt,
  detailBarLabel,
  detailCoverage,
  detailLine,
  METHODOLOGY_URL,
  methodologyLabel,
  detailHover,
  detailTotalLine,
  detailWaitText,
  kindLabel,
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
  dateLabel,
  detectLang,
  emptyRangeText,
  carValue,
  carTag,
  fromLabel,
  hasLangVariable,
  isCarbonStatusLine,
  languageSetting,
  contextText,
  moreAgentsText,
  subagentsAlt,
  subagentTitle,
  mascotAlt,
  scaleAlt,
  noHistoryText,
  otherProjectsLine,
  paneHint,
  paneTitle,
  paneUnplaced,
  projectBarLine,
  pushHistory,
  quotaText,
  rangeLabel,
  sessionLine,
  showLabel,
  stripesAlt,
  stripesCaption,
  stripesWaitText,
  stripeTitle,
  toLabel,
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
  miniFaceFrame,
  moodOf,
  isStill,
  faceAt,
  REACT_MS,
  SLEEP_AFTER_MS,
  type Mood,
  mascotCells,
  mascotSvg,
  scaleSvg,
  SCALE_WIDTH,
  SCALE_HEIGHT,
  NEUTRAL,
  IDLE_STEP_MS,
  stepMs,
  subagentsSvg,
  STRIPES_SVG_HEIGHT,
  stripesSvg,
} from "./lib/mascot.ts";
import type { Stripe } from "./lib/mascot.ts";
import {
  barMedian,
  bars,
  CURRENT_VERSION,
  DEFAULT_VIEW,
  folderName,
  panelSite,
  historyPath,
  newerRelease,
  updateFlagPath,
  isView,
  dayKey,
  parseDay,
  parseHistory,
  pastSessions,
  periodTotal,
  previousTotal,
  RANGES,
  MIN_STRIPES,
  colourMedian,
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
  { grams: 0, usd: 0, turns: 0, tokens: { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 } } as SessionTotal,
);

const working = atom(
  { plugin: "claude-carbon", key: "working" } as const,
  false,
);
// In a terminal, /carbon-panel shows the molecule in the band above the prompt: a docked
// pane would take a whole column for four lines.
const band = atom(
  { plugin: "claude-carbon", key: "band" } as const,
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
  detail: false,
};
const BLOCKS = ["compare", "cost", "equivalence", "projects", "detail"] as const;
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
// The pane's settings control: a gear (U+2699, text presentation)
const GEAR = "\u2699";
// The most stripes drawn, the most recent kept: in the desktop app few enough to stay
// readable in a side pane (and far under the Svg's 131072 characters), in a terminal
// what the line holds, up to a Raster's 512 columns.
const DESKTOP_MAX_STRIPES = 180;
// The subagent molecules shown under the big one before "+N"
const MAX_AGENT_MOLECULES = 8;
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
    { grams: 0, usd: 0, turns: 0, tokens: { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 } },
  );
  await $.state.set({ plugin: "claude-carbon", key: "answers" }, []);
  $.ui.status(undefined);
  pane.subagents = 0;
  pane.agents = new Map();
  pane.sessionFamily = null;
  // The pane follows the new conversation: its id is read again at the next drawing, and
  // the history with it, where the conversation before is now a past session
  pane.sessionId = null;
  pane.rows = undefined;
  pane.mood = null;
  pane.lastActive = 0;
  pane.reactUntil = 0;
}

// The pane. Where the history file is, this session's id (its own row in the file holds
// a partial total), and the history as last read: undefined until read, null when there
// is no file to read (no database: an install without the bash hooks). The walk in the
// terminal: the timer that steps it; the picture follows the clock, so a redraw for
// another reason (a new request's total) keeps the step.
const pane: {
  historyFile: string | null;
  // The daily release check's flag, the running plugin's version, and the newer release
  // the foot names (null when there is none)
  updateFile: string | null;
  ownVersion: string | null;
  newer: string | null;
  sessionId: string | null;
  rows: SessionRow[] | null | undefined;
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
  // The tile whose note is open, by its (i)
  openNote: string | null;
  // The running session as the pane tells it: subagents started, the family of the last
  // model that answered
  subagents: number;
  // Each subagent started this session, in order, and the CO2 of its requests
  agents: Map<string, number>;
  sessionFamily: Family | null;
  // The molecule's mood, since when (its faces loop from there), the last turn's start
  // or end, and until when it reacts to the last answer (ms)
  mood: Mood | null;
  moodSince: number;
  // The band's site, as its last drawing named it: where the walk blits
  bandRequestId: string | null;
  lastActive: number;
  reactUntil: number;
} = {
  historyFile: null,
  updateFile: null,
  ownVersion: null,
  newer: null,
  sessionId: null,
  rows: undefined,
  walkTimer: null,
  walkRun: 0,
  project: "",
  cardReadyUntil: 0,
  customizing: false,
  openNote: null,
  subagents: 0,
  agents: new Map<string, number>(),
  sessionFamily: null,
  mood: null,
  moodSince: 0,
  bandRequestId: null,
  lastActive: 0,
  reactUntil: 0,
};

async function loadPaneHistory($: EngineInterface) {
  pane.newer = null;
  if (pane.updateFile !== null) {
    try {
      const flag = await $.fs.read(pane.updateFile);
      if (typeof flag === "string")
        pane.newer = newerRelease(flag, pane.ownVersion, await $.clock.now());
    } catch {
      pane.newer = null;
    }
  }
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

// The molecule's class (this session against the median of past sessions, null without
// enough of them) and mood. A new mood starts its faces from the first.
async function moleculeNow(
  $: EngineInterface,
  now: number,
): Promise<{ cls: number | null; mood: Mood; isWorking: boolean }> {
  const total = await read($, session);
  const isWorking = await read($, working);
  const m = colourMedian(pastSessions(pane.rows ?? [], pane.sessionId));
  // Grey, as drawn, until this session counts something
  const cls = !(total.grams > 0) ? null : classOf(total.grams, m);
  if (pane.lastActive === 0) pane.lastActive = now;
  const mood = moodOf({
    working: isWorking,
    cls,
    hasAnswer: total.turns > 0,
    idleMs: now - pane.lastActive,
    reacting: now < pane.reactUntil,
  });
  if (mood !== pane.mood) {
    pane.mood = mood;
    pane.moodSince = now;
  }
  return { cls, mood, isWorking };
}

// The terminal's molecule at `now`: its hop, at the pace of its colour while a turn runs
// and a slow breath at rest, and its face; with how long that picture holds.
function terminalMolecule(
  now: number,
  mood: Mood,
  cls: number | null,
  isWorking: boolean,
): { frame: string[]; holdMs: number } {
  const pace = isWorking ? stepMs(cls ?? NEUTRAL_CLASS) : IDLE_STEP_MS;
  const hop = isStill(mood) || Math.floor(now / pace) % 2 === 0 ? 0 : 1;
  const { face, holdMs } = faceAt(mood, now - pane.moodSince);
  return {
    frame: miniFaceFrame(hop, face),
    holdMs: Math.min(pace - (now % pace), holdMs),
  };
}

// The terminal's whole drawing: this session beside its small molecule, a few rows. In
// the band above the prompt, or in a pane the desktop app opened on a session the
// terminal shows too.
async function terminalSession(
  $: EngineInterface,
  e: RenderInputOf<"AbovePrompt", "terminal"> | RenderInputOf<"Pane", "terminal">,
  lang: Lang,
) {
  if (pane.rows === undefined) await loadPaneHistory($);
  if (pane.sessionId === null) pane.sessionId = await $.session.id().catch(() => null);
  const total = await read($, session);
  const now = await $.clock.now();
  const past = pastSessions(pane.rows ?? [], pane.sessionId);
  const sm = sessionMedian(past);
  const cm = colourMedian(past);
  const { cls, mood, isWorking } = await moleculeNow($, now);
  const color = colorOf(cls);
  // A dot per subagent in its molecule's colour, eight then "+N"
  const agents = [...pane.agents.values()];
  const dots = agents
    .slice(0, MAX_AGENT_MOLECULES)
    .map((grams) => (!(grams > 0) ? NEUTRAL : colorOf(classOf(grams, cm))));
  const more = agents.length - dots.length;
  // The context window's fill and the session's API-price value, as the status line
  // has them
  const contextUsed = await $.session
    .usage()
    .then((u) => u.context.percent ?? null)
    .catch(() => null);
  const meta = [
    ...(contextUsed !== null ? [contextText(contextUsed, lang)] : []),
    ...(total.usd !== undefined && total.usd > 0 ? [costText(total.usd, lang)] : []),
  ].join(" · ");
  const ui = $.ui.resolve(e);
  const { Box, Text } = ui;
  return (
    <Box flexDirection="row">
      <ui.Raster
        key="mascot"
        columns={CELL_COLUMNS}
        rows={CELL_ROWS}
        cells={mascotCells(terminalMolecule(now, mood, cls, isWorking).frame, color)}
      />
      <Box flexDirection="column" marginLeft={2} flexShrink={1}>
        <Text bold>
          {total.grams > 0 ? currentLine(total.grams, sm, lang) : waitingText(lang)}
        </Text>
        {total.turns > 0 && (
          <Text dimColor>
            {sessionStatsText(total.turns, pane.subagents, pane.sessionFamily, lang)}
          </Text>
        )}
        {dots.length > 0 && (
          <Box flexDirection="row" columnGap={1}>
            {dots.map((dot, i) => (
              <Text key={`agent-${i}`} color={dot}>
                ●
              </Text>
            ))}
            {more > 0 && <Text dimColor>{moreAgentsText(more)}</Text>}
          </Box>
        )}
        {meta !== "" && <Text dimColor>{meta}</Text>}
        {/* No history file, or a reference until there is a median of one's own */}
        {pane.rows === null ? (
          <Text dimColor>{noHistoryText(lang)}</Text>
        ) : (
          sm === null && <Text dimColor>{colorNote(past.length, lang)}</Text>
        )}
      </Box>
    </Box>
  );
}

// The kept choice over the defaults: a block added since it was kept takes its default.
// Null when nothing usable was kept.
function keptBlocksOf(value: unknown): PaneBlocks | null {
  if (typeof value !== "object" || value === null) return null;
  const v = value as Partial<Record<string, unknown>>;
  const out: PaneBlocks = { ...DEFAULT_BLOCKS };
  let isAny = false;
  for (const block of BLOCKS) {
    const kept = v[block];
    if (typeof kept === "boolean") {
      out[block] = kept;
      isAny = true;
    }
  }
  return isAny ? out : null;
}

function stopWalk() {
  pane.walkTimer?.cancel();
  pane.walkTimer = null;
  pane.walkRun += 1;
}

// One step of the terminal's molecule while the pane is open: a blit of the next frame,
// no redraw, then the next step, at the pace of the current colour while a turn runs and
// a slow breath at rest. A blit the surface refuses (the pane in a hidden tab) is left be.
// Each await may see the walk stopped or restarted: the step then ends without drawing.
async function walkStep($: EngineInterface, run: number) {
  const isCurrent = () => run === pane.walkRun;
  try {
    const surfaces = await $.session.surfaces();
    const isBand = await read($, band);
    const isPane = await isPaneOpen($);
    const goOn = surfaces.includes("terminal") && (isBand || isPane);
    const isWorking = await read($, working);
    if (!isCurrent()) return;
    if (!goOn) {
      stopWalk();
      return;
    }
    const now = await $.clock.now();
    const { cls, mood } = await moleculeNow($, now);
    if (!isCurrent()) return;
    const shown = terminalMolecule(now, mood, cls, isWorking);
    const cells = mascotCells(shown.frame, colorOf(cls));
    const sites = [
      ...(isPane ? [PANE_ID] : []),
      ...(isBand && pane.bandRequestId !== null ? [pane.bandRequestId] : []),
    ];
    for (const requestId of sites)
      await $.ui
        .blit({ requestId, key: "mascot", cells, columns: CELL_COLUMNS, rows: CELL_ROWS })
        .catch(() => undefined);
    if (!isCurrent()) return;
    pane.walkTimer = $.clock.after(Math.max(40, shown.holdMs), () => {
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
  pane.walkTimer = $.clock.after(IDLE_STEP_MS, () => {
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
    try {
      const text = await $.fs.read(`${$.plugin.root}/.claude-plugin/plugin.json`);
      const version: unknown =
        typeof text === "string" ? JSON.parse(text)?.version : undefined;
      pane.ownVersion = typeof version === "string" ? version : null;
    } catch {
      pane.ownVersion = null;
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
      // The same opt-out as the status line's hint
      const noNotice = await $.env.get("CLAUDE_CARBON_NO_UPDATE_NOTIFIER");
      pane.updateFile =
        noNotice !== undefined && noNotice !== ""
          ? null
          : updateFlagPath({
              configDir: await $.env.get("CLAUDE_CONFIG_DIR"),
              home: await $.env.get("HOME"),
              userProfile: await $.env.get("USERPROFILE"),
            });
      pane.sessionId = await $.session.id().catch(() => null);
      pane.project = folderName(e.cwd ?? "");
      pane.subagents = 0;
      pane.agents = new Map();
      pane.sessionFamily = null;
      pane.rows = undefined;
      pane.mood = null;
      pane.lastActive = 0;
      pane.reactUntil = 0;
      stopWalk();
      pane.bandRequestId = null;
      await $.state.set({ plugin: "claude-carbon", key: "working" }, false);
      await $.state.set({ plugin: "claude-carbon", key: "band" }, false);
      const kept = await $.store.get(VIEW_KEY);
      if (isView(kept)) {
        await $.state.set({ plugin: "claude-carbon", key: "view" }, kept);
      }
      const keptBlocks = keptBlocksOf(await $.store.get(BLOCKS_KEY));
      if (keptBlocks !== null) {
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
      pane.subagents += 1;
      pane.agents.set(id, 0);
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
      pane.lastActive = await $.clock.now();
      await $.state.set({ plugin: "claude-carbon", key: "working" }, true);
      if ((await read($, band)) || (await isPaneOpen($))) ensureWalk($);
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
          pane.sessionFamily = family(model);
          if (e.agentId !== undefined && pane.agents.has(e.agentId))
            pane.agents.set(e.agentId, (pane.agents.get(e.agentId) ?? 0) + grams);
          const usd = prices !== null ? costUsd(usage, model, prices) : null;
          await update($, session, ({ usd: spent, tokens: seen, ...total }) => ({
            ...total,
            grams: total.grams + grams,
            // Counted from the first request of the session on; a total kept without
            // them stays without them until it starts over
            ...(seen !== undefined
              ? {
                  tokens: {
                    input: seen.input + usage.input_tokens,
                    cacheWrite: seen.cacheWrite + usage.cache_creation_input_tokens,
                    cacheRead: seen.cacheRead + usage.cache_read_input_tokens,
                    output: seen.output + usage.output_tokens,
                  },
                }
              : {}),
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
    // open answer, and the molecule must still slow down (its next step reads `working`).
    // The Stop hook writes the history again after this answer, other sessions running at
    // the same time included: the pane's next drawing reads it again (and finds it, when
    // an update installed in this very session had none yet).
    pane.rows = undefined;
    try {
      await $.state.set({ plugin: "claude-carbon", key: "working" }, false);
    } catch {
      // The next session start sets it again.
    }
    // The molecule reacts to the answer, then falls asleep if nothing follows. On the
    // desktop nothing else redraws it at those two moments.
    try {
      const now = await $.clock.now();
      pane.lastActive = now;
      pane.reactUntil = now + REACT_MS;
      if (await isPaneOpen($)) {
        $.clock.after(REACT_MS, () => $.ui.invalidate("ui.render"));
        $.clock.after(SLEEP_AFTER_MS, () => $.ui.invalidate("ui.render"));
      }
    } catch {
      // It keeps its face until the next drawing.
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
        // The 5-hour quota the status line also shows, from the engine's own reading
        const quota = await $.session
          .usage()
          .then((u) => quotaText(u.rateLimits, lang))
          .catch(() => null);
        $.ui.status(sessionLine(total.grams, lang, total.usd ?? null, quota));
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
  // the pane has nothing to type into, and Escape must still interrupt a turn. The
  // command is also a skill of the plugin (skills/carbon-panel), so the desktop app lists
  // it: its plugin spelling is caught here too, and its text never reaches the model.
  on("command.run", { command: [COMMAND, `claude-carbon:${COMMAND}`] }, async ($, e) => {
    try {
      // Typed in a terminal, the molecule shows in the band above the prompt, on and off:
      // a pane would dock as a whole column in fullscreen rendering, for four lines.
      // Sent from the desktop app or a phone, it opens the side pane there.
      const surfaces = await $.session.surfaces();
      if (panelSite(surfaces, e.origin?.kind ?? "") === "band") {
        const isOn = !(await read($, band));
        if (isOn) {
          pane.rows = undefined;
          await loadPaneHistory($);
        } else {
          stopWalk();
        }
        await $.state.set({ plugin: "claude-carbon", key: "band" }, isOn);
        if (isOn) ensureWalk($);
        return {};
      }
      if (await isPaneOpen($)) {
        stopWalk();
        await $.ui.close({ id: PANE_ID });
        return {};
      }
      pane.rows = undefined;
      await loadPaneHistory($);
      // The desktop app's side pane
      const opened = await $.ui.open({
        id: PANE_ID,
        title: paneTitle(lang),
        closeOnEscape: true,
      });
      if (!opened.isPlaced) {
        $.ui.toast(paneUnplaced(lang), { timeoutMs: 8000 });
      } else {
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

  // The band above a terminal's prompt, while /carbon-panel has it on: the session beside
  // its molecule, over whatever else the band holds. A survey has the band to itself.
  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    try {
      if (e.surface !== "terminal" || e.props.hasSurvey || !(await read($, band)))
        return next(e);
      pane.bandRequestId = e.requestId;
      const ours = await terminalSession($, e, lang);
      const below = await next(e);
      if (below === null || below === undefined) return ours;
      const { Box } = $.ui.resolve(e);
      return (
        <Box flexDirection="column">
          {ours}
          {below}
        </Box>
      );
    } catch {
      return next(e);
    }
  });

  on("ui.render", { component: "Pane", requestId: PANE_ID }, async ($, e, next) => {
    try {
      if (e.surface === "terminal") return await terminalSession($, e, lang);
      if (pane.rows === undefined) await loadPaneHistory($);
      if (pane.sessionId === null)
        pane.sessionId = await $.session.id().catch(() => null);
      const total = await read($, session);
      const isWorking = await read($, working);
      const view = await read($, paneView);
      const now = await $.clock.now();
      const past = pastSessions(pane.rows ?? [], pane.sessionId);
      const sm = sessionMedian(past);
      const cm = colourMedian(past);
      // Grey until this session has counted something
      const cls = !(total.grams > 0) ? null : classOf(total.grams, cm);
      const color = colorOf(cls);
      const { mood } = await moleculeNow($, now);
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
              model: own?.model ?? "",
              // The running session's tokens counted live, or as the file last saw them
              tokens: total.tokens ?? own?.tokens ?? null,
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
      // A window longer than the room (years by month) keeps its most recent periods
      const shown = list.slice(-DESKTOP_MAX_STRIPES);
      const stripes: Stripe[] = shown.map((b) => ({
        color: b.grams > 0 ? (bm === null ? NEUTRAL : colorOf(classOf(b.grams, bm))) : null,
        title: stripeTitle(b.start, w.step, b.grams, b.sessions, lang),
        start: b.start,
      }));
      const blocks = await read($, paneBlocks);
      const setView = (chosen: PaneView) => {
        void (async () => {
          await $.state.set({ plugin: "claude-carbon", key: "view" }, chosen);
          await $.store.set(VIEW_KEY, chosen);
        })().catch(() => undefined);
      };

      const ui = $.ui.resolve(e);
      const { Box, Text, Button } = ui;
      // The molecule, and under it the colour scale with this session's place on it
      const mascot = (
        <Box flexDirection="column" alignItems="center">
          <ui.Svg
            source={mascotSvg({
              color,
              walking: isWorking,
              step: stepMs(cls ?? NEUTRAL_CLASS),
              title: mascotAlt(lang),
              mood,
            })}
            alt={mascotAlt(lang)}
            width={112}
            height={90}
            isInteractive
          />
          <ui.Svg
            source={scaleSvg(cls)}
            alt={scaleAlt(cls, lang)}
            width={SCALE_WIDTH}
            height={SCALE_HEIGHT}
          />
        </Box>
      );
      // The chosen button in the app's main style, the others dim
      const choice = (isChosen: boolean) =>
        isChosen ? { variant: "primary" as const } : { dimColor: true };
      const sessionText = total.grams > 0 ? currentLine(total.grams, sm, lang) : waitingText(lang);
      const hasStripes = pane.rows !== null && stripes.length > 0;
      // Periods with sessions in them: below three, the stripes say they are coming
      const filledStripes = shown.filter((b) => b.sessions > 0).length;
      const withYear = w.end - w.start > 300 * 86_400_000;
      const firstShown = shown[0];
      const dates =
        firstShown === undefined
          ? ""
          : `${dateLabel(Math.max(w.start, firstShown.start), w.step, lang, withYear)} → ${dateLabel(w.end, w.step, lang, withYear)}`;

      const rangeButtons = RANGES.map((range) => (
        <Button
          key={`range-${range}`}
          label={rangeLabel(range, lang)}
          {...choice(view.range === range)}
          onPress={() => {
            if (range !== "custom") return setView({ range });
            // A custom range opens on the last 30 days, then the fields move it
            setView({
              range,
              from: view.from ?? dayKey(now - 29 * 86_400_000),
              to: view.to ?? dayKey(now),
            });
          }}
        />
      ));
      // The custom range: two dates typed, read at Enter. The mods API has no calendar:
      // a field takes the day first ("01/05/2026") or as 2026-05-01. A start after the
      // end swaps them.
      const setDay = (field: "from" | "to", typed: string) => {
        const key = parseDay(typed);
        if (key === null) {
          $.ui.toast(dateInvalid(lang), { timeoutMs: 6000 });
          return;
        }
        const from = field === "from" ? key : (view.from ?? key);
        const to = field === "to" ? key : (view.to ?? key);
        setView({ range: "custom", from: from <= to ? from : to, to: from <= to ? to : from });
      };
      // A phone has no text field (Remote Control): the two dates show as text there.
      const customRange =
        view.range === "custom" &&
        ("Input" in ui ? (
          <Box flexDirection="row" columnGap={1} flexWrap="wrap" alignItems="center">
            <ui.Input
              key="from"
              label={fromLabel(lang)}
              placeholder={datePlaceholder(lang)}
              value={view.from !== undefined ? dayInputValue(view.from) : ""}
              submitLabel="ok"
              onSubmit={(value: string) => setDay("from", value)}
            />
            <ui.Input
              key="to"
              label={toLabel(lang)}
              placeholder={datePlaceholder(lang)}
              value={view.to !== undefined ? dayInputValue(view.to) : ""}
              submitLabel="ok"
              onSubmit={(value: string) => setDay("to", value)}
            />
          </Box>
        ) : (
          <Text dimColor>
            {`${dayInputValue(view.from ?? dayKey(now))} → ${dayInputValue(view.to ?? dayKey(now))}`}
          </Text>
        ));

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
          label={cardButtonLabel(new Date(now).getFullYear(), lang)}
          variant="primary"
          onPress={prepareCard}
        />
      );

      // The drawing's width in CSS pixels, from the pane's columns
      const stripesWidth = Math.min(720, Math.max(200, e.props.bodyColumns * 8));
      const stripesDrawing = (
        <ui.Svg
          source={stripesSvg(stripes, stripesAlt(lang), stripesWidth)}
          alt={stripesAlt(lang)}
          width={stripesWidth}
          height={STRIPES_SVG_HEIGHT}
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
      const listed = blocks.projects ? (totals?.projects.slice(0, 5) ?? []) : [];
      const rest = blocks.projects ? (totals?.projects.slice(5) ?? []) : [];
      const restGrams = rest.reduce((s, p) => s + p.grams, 0);

      const setBlocks = (chosen: PaneBlocks) => {
        void (async () => {
          await $.state.set({ plugin: "claude-carbon", key: "blocks" }, chosen);
          await $.store.set(BLOCKS_KEY, chosen);
        })().catch(() => undefined);
      };
      const customizeButton = (
        <Button
          key="customize"
          // A gear, a control by itself: the block switches of "Mon usage"
          label={GEAR}
          plain
          {...(pane.customizing ? {} : { dimColor: true })}
          onPress={() => {
            pane.customizing = !pane.customizing;
            $.ui.invalidate("ui.render");
          }}
        />
      );
      const options = pane.customizing && (
        <Box flexDirection="row" columnGap={1} rowGap={1} flexWrap="wrap" alignItems="center">
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
      // A tile of the desktop pane: a dim label over a bold figure, in a rounded frame.
      // A tile with a note has an (i) button: a click shows the note under the tiles, a
      // second hides it. (A hover reveal did not reach the desktop app.)
      const toggleNote = (kind: string) => {
        pane.openNote = pane.openNote === kind ? null : kind;
        $.ui.invalidate("ui.render");
      };
      const tile = (
        kind: string,
        value: string,
        color?: "success" | "error",
        note?: string,
      ) => (
        <Box
          key={`tile-${kind}`}
          borderStyle="round"
          paddingX={1}
          flexDirection="column"
          flexGrow={1}
        >
          <Box flexDirection="row" columnGap={1} alignItems="center">
            <Text dimColor>{tileLabel(kind, lang)}</Text>
            {note !== undefined && (
              <Button
                key={`note-${kind}`}
                label={"\u24d8"}
                plain
                {...(pane.openNote === kind ? {} : { dimColor: true })}
                onPress={() => toggleNote(kind)}
              />
            )}
          </Box>
          <Text bold {...(color !== undefined ? { color } : {})}>
            {value}
          </Text>
        </Box>
      );
      // A tile's note, shown while its (i) is open
      const tileNote = (kind: string, text: string) =>
        pane.openNote === kind && <Text key={`note-text-${kind}`} dimColor>{text}</Text>;
      // The session's subagents as small molecules, each coloured by its CO2 against the
      // median of past sessions (the starting reference before one): at most eight, then "+N"
      const agentList = [...pane.agents.values()];
      const shownAgents = agentList.slice(0, MAX_AGENT_MOLECULES).map((grams, i) => ({
        color: !(grams > 0) ? NEUTRAL : colorOf(classOf(grams, cm)),
        title: subagentTitle(i + 1, grams, lang),
      }));
      const moreAgents = agentList.length - shownAgents.length;
      const sessionStats =
        total.turns > 0
          ? sessionStatsText(total.turns, pane.subagents, pane.sessionFamily, lang)
          : null;
      // The context window's fill and the session's API-price value, as the status line
      // has them
      const contextUsed = await $.session
        .usage()
        .then((u) => u.context.percent ?? null)
        .catch(() => null);
      const sessionMeta = [
        ...(contextUsed !== null ? [contextText(contextUsed, lang)] : []),
        ...(total.usd !== undefined && total.usd > 0 ? [costText(total.usd, lang)] : []),
      ].join(" · ");
      const noHistory = pane.rows === null && <Text dimColor>{noHistoryText(lang)}</Text>;
      const empty =
        pane.rows !== null && !hasTotals && <Text dimColor>{emptyRangeText(lang)}</Text>;

      // The heaviest projects with their share and CO2, then the rest in one line
      const projectsList = hasTotals && totals !== null && listed.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          {listed.map((p) => (
            <Text key={`project-${p.project}`}>
              {projectBarLine(p.project, p.grams, p.share, lang)}
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
      );
      // The period's tokens, energy and CO2 by kind, when the person asked for it: two
      // stacked bars (tokens, then CO2 and energy, whose shares are the same), then a
      // line per kind under its colour key
      const detail =
        blocks.detail && hasTotals && pane.rows !== null ? periodDetail(rows, w, factors) : null;
      const detailBar = (bar: "tokens" | "co2") =>
        detail !== null && (
          <Box flexDirection="column">
            <Text dimColor>{detailBarLabel(bar, lang)}</Text>
            <ui.Svg
              source={splitBarSvg(
                detail.parts.map((p) => (bar === "tokens" ? p.tokenShare : p.gramShare)),
                detail.parts.map((p) => detailHover(p, bar, lang)),
                stripesWidth,
                `detail-${bar}`,
              )}
              alt={detailAlt(bar, lang)}
              width={stripesWidth}
              height={DETAIL_SVG_HEIGHT}
              isInteractive
            />
          </Box>
        );
      const detailBlock =
        blocks.detail && hasTotals && (
          <Box flexDirection="column" rowGap={1} marginTop={1}>
            <Text bold>{blockLabel("detail", lang)}</Text>
            {detail === null ? (
              <Text dimColor>{detailWaitText(lang)}</Text>
            ) : (
              <Box flexDirection="column" rowGap={1}>
                {detailBar("tokens")}
                {detailBar("co2")}
                <Box flexDirection="column">
                  {detail.parts.map((p, i) => p.tokens > 0 && (
                    // A kind with no token says nothing; the others keep their colour
                    <Box key={`detail-${p.kind}`} flexDirection="column">
                      <Box flexDirection="row" columnGap={1} alignItems="center">
                        <ui.Svg source={swatchSvg(i)} alt={kindLabel(p.kind, lang)} width={10} height={10} />
                        <Text bold>{kindLabel(p.kind, lang)}</Text>
                      </Box>
                      <Text dimColor>{detailLine(p, lang)}</Text>
                    </Box>
                  ))}
                </Box>
                <Text>{detailTotalLine(detail, lang)}</Text>
                {detail.sessions < detail.sessionsInPeriod && (
                  <Text dimColor>{detailCoverage(detail.sessions, detail.sessionsInPeriod, lang)}</Text>
                )}
                <ui.Link href={METHODOLOGY_URL} label={methodologyLabel(lang)} />
              </Box>
            )}
          </Box>
        );
      // Mods set no font size: the foot stays small by saying little
      const foot = (
        <Box flexDirection="column" marginTop={1}>
          {pane.newer !== null && <Text>{updateText(pane.newer, lang)}</Text>}
          <ui.Link href={REPO_URL} label={repoLabel(lang)} />
          <Box flexDirection="row" columnGap={1} flexWrap="wrap">
            <Text dimColor>{builtByLabel(lang)}</Text>
            <ui.Link href={AUTHOR_URL} label="Gaëtan Wittebolle" />
          </Box>
          <Box flexDirection="row" columnGap={1} flexWrap="wrap">
            <Text dimColor>{forTeamLabel(lang)}</Text>
            <ui.Link href={teamUrl(lang)} label="TokenClimate" />
          </Box>
        </Box>
      );

      return (
        // The whole height of the side pane, the links held at its foot whatever shows
        // above them. A percentage does not reach the desktop's layout: the height is
        // the rows the surface gives the pane's body.
        <Box
          flexDirection="column"
          minHeight={Math.max(1, e.props.scroll.bodyRows)}
          justifyContent="space-between"
          rowGap={1}
        >
        <Box flexDirection="column" rowGap={1}>
          <Box flexDirection="row" alignItems="center">
            {mascot}
            <Box flexDirection="column" marginLeft={2} flexShrink={1}>
              <Text bold>{sessionText}</Text>
              {sessionStats !== null && <Text dimColor>{sessionStats}</Text>}
              {sessionMeta !== "" && <Text dimColor>{sessionMeta}</Text>}
              {sm === null && <Text dimColor>{colorNote(past.length, lang)}</Text>}
            </Box>
          </Box>
          {shownAgents.length > 0 && (
            <Box flexDirection="row" alignItems="center" columnGap={1}>
              <ui.Svg
                source={subagentsSvg(shownAgents, {
                  walking: isWorking,
                  step: stepMs(cls ?? NEUTRAL_CLASS),
                })}
                alt={subagentsAlt(agentList.length, lang)}
                width={shownAgents.length * 66 - 6}
                height={48}
                isInteractive
              />
              {moreAgents > 0 && <Text dimColor>{moreAgentsText(moreAgents)}</Text>}
            </Box>
          )}
          <Box flexDirection="column" rowGap={1} marginTop={1}>
            <Box flexDirection="row" justifyContent="space-between" alignItems="center">
              <Text bold>{blockTitle("usage", lang)}</Text>
              {customizeButton}
            </Box>
            {options}
            <Box flexDirection="row" columnGap={1} rowGap={1} flexWrap="wrap">
              {rangeButtons}
            </Box>
            {customRange}
          </Box>
          {hasTotals && totals !== null && (
            // The period's figures as tiles, the pane's main reading
            <Box flexDirection="column" rowGap={1}>
              <Box flexDirection="row" columnGap={1} rowGap={1} flexWrap="wrap">
                {tile("period", formatGrams(totals.grams, lang))}
                {blocks.compare && delta !== null && previous !== null && change !== null &&
                  tile("change", changeValue(delta), delta > 0 ? "error" : delta < 0 ? "success" : undefined)}
                {tile("sessions", String(totals.sessions))}
                {blocks.cost && totals.usd !== null && totals.usd > 0 &&
                  tile("cost", moneyValue(totals.usd, lang), undefined, apiValueNote(lang))}
                {blocks.equivalence && car !== null &&
                  tile("car", carValue(totals.grams, car, lang), undefined, carTag(car.tag))}
              </Box>
              {blocks.cost && totals.usd !== null && totals.usd > 0 && tileNote("cost", apiValueNote(lang))}
              {blocks.equivalence && car !== null && tileNote("car", carTag(car.tag))}
            </Box>
          )}
          {noHistory}
          {empty}
          {hasStripes && filledStripes < MIN_STRIPES && (
            <Text dimColor>{stripesWaitText(w.step, filledStripes, lang)}</Text>
          )}
          {hasStripes && filledStripes >= MIN_STRIPES && (
            // The desktop app does not space an Svg from its siblings: a margin above it,
            // the dates right under it
            <Box flexDirection="column" marginTop={1}>
              {stripesDrawing}
              <Text dimColor>{dates}</Text>
              <Text dimColor>{stripesCaption(w.step, bm, lang)}</Text>
            </Box>
          )}
          {projectsList}
          {detailBlock}
          <Box flexDirection="column" rowGap={1}>
            <Box flexDirection="row">{cardButton}</Box>
            {isCardReady && <Text bold>{cardReadyText(lang)}</Text>}
          </Box>
        </Box>
          {foot}
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
