// The claude-carbon mod: the CO2 of each Claude Code answer, at the moment the answer ends.
//
// Terminal: at the right end of the turn duration line ("✻ Worked for 4s · done 10:32 PM
// ... 1,1 gCO₂"). Desktop app, where that line is not drawn: a line under the answer, for
// unusual answers only. The session total is pinned under the prompt, unless the
// claude-carbon status line already shows it on this surface. Where no terminal is
// attached, the pinned session entry also carries the last answer's figure.
//
// One request at a time through turn.step, the formula and factors of the bash plugin
// (lib/co2.ts). Writes no database, calls no network, never changes what Claude does.

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
  formatGrams,
  hasLangVariable,
  isCarbonStatusLine,
  languageSetting,
  median,
  parseSystemLocale,
  pushHistory,
  sessionLine,
  welcomeText,
} from "./lib/format.ts";
import type { Lang } from "./lib/format.ts";

// One entry per main-loop turn, oldest first, uncounted turns included (co2 null) so
// a duration line never borrows another turn's figure.
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
  turns: number;
  steps: number;
  subagentSteps: number;
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
  steps: number;
  subagentSteps: number;
};

function openTurn(turnId: string): OpenTurn {
  return {
    turnId,
    grams: 0,
    subagentGrams: 0,
    spawned: new Set(),
    stepped: new Set(),
    steps: 0,
    subagentSteps: 0,
  };
}

function asNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

// $.store is shared by every session on the machine and has no conditional write: two
// sessions ending a turn at once can lose one value of the history. The median tolerates it.
async function loadHistory($: EngineInterface): Promise<History> {
  const raw = (await $.store.get(HISTORY_KEY)) as Partial<History> | undefined;
  const values = Array.isArray(raw?.values)
    ? raw.values.filter((v): v is number => typeof v === "number" && v > 0)
    : [];
  return {
    values,
    turns: asNumber(raw?.turns),
    steps: asNumber(raw?.steps),
    subagentSteps: asNumber(raw?.subagentSteps),
    welcomed: raw?.welcomed === true,
  };
}

// No terminal draws this session: the duration line never shows here.
function isRemoteOnly(surfaces: readonly string[]): boolean {
  return surfaces.length > 0 && !surfaces.includes("terminal");
}

// The locale the user picked in the system settings, which Desktop and Windows do not
// pass in LANG. Measured under 50 ms on macOS; anything wrong means undefined.
async function systemLocale($: EngineInterface): Promise<string | undefined> {
  const argv =
    (await $.env.get("OS")) === "Windows_NT"
      ? [
          "reg",
          "query",
          "HKCU\\Control Panel\\International",
          "/v",
          "LocaleName",
        ]
      : ["defaults", "read", "-g", "AppleLocale"];
  try {
    const { exitCode, stdout } = await $.process.run(argv, { timeoutMs: 2000 });
    return exitCode === 0 ? parseSystemLocale(stdout) : undefined;
  } catch {
    return undefined;
  }
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
    // Windows session usually set none: then the language setting, then the
    // system's locale, then French.
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
        : (languageSetting(settings.language) ?? (await systemLocale($))),
    );

    try {
      await $.command.register({
        name: "carbon-stats",
        description:
          "Show the median CO2 of your answers and the model requests per prompt",
      });
    } catch {
      // The command is a convenience: the per-answer figure works without it.
    }

    // Once, worded for where the figure shows. A session nothing draws yet is
    // welcomed at its first answer instead.
    const history = await loadHistory($);
    if (!history.welcomed && e.isInteractive) {
      const surfaces = await $.session.surfaces();
      if (surfaces.length > 0) {
        $.ui.toast(welcomeText(lang, isRemoteOnly(surfaces)), {
          timeoutMs: 10000,
        });
        await $.store.set(HISTORY_KEY, { ...history, welcomed: true });
      }
    }

    return next(e);
  });

  on("command.run", { command: "carbon-stats" }, async ($) => {
    const history = await loadHistory($);
    const { value: total } = await $.state.get({
      plugin: "claude-carbon",
      key: "session",
    });
    const fr = lang === "fr";
    const grams = formatGrams(total?.grams ?? 0, lang);
    const lines: string[] = [
      fr ? `Cette session : ${grams}` : `This session: ${grams}`,
    ];
    const n = history.values.length;
    if (n === 0) {
      lines.push(
        fr ? "Pas encore de réponse mesurée." : "No answer measured yet.",
      );
    } else {
      const m = formatGrams(median(history.values), lang);
      lines.push(
        fr
          ? n === 1
            ? `Votre dernière réponse : ${m}`
            : `Médiane de vos ${n} dernières réponses : ${m}`
          : n === 1
            ? `Your last answer: ${m}`
            : `Median of your last ${n} answers: ${m}`,
      );
    }
    if (history.turns > 0) {
      const perPrompt = (history.steps + history.subagentSteps) / history.turns;
      const value = fr
        ? perPrompt.toFixed(1).replace(".", ",")
        : perPrompt.toFixed(1);
      const prompts = history.turns === 1 ? "prompt" : "prompts";
      lines.push(
        fr
          ? `Requêtes au modèle par prompt : ${value} en moyenne sur ${history.turns} ${prompts}`
          : `Model requests per prompt: ${value} on average over ${history.turns} ${prompts}`,
      );
    }
    return { text: lines.join("\n") };
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
            if (agent === undefined) {
              current.steps += 1;
            } else {
              current.subagentSteps += 1;
              // Work the engine runs on its own (a compaction) is in the answer's
              // total but is not named as a subagent.
              if (current.spawned.has(agent)) {
                current.subagentGrams += grams;
                current.stepped.add(agent);
              }
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
    const result = await next(e);
    if (e.agentId !== undefined) return result;
    try {
      // Only the turn that opened the answer closes it.
      const done = current;
      if (done === null || e.turnId !== done.turnId) return result;
      current = null;
      const history = await loadHistory($);
      const isCounted = done.grams > 0;
      const co2 = isCounted
        ? buildAnswerCo2(
            {
              grams: done.grams,
              subagentGrams: done.subagentGrams,
              subagents: done.stepped.size,
            },
            history.values,
            lang,
          )
        : null;
      await update($, answers, (all) =>
        [...all, { durationMs: e.durationMs, co2 }].slice(-KEEP_ANSWERS),
      );
      const surfaces = await $.session.surfaces();
      const remoteOnly = isRemoteOnly(surfaces);
      const isWelcome = !history.welcomed && surfaces.length > 0;
      if (isWelcome) {
        $.ui.toast(welcomeText(lang, remoteOnly), { timeoutMs: 10000 });
      }
      if (isCounted || isWelcome) {
        await $.store.set(HISTORY_KEY, {
          ...history,
          ...(isCounted
            ? {
                values: pushHistory(history.values, done.grams),
                turns: history.turns + 1,
                steps: history.steps + done.steps,
                subagentSteps: history.subagentSteps + done.subagentSteps,
              }
            : {}),
          welcomed: history.welcomed || isWelcome,
        });
      }
      await update($, session, (total) => ({
        ...total,
        turns: total.turns + 1,
      }));
      const { value: total } = await $.state.get({
        plugin: "claude-carbon",
        key: "session",
      });
      // The claude-carbon status line only shows in a terminal.
      if (
        (!hasCarbonStatusLine || remoteOnly) &&
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
    // The duration turn.complete reports is the one the line formats: an exact match,
    // newest first. A line with no entry (an older turn, a resumed transcript) is left
    // as the engine draws it.
    const entries = await read($, answers);
    let co2: AnswerCo2Entry["co2"] | undefined;
    for (let i = entries.length - 1; i >= 0; i -= 1) {
      const entry = entries[i];
      if (entry !== undefined && entry.durationMs === e.props.durationMs) {
        co2 = entry.co2;
        break;
      }
    }
    if (co2 === undefined || co2 === null) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    const engineLine = await next(e);
    return (
      <Box flexDirection="column">
        {/* The engine's line fills the row and carries a blank row above it: the
            figure sits at the right end of its last row, like the total of a bill,
            and never moves or wraps the engine's own text. */}
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
