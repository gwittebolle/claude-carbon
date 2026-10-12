import { describe, expect, mock, test } from "claude-code/testing";

const PLUGIN = "claude-carbon";
const NBSP = " ";

const FACTORS = JSON.stringify({
  models: {
    fable: { input: 156, output: 3304 },
    opus: { input: 78, output: 1652 },
    sonnet: { input: 39, output: 826 },
    haiku: { input: 20, output: 413 },
  },
  cache_read_factor: 0.08,
  exclude_models: [],
});

type Step = {
  model: string;
  input?: number;
  cacheWrite?: number;
  cacheRead?: number;
  output?: number;
  agentId?: string;
};

type World = {
  // Read at each call: a test can attach a surface after the session started
  surfaces?: string[];
  // LANG; null leaves every locale variable unset, as the desktop app does
  lang?: string | null;
  // The `language` setting, free text
  language?: string;
  // What the system's locale command prints; unset, the command cannot run
  systemLocale?: string;
  os?: string;
  statusLine?: string;
  history?: number[];
  // Values under the v1 key, which counted background subagents in the answer
  legacyHistory?: number[];
  welcomed?: boolean;
};

const storedHistory = (values: number[], welcomed: boolean) => ({
  values,
  turns: values.length,
  steps: values.length,
  subagentSteps: 0,
  welcomed,
});

// The time the mod reads; a turn moves it on by its duration.
let clock: any;

// The engine beneath the plugin: each noun the mod calls, answered as a session would.
// A mods API call answers { value } (or { deny }).
function world(on: any, options: World = {}) {
  clock = mock.clock(on, { now: 1_000_000 });
  const statuses: Array<string | undefined> = [];
  const toasts: string[] = [];
  const commands: string[][] = [];
  const welcomed = options.welcomed ?? true;
  mock.store(on, {
    "history.v2": storedHistory(options.history ?? [], welcomed),
    ...(options.legacyHistory === undefined
      ? {}
      : { history: storedHistory(options.legacyHistory, true) }),
  });
  mock.env(on, {
    ...(options.lang === null ? {} : { LANG: options.lang ?? "fr_FR.UTF-8" }),
    ...(options.os === undefined ? {} : { OS: options.os }),
  });
  on("process.run", ($: any, e: any) => {
    commands.push([...e.argv]);
    return options.systemLocale === undefined
      ? { deny: "cannot start" }
      : { value: { exitCode: 0, stdout: options.systemLocale, stderr: "" } };
  });
  on("fs.read", () => ({ value: FACTORS }));
  on("settings.read", () => ({
    value: {
      ...(options.statusLine
        ? { statusLine: { type: "command", command: options.statusLine } }
        : {}),
      ...(options.language === undefined ? {} : { language: options.language }),
    },
  }));
  on("session.surfaces", () => ({ value: options.surfaces ?? ["terminal"] }));
  on("command.register", ($: any, e: any) => ({ value: { command: e.name } }));
  on("ui.status", ($: any, e: any) => {
    statuses.push(e.text);
    return { value: undefined };
  });
  on("ui.toast", ($: any, e: any) => {
    toasts.push(e.text);
    return { value: undefined };
  });
  // The engine's own duration line, which the mod's hook wraps.
  on("ui.render", { component: "TurnDuration" }, ($inner: any, e: any) => {
    const { Text } = $inner.ui.resolve(e);
    return <Text dimColor>✻ Baked for 38s</Text>;
  });
  on("agent.spawn", ($: any, e: any) => ({
    model: "claude-haiku-5-5",
    agentId: e.description,
  }));
  // An Agent call that returns while its agent runs on: started in the background,
  // or sent there with ctrl+b.
  on("tool.call", { tool: "Agent" }, ($: any, e: any) => ({
    result: {
      isAsync: true,
      status: "async_launched",
      agentId: e.description,
    },
  }));
  on("session.start", ($: any, e: any) => ({ cwd: e.cwd }));
  on("session.end", ($: any, e: any) => ({ sessionId: e.sessionId }));
  on("turn.start", ($: any, e: any) => ({ turnId: e.turnId }));
  on("turn.complete", ($: any, e: any) => ({ text: e.answer }));
  return { statuses, toasts, commands };
}

let queue: Step[] = [];
let turns = 0;

function engineSteps(on: any) {
  on("turn.step", async function* ($: any, e: any) {
    const step = queue.shift();
    return {
      turnId: e.turnId,
      index: e.index,
      answer: "",
      toolUses: [],
      stopReason: "end_turn",
      usage:
        step === undefined
          ? null
          : {
              model: step.model,
              input_tokens: step.input ?? 0,
              cache_creation_input_tokens: step.cacheWrite ?? 0,
              cache_read_input_tokens: step.cacheRead ?? 0,
              output_tokens: step.output ?? 0,
            },
    };
  });
}

async function startSession($: any, isInteractive = true) {
  await $.session.start({
    cwd: "/tmp/project",
    surface: isInteractive ? "terminal" : null,
    isInteractive,
  });
}

async function spawn(
  $: any,
  id: string,
  background = false,
  parentAgentId?: string,
) {
  await $.agent.spawn({
    prompt: "explore",
    description: id,
    subagentType: "Explore",
    provider: { kind: "engine" },
    parentModel: "claude-opus-5-5",
    background,
    ...(parentAgentId === undefined ? {} : { parentAgentId }),
  });
}

// The Agent call of a running agent returns `async_launched`.
async function asyncLaunched($: any, id: string) {
  await $.tool.call({ tool: "Agent", description: id, prompt: "explore" });
}

async function stats($: any) {
  const answer = await $.command.run({ command: "carbon-stats", args: "" });
  return plain(answer.text) ?? "";
}

async function step($: any, s: Step, turnId: string, index: number) {
  queue.push(s);
  const stream = $.turn.step({
    turnId,
    index,
    model: s.model,
    messageCount: 1,
    ...(s.agentId === undefined ? {} : { agentId: s.agentId }),
  });
  for await (const _chunk of stream) {
    // drain
  }
  await stream.result;
}

async function runTurn(
  $: any,
  steps: Step[],
  durationMs: number,
  before?: () => Promise<void>,
) {
  turns += 1;
  const turnId = `turn-${turns}`;
  await $.turn.start({ text: "go", turnId });
  if (before !== undefined) await before();
  for (const [index, s] of steps.entries()) await step($, s, turnId, index);
  await clock.advance(durationMs);
  return $.turn.complete({
    answer: "done",
    durationMs,
    isAborted: false,
    turnId,
    reason: "answer",
  });
}

// The engine draws a turn's line as the turn ends, then again under the same
// requestId on a resize or a scroll. The line is named after the turn it closes.
async function durationLine(
  $: any,
  durationMs: number,
  requestId = `line-${durationMs}`,
) {
  const ui = await $.ui.mount({
    plugin: PLUGIN,
    surface: "terminal",
    component: "TurnDuration",
    requestId,
    props: { word: "Baked", durationMs },
  });
  const drawn = JSON.stringify(await ui.drawn()).replaceAll(NBSP, " ");
  await ui.unmount();
  return drawn;
}

const plain = (text: string | undefined) => text?.replaceAll(NBSP, " ");

// 1 000 input, 100 000 cache reads, 2 000 output on Opus: (78 000 + 624 000 + 3 304 000) / 1e6 = 4.006 g
const ORDINARY: Step = {
  model: "claude-opus-5-5",
  input: 1000,
  cacheRead: 100000,
  output: 2000,
};
// 2 000 input and 6 000 output on Opus: 0.156 + 9.912 = 10.068 g
const HEAVY: Step = { model: "claude-opus-5-5", input: 2000, output: 6000 };
// 50 answers of 1 g: enough history for an answer to stand out
const ONE_GRAM_HISTORY = Array.from({ length: 50 }, () => 1);

describe("terminal", () => {
  test("an ordinary answer gets its CO2 on its duration line, in grey", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    const drawn = await durationLine($, 38000);
    expect(drawn).toContain("✻ Baked for 38s");
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("warning");
    expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
  });

  test("an unusual answer shows its ratio to the median and its subagents", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [
        HEAVY,
        { model: "claude-haiku-5-5", output: 4000, agentId: "agent-1" },
        { model: "claude-haiku-5-5", output: 4000, agentId: "agent-2" },
      ],
      372000,
      async () => {
        await spawn($, "agent-1");
        await spawn($, "agent-2");
      },
    );
    const drawn = await durationLine($, 372000);
    // 10.068 + 1.652 + 1.652 = 13.372 g, 13× a 1 g median
    expect(drawn).toContain("13 gCO₂ · 13× votre médiane");
    expect(drawn).toContain("warning");
    expect(drawn).toContain("dont 2 sous-agents : 3,3 gCO₂");
  });

  test("engine work under an unknown agent counts but is not named a subagent", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [
        HEAVY,
        { model: "claude-haiku-5-5", output: 4000, agentId: "compact-1" },
      ],
      90000,
    );
    const drawn = await durationLine($, 90000);
    expect(drawn).toContain("12 gCO₂ · 12× votre médiane");
    expect(drawn).not.toContain("sous-agent");
  });

  test("a background subagent counts in the session total, not in the answer", async ($: any, on: any) => {
    const { statuses } = world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [ORDINARY, { model: "claude-opus-5-5", output: 6000, agentId: "bg-1" }],
      38000,
      async () => spawn($, "bg-1", true),
    );
    const drawn = await durationLine($, 38000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("médiane");
    // 4.006 + 9.912 = 13.918 g in the session
    expect(plain(statuses.at(-1))).toBe("14 gCO₂ cette session");
  });

  test("requests after an answer ended never land on the next answer", async ($: any, on: any) => {
    const { statuses } = world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000, async () => spawn($, "late-1"));
    await step(
      $,
      { model: "claude-opus-5-5", output: 6000, agentId: "late-1" },
      "turn-late",
      0,
    );
    await runTurn($, [ORDINARY], 21000);
    const drawn = await durationLine($, 21000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    // 4.006 + 9.912 + 4.006 = 17.924 g in the session
    expect(plain(statuses.at(-1))).toBe("18 gCO₂ cette session");
  });

  test("a foreground subagent sent to the background leaves the answers after it", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    const opusAgent = { model: "claude-opus-5-5", output: 6000, agentId: "fg-1" };
    await $.turn.start({ text: "go", turnId: "t1" });
    await spawn($, "fg-1");
    await step($, ORDINARY, "t1", 0);
    await step($, { model: "claude-haiku-5-5", output: 4000, agentId: "fg-1" }, "a1", 0);
    // ctrl+b: the Agent call returns, the agent runs on
    await asyncLaunched($, "fg-1");
    await step($, opusAgent, "a1", 1);
    await $.turn.complete({
      answer: "done",
      durationMs: 38000,
      isAborted: false,
      turnId: "t1",
      reason: "answer",
    });
    // 4.006 + 1.652 g before ctrl+b, 4.006 g alone in the next answer
    expect(await durationLine($, 38000)).toContain("5,7 gCO₂");
    await runTurn($, [ORDINARY, opusAgent], 21000);
    expect(await durationLine($, 38000)).toContain("5,7 gCO₂");
    const drawn = await durationLine($, 21000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    // 5.658 + 9.912 + 4.006 + 9.912 = 29.488 g in the session
    expect(plain(statuses.at(-1))).toBe("29 gCO₂ cette session");
    // The median of 5.658 and 4.006, with no background request in it
    expect(await stats($)).toContain("Médiane de vos 2 dernières réponses : 4,8 gCO₂");
  });

  test("a subagent started in the background stays out of the next answer", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000, async () => {
      await spawn($, "bg-2", true);
      await asyncLaunched($, "bg-2");
    });
    await runTurn(
      $,
      [ORDINARY, { model: "claude-opus-5-5", output: 6000, agentId: "bg-2" }],
      21000,
    );
    expect(await durationLine($, 21000)).toContain("4,0 gCO₂");
    // 4.006 + 4.006 + 9.912 = 17.924 g in the session
    expect(plain(statuses.at(-1))).toBe("18 gCO₂ cette session");
    expect(await stats($)).toContain("Médiane de vos 2 dernières réponses : 4,0 gCO₂");
  });

  test("a subagent of a background subagent is in the background too", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [ORDINARY, { model: "claude-opus-5-5", output: 6000, agentId: "child-1" }],
      38000,
      async () => {
        await spawn($, "bg-3", true);
        await spawn($, "child-1", false, "bg-3");
      },
    );
    const drawn = await durationLine($, 38000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    expect(plain(statuses.at(-1))).toBe("14 gCO₂ cette session");
  });

  test("a foreground subagent still running in the next answer stays out of it", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000, async () => spawn($, "slow-1"));
    // It starts a subagent of its own while the next answer is written
    await runTurn(
      $,
      [
        ORDINARY,
        { model: "claude-opus-5-5", output: 6000, agentId: "slow-1" },
        { model: "claude-haiku-5-5", output: 4000, agentId: "slow-child" },
      ],
      21000,
      async () => spawn($, "slow-child", false, "slow-1"),
    );
    const drawn = await durationLine($, 21000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    // 4.006 + 4.006 + 9.912 + 1.652 = 19.576 g in the session
    expect(plain(statuses.at(-1))).toBe("20 gCO₂ cette session");
  });

  test("a subagent of a foreground subagent counts in its parent's answer", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [HEAVY, { model: "claude-haiku-5-5", output: 4000, agentId: "child-2" }],
      90000,
      async () => {
        await spawn($, "fg-2");
        await spawn($, "child-2", false, "fg-2");
      },
    );
    // 10.068 + 1.652 = 11.72 g, named as one subagent
    const drawn = await durationLine($, 90000);
    expect(drawn).toContain("12 gCO₂ · 12× votre médiane");
    expect(drawn).toContain("dont 1 sous-agent : 1,7 gCO₂");
  });

  test("an answer only closes on its own turn", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await $.turn.start({ text: "go", turnId: "t1" });
    await step($, ORDINARY, "t1", 0);
    await $.turn.complete({
      answer: "",
      durationMs: 1000,
      isAborted: false,
      turnId: "t0",
      reason: "answer",
    });
    expect(await durationLine($, 1000)).not.toContain("CO₂");
    await step($, ORDINARY, "t1", 1);
    await clock.advance(5000);
    await $.turn.complete({
      answer: "done",
      durationMs: 38000,
      isAborted: false,
      turnId: "t1",
      reason: "answer",
    });
    expect(await durationLine($, 38000)).toContain("8,0 gCO₂");
    expect(await durationLine($, 1000)).not.toContain("CO₂");
  });

  test("two turns of the same duration keep their own figures", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(await durationLine($, 38000, "a")).toContain("4,0 gCO₂");
    await runTurn($, [HEAVY], 38000);
    expect(await durationLine($, 38000, "b")).toContain("10 gCO₂");
    // Drawn again on a resize or a scroll, in any order
    expect(await durationLine($, 38000, "b")).toContain("10 gCO₂");
    expect(await durationLine($, 38000, "a")).toContain("4,0 gCO₂");
  });

  test("a line takes its turn's figure whatever duration it shows", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(await durationLine($, 38300)).toContain("4,0 gCO₂");
    // After background agents: a 1.5 s turn under a "Baked for 42s" line
    await runTurn($, [HEAVY], 1490);
    expect(await durationLine($, 42994)).toContain("10 gCO₂");
  });

  test("a line drawn just before its turn's figure is written takes it", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await $.turn.start({ text: "go", turnId: "t1" });
    await step($, ORDINARY, "t1", 0);
    const ui = await $.ui.mount({
      plugin: PLUGIN,
      surface: "terminal",
      component: "TurnDuration",
      requestId: "early",
      props: { word: "Baked", durationMs: 38000 },
    });
    expect(JSON.stringify(await ui.drawn())).not.toContain("CO₂");
    await clock.advance(10);
    await $.turn.complete({
      answer: "done",
      durationMs: 38000,
      isAborted: false,
      turnId: "t1",
      reason: "answer",
    });
    expect(plain(JSON.stringify(await ui.drawn()))).toContain("4,0 gCO₂");
    await ui.unmount();
  });

  test("a line first drawn more than a second after its turn shows nothing", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    // A line ctrl+o shows later, for a turn the normal view drew no line for
    await clock.advance(47000);
    expect(await durationLine($, 2019)).not.toContain("CO₂");
    // The turn's own line, drawn after that, gets nothing either
    expect(await durationLine($, 38000)).not.toContain("CO₂");
  });

  test("a figure goes to one line only", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(await durationLine($, 38000)).toContain("4,0 gCO₂");
    // Another line first drawn in the same second (ctrl+o right after the answer)
    await clock.advance(200);
    expect(await durationLine($, 2019)).not.toContain("CO₂");
    expect(await durationLine($, 38000)).toContain("4,0 gCO₂");
  });

  test("an entry of the earlier format is never bound", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    const co2 = { main: "4,0 gCO₂", sub: null, isUnusual: false };
    // What the session held under the earlier code: matched by duration alone
    let served: unknown[] = [{ durationMs: 38000, co2 }];
    on("state.get", ($inner: any, e: any, next: any) =>
      e.key === "answers" ? { value: { value: served, version: 1 } } : next(e),
    );
    await startSession($);
    expect(await durationLine($, 38000, "old")).not.toContain("CO₂");
    served = [
      ...served,
      { turnId: "t2", durationMs: 38000, at: clock.now(), co2 },
    ];
    expect(await durationLine($, 38000, "new")).toContain("4,0 gCO₂");
  });

  test("an uncounted turn next to a counted one shows nothing", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 4200);
    expect(await durationLine($, 4200)).toContain("4,0 gCO₂");
    await runTurn(
      $,
      [{ model: "glm-4.7-flash", input: 5000, output: 5000 }],
      4700,
    );
    expect(await durationLine($, 4700)).not.toContain("CO₂");
    expect(await durationLine($, 4200)).toContain("4,0 gCO₂");
  });

  test(
    "the newest figure survives once a hundred are kept",
    { timeoutMs: 30000 },
    async ($: any, on: any) => {
      world(on);
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 9999);
      expect(await durationLine($, 9999)).toContain("4,0 gCO₂");
      for (let i = 0; i < 100; i += 1) await runTurn($, [ORDINARY], 10000 + i);
      await runTurn($, [HEAVY], 4200);
      expect(await durationLine($, 4200)).toContain("10 gCO₂");
      // The first turn's entry is gone: its line goes back to the engine's
      expect(await durationLine($, 9999)).not.toContain("CO₂");
    },
  );

  test("a model outside Claude is not counted", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [{ model: "glm-4.7-flash", input: 5000, output: 5000 }],
      12000,
    );
    expect(await durationLine($, 12000)).not.toContain("CO₂");
    expect(statuses.length).toBe(0);
  });

  test("no session line when the claude-carbon status line is configured", async ($: any, on: any) => {
    const { statuses } = world(on, {
      statusLine: "~/Claude OS/code/claude-carbon/scripts/statusline.sh",
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(statuses.length).toBe(0);
  });

  test(
    "showSessionTotal off: no session line, the answer keeps its figure",
    { options: { showSessionTotal: false } },
    async ($: any, on: any) => {
      const { statuses } = world(on);
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 38000);
      expect(statuses.length).toBe(0);
      expect(plain(await durationLine($, 38000))).toContain("4,0 gCO₂");
    },
  );

  test(
    "showSessionTotal unset: the session line shows",
    { options: {} },
    async ($: any, on: any) => {
      const { statuses } = world(on);
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 38000);
      expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
    },
  );

  test("/clear and /resume start the session over", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    for (const reason of ["clear", "resume"]) {
      await runTurn($, [ORDINARY], 38000);
      await $.session.end({
        reason,
        sessionId: "s1",
        resume: { sessionId: "s1" },
      });
      expect(statuses.at(-1)).toBe(undefined);
      expect(await durationLine($, 38000)).not.toContain("CO₂");
    }
    await runTurn($, [ORDINARY], 20000);
    expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
  });
});

describe("desktop", () => {
  test("an ordinary answer adds no line", async ($: any, on: any) => {
    world(on, { surfaces: ["desktop"], history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [ORDINARY], 38000);
    expect(result.text).toBe("done");
  });

  test("an unusual answer gets one line under it", async ($: any, on: any) => {
    world(on, { surfaces: ["desktop"], history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [HEAVY], 90000);
    expect(plain(result.text)).toBe("10 gCO₂ · 10× votre médiane");
  });

  test("a terminal session never gets the line under the answer", async ($: any, on: any) => {
    world(on, { surfaces: ["terminal", "desktop"], history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [HEAVY], 90000);
    expect(result.text).toBe("done");
  });

  test("the session total shows even with the claude-carbon status line configured", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      statusLine: "~/code/claude-carbon/scripts/statusline.sh",
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe(
      "4,0 gCO₂ cette session · dernière réponse 4,0 gCO₂",
    );
  });

  // The surface already heads the entry with the plugin's name.
  const expectNoPluginName = (statuses: Array<string | undefined>) => {
    for (const text of statuses) expect(text).not.toContain("claude-carbon");
  };

  test("an ordinary answer puts its figure in the pinned entry", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [ORDINARY], 38000);
    expectNoPluginName(statuses);
    expect(result.text).toBe("done");
    expect(plain(statuses.at(-1))).toBe(
      "4,0 gCO₂ cette session · dernière réponse 4,0 gCO₂",
    );
  });

  test("the entry follows the last answer", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    await runTurn($, [ORDINARY], 21000);
    expectNoPluginName(statuses);
    expect(plain(statuses.at(-1))).toBe(
      "8,0 gCO₂ cette session · dernière réponse 4,0 gCO₂",
    );
  });

  test("an unusual answer: ratio under the answer, plain figure in the entry", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [HEAVY], 90000);
    expectNoPluginName(statuses);
    expect(plain(result.text)).toBe("10 gCO₂ · 10× votre médiane");
    expect(plain(statuses.at(-1))).toBe(
      "10 gCO₂ cette session · dernière réponse 10 gCO₂",
    );
  });

  test("an excluded last answer drops the tail", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    await runTurn(
      $,
      [{ model: "glm-4.7-flash", input: 5000, output: 5000 }],
      12000,
    );
    expectNoPluginName(statuses);
    expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
  });

  test("a background subagent counts in the total, not in the last answer", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [ORDINARY, { model: "claude-opus-5-5", output: 6000, agentId: "bg-1" }],
      38000,
      async () => spawn($, "bg-1", true),
    );
    expectNoPluginName(statuses);
    // 4.006 + 9.912 = 13.918 g in the session, 4.006 g in the answer
    expect(plain(statuses.at(-1))).toBe(
      "14 gCO₂ cette session · dernière réponse 4,0 gCO₂",
    );
  });

  test("a terminal attached keeps the short entry", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["terminal", "desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expectNoPluginName(statuses);
    expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
  });

  test(
    "showPerTurn off: no tail on Desktop",
    { options: { showPerTurn: false } },
    async ($: any, on: any) => {
      const { statuses } = world(on, { surfaces: ["desktop"] });
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 38000);
      expectNoPluginName(statuses);
      expect(plain(statuses.at(-1))).toBe("4,0 gCO₂ cette session");
    },
  );

  test(
    "showSessionTotal off: the desktop app, with no status line, keeps the entry",
    { options: { showSessionTotal: false } },
    async ($: any, on: any) => {
      const { statuses } = world(on, { surfaces: ["desktop"] });
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 38000);
      expect(plain(statuses.at(-1))).toBe(
        "4,0 gCO₂ cette session · dernière réponse 4,0 gCO₂",
      );
    },
  );
});

describe("first run", () => {
  test("the welcome toast shows once", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    await startSession($);
    expect(toasts).toEqual([
      "Le CO₂ de chaque réponse s'affiche en fin de réponse. Les plus lourdes ressortent après 50 réponses.",
    ]);
  });

  test("in English in a terminal", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false, lang: "en_US.UTF-8" });
    engineSteps(on);
    await startSession($);
    expect(toasts).toEqual([
      "Each answer's CO₂ shows when it ends. The heaviest stand out after 50 answers.",
    ]);
  });

  test("on Desktop it points at the pinned total", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false, surfaces: ["desktop"] });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(toasts).toEqual([
      "Le total CO₂ de la session reste sous le prompt. Une réponse bien plus lourde que d'habitude le signale.",
    ]);
  });

  test("a session nothing draws at start is welcomed at its first answer", async ($: any, on: any) => {
    const surfaces: string[] = [];
    const { toasts } = world(on, {
      welcomed: false,
      surfaces,
      lang: "en_US.UTF-8",
    });
    engineSteps(on);
    await startSession($, false);
    expect(toasts.length).toBe(0);
    surfaces.push("desktop");
    await runTurn($, [ORDINARY], 38000);
    await runTurn($, [ORDINARY], 21000);
    expect(toasts).toEqual([
      "The session's CO₂ total stays under the prompt. An answer much heavier than usual says so.",
    ]);
  });

  test("a run nobody watches keeps the welcome for later", async ($: any, on: any) => {
    const surfaces: string[] = [];
    const { toasts } = world(on, { welcomed: false, surfaces });
    engineSteps(on);
    await startSession($, false);
    await runTurn($, [ORDINARY], 38000);
    expect(toasts.length).toBe(0);
    surfaces.push("terminal");
    await startSession($);
    expect(toasts.length).toBe(1);
    expect(toasts[0]).toContain("Le CO₂ de chaque réponse");
  });
});

describe("language without LANG", () => {
  const FR_TOAST =
    "Le CO₂ de chaque réponse s'affiche en fin de réponse. Les plus lourdes ressortent après 50 réponses.";
  const EN_TOAST =
    "Each answer's CO₂ shows when it ends. The heaviest stand out after 50 answers.";
  const APPLE_LOCALE = ["defaults", "read", "-g", "AppleLocale"];

  test("an en_US system gives English", async ($: any, on: any) => {
    const { toasts, commands } = world(on, {
      welcomed: false,
      lang: null,
      systemLocale: "en_US\n",
    });
    await startSession($);
    expect(commands).toEqual([APPLE_LOCALE]);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("a fr_FR system gives French", async ($: any, on: any) => {
    const { toasts } = world(on, {
      welcomed: false,
      lang: null,
      systemLocale: "fr_FR\n",
    });
    await startSession($);
    expect(toasts).toEqual([FR_TOAST]);
  });

  test("a command that cannot run gives French", async ($: any, on: any) => {
    const { toasts, commands } = world(on, {
      welcomed: false,
      lang: null,
    });
    await startSession($);
    expect(commands.length).toBe(1);
    expect(toasts).toEqual([FR_TOAST]);
  });

  test("the language setting wins over the system", async ($: any, on: any) => {
    const { toasts, commands } = world(on, {
      welcomed: false,
      lang: null,
      language: "English",
      systemLocale: "fr_FR\n",
    });
    await startSession($);
    expect(commands).toEqual([]);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("Windows reads the locale from the registry", async ($: any, on: any) => {
    const { toasts, commands } = world(on, {
      welcomed: false,
      lang: null,
      os: "Windows_NT",
      systemLocale:
        "\r\nHKEY_CURRENT_USER\\Control Panel\\International\r\n    LocaleName    REG_SZ    en-US\r\n\r\n",
    });
    await startSession($);
    expect(commands).toEqual([
      [
        "reg",
        "query",
        "HKCU\\Control Panel\\International",
        "/v",
        "LocaleName",
      ],
    ]);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("LANG decides alone: nothing else is asked", async ($: any, on: any) => {
    const { toasts, commands } = world(on, {
      welcomed: false,
      lang: "en_US.UTF-8",
      language: "Français",
      systemLocale: "fr_FR\n",
    });
    await startSession($);
    expect(commands).toEqual([]);
    expect(toasts).toEqual([EN_TOAST]);
  });
});

describe("unusual threshold", () => {
  test("49 answers of history: no answer stands out yet", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY.slice(1) });
    engineSteps(on);
    await startSession($);
    await runTurn($, [HEAVY], 90000);
    const drawn = await durationLine($, 90000);
    expect(drawn).toContain("10 gCO₂");
    expect(drawn).not.toContain("médiane");
  });

  test("3x the median is not enough under the 97th percentile", async ($: any, on: any) => {
    // Median 1 g, 97th percentile 12 g: 10 g is 10x the median, still ordinary
    world(on, {
      history: [
        ...Array.from({ length: 90 }, () => 1),
        ...Array.from({ length: 10 }, () => 12),
      ],
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [HEAVY], 90000);
    expect(await durationLine($, 90000)).not.toContain("médiane");
  });
});

test(
  "showPerTurn off keeps the duration line as it is",
  { options: { showPerTurn: false } },
  async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(await durationLine($, 38000)).not.toContain("CO₂");
  },
);

test("the v1 history is not read", async ($: any, on: any) => {
  world(on, { legacyHistory: ONE_GRAM_HISTORY });
  engineSteps(on);
  await startSession($);
  await runTurn($, [HEAVY], 90000);
  expect(await durationLine($, 90000)).not.toContain("médiane");
  expect(await stats($)).toContain("Votre dernière réponse : 10 gCO₂");
});

test("/carbon-stats reports the median and requests per prompt", async ($: any, on: any) => {
  world(on, { history: ONE_GRAM_HISTORY });
  engineSteps(on);
  await startSession($);
  const answer = await $.command.run({ command: "carbon-stats", args: "" });
  expect(plain(answer.text)).toContain(
    "Médiane de vos 50 dernières réponses : 1,0 gCO₂",
  );
  expect(plain(answer.text)).toContain(
    "Requêtes au modèle par prompt : 1,0 en moyenne sur 50 prompts",
  );
});
