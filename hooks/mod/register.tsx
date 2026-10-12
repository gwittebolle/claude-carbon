// The claude-carbon mod: the CO2 of each Claude Code answer, at the moment the answer ends.
//
// Terminal: at the right end of the turn duration line ("✻ Worked for 4s · done 10:32 PM
// ... 1,1 gCO₂"). Desktop app, where that line is not drawn: a line under the answer, for
// unusual answers only. The session total is pinned under the prompt, unless a status
// line already shows it on this surface (the claude-carbon one, or showSessionTotal
// off). Where no terminal is attached, the pinned session entry also carries the last
// answer's figure.
//
// One request at a time through turn.step, the formula and factors of the bash plugin
// (lib/co2.ts). Writes no database, starts no process, calls no network, never changes
// what Claude does.

import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { AnswerCo2Entry, SessionTotal } from "../../types";
import {
  co2Grams,
  DEFAULT_FACTORS,
  isExcluded,
  parseFactors,
} from "./lib/co2.ts";
import type { Factors } from "./lib/co2.ts";
import {
  answerLine,
  buildAnswerCo2,
  detectLang,
  hasLangVariable,
  isCarbonStatusLine,
  languageSetting,
  pushHistory,
  sessionLine,
  welcomeText,
} from "./lib/format.ts";
import type { Lang } from "./lib/format.ts";
import { lineEntry } from "./lib/lines.ts";

// One entry per main-loop turn, oldest first, uncounted turns included (co2 null) so
// a duration line never borrows another turn's figure (lib/lines.ts).
const answers = atom(
  { plugin: "claude-carbon", key: "answers" } as const,
  [] as AnswerCo2Entry[],
);
const session = atom(
  { plugin: "claude-carbon", key: "session" } as const,
  { grams: 0, turns: 0 } as SessionTotal,
);

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
    { grams: 0, turns: 0 },
  );
  await $.state.set({ plugin: "claude-carbon", key: "answers" }, []);
  $.ui.status(undefined);
}

export const register: Register = (on, options) => {
  const showPerTurn = options.showPerTurn !== false;
  // Off where a status line already shows the total (ccstatusline with the
  // claude-carbon segment): read like the claude-carbon status line, so the
  // desktop app, which draws no status line, keeps it.
  const showSessionTotal = options.showSessionTotal !== false;
  let factors: Factors = DEFAULT_FACTORS;
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
      factors =
        typeof text === "string"
          ? parseFactors(JSON.parse(text))
          : DEFAULT_FACTORS;
    } catch {
      factors = DEFAULT_FACTORS;
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

  on("turn.start", ($, e, next) => {
    // The main loop alone raises turn.start; a subagent's run does not.
    current = openTurn(e.turnId);
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
          await update($, session, (total) => ({
            ...total,
            grams: total.grams + grams,
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
        // The last answer's figure, in place of the duration line; dropped when the
        // answer counted nothing, so a stale figure never stays on screen.
        const last = showPerTurn && remoteOnly && isCounted ? done.grams : null;
        $.ui.status(sessionLine(total.grams, lang, last));
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
