import { describe, expect, mock, test } from "claude-code/testing";

const PLUGIN = "claude-carbon";
const NBSP = " ";

const FACTORS = JSON.stringify({
  models: {
    fable: { input: 156, output: 3304 },
    opus: { input: 78, output: 1652 },
    sonnet: { input: 39, output: 826 },
    haiku: { input: 10, output: 207 },
  },
  cache_read_factor: 0.08,
  exclude_models: [],
});

// The parts of data/prices.json the tests' models read.
const PRICES = JSON.stringify({
  models: {
    fable: { input: 10, output: 50 },
    opus: { input: 4, output: 20 },
    sonnet: { input: 2, output: 10 },
    haiku: { input: 0.1, output: 0.5 },
  },
  model_overrides: {
    "claude-opus-5-5": { input: 4, output: 20, cache_read_multiplier: 0.05 },
  },
  cache_write_multiplier: 1.25,
  cache_write_multiplier_1h: 2.0,
  cache_read_multiplier: 0.1,
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
  statusLine?: string;
  history?: number[];
  // Values under the v1 key, which counted background subagents in the answer
  legacyHistory?: number[];
  welcomed?: boolean;
  // data/prices.json as the mod reads it; null: the file cannot be read
  prices?: string | null;
  // The one-time /carbon-panel hint already shown (its own tests are in carbon-pane.test.tsx)
  hinted?: boolean;
};

const storedHistory = (values: number[], welcomed: boolean) => ({
  values,
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
  // Any process the mod would start: it starts none.
  const processes: string[][] = [];
  const welcomed = options.welcomed ?? true;
  // $.store in memory, as mock.store keeps it, readable by the test.
  const store = new Map<string, unknown>([
    ["history.v2", storedHistory(options.history ?? [], welcomed)],
    ...(options.legacyHistory === undefined
      ? []
      : [["history", storedHistory(options.legacyHistory, true)] as const]),
    ...(options.hinted === false ? [] : [["pane.hinted", true] as const]),
  ]);
  on("store.get", ($: any, e: any) => ({ value: store.get(e.key) }));
  on("store.set", ($: any, e: any) => {
    store.set(e.key, JSON.parse(JSON.stringify(e.value)));
    return { value: undefined };
  });
  on("store.delete", ($: any, e: any) => {
    store.delete(e.key);
    return { value: undefined };
  });
  on("store.keys", () => ({ value: [...store.keys()] }));
  // The answers' figures kept for the median, in grams to the milligram.
  const storedValues = () =>
    (store.get("history.v2") as { values: number[] }).values.map(
      (v) => Math.round(v * 1000) / 1000,
    );
  mock.env(
    on,
    options.lang === null ? {} : { LANG: options.lang ?? "fr_FR.UTF-8" },
  );
  on("process.run", ($: any, e: any) => {
    processes.push([...e.argv]);
    return { deny: "not expected" };
  });
  on("fs.read", ($: any, e: any) => {
    if (!String(e.path).endsWith("/data/prices.json")) return { value: FACTORS };
    const prices = options.prices === undefined ? PRICES : options.prices;
    return prices === null ? { deny: "not found" } : { value: prices };
  });
  on("settings.read", () => ({
    value: {
      ...(options.statusLine
        ? { statusLine: { type: "command", command: options.statusLine } }
        : {}),
      ...(options.language === undefined ? {} : { language: options.language }),
    },
  }));
  on("session.surfaces", () => ({ value: options.surfaces ?? ["terminal"] }));
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
  return { statuses, toasts, processes, storedValues };
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
// and (4 000 + 20 000 + 40 000) / 1e6 = $0.064 at Opus 5.5's prices (reads at 0.05x)
const ORDINARY: Step = {
  model: "claude-opus-5-5",
  input: 1000,
  cacheRead: 100000,
  output: 2000,
};
// 2 000 input and 6 000 output on Opus: 0.156 + 9.912 = 10.068 g, $0.128
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
  });

  test("an unusual answer shows its ratio to the median and its subagents", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [
        HEAVY,
        { model: "claude-haiku-5-5", output: 8000, agentId: "agent-1" },
        { model: "claude-haiku-5-5", output: 8000, agentId: "agent-2" },
      ],
      372000,
      async () => {
        await spawn($, "agent-1");
        await spawn($, "agent-2");
      },
    );
    const drawn = await durationLine($, 372000);
    // 10.068 + 1.656 + 1.656 = 13.38 g, 13× a 1 g median
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
        { model: "claude-haiku-5-5", output: 8000, agentId: "compact-1" },
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 14 gCO₂ · 0,18 $");
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 18 gCO₂ · 0,25 $");
  });

  test("a foreground subagent sent to the background leaves the answers after it", async ($: any, on: any) => {
    const { statuses, storedValues } = world(on);
    engineSteps(on);
    await startSession($);
    const opusAgent = { model: "claude-opus-5-5", output: 6000, agentId: "fg-1" };
    await $.turn.start({ text: "go", turnId: "t1" });
    await spawn($, "fg-1");
    await step($, ORDINARY, "t1", 0);
    await step($, { model: "claude-haiku-5-5", output: 8000, agentId: "fg-1" }, "a1", 0);
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
    // 4.006 + 1.656 g before ctrl+b, 4.006 g alone in the next answer
    expect(await durationLine($, 38000)).toContain("5,7 gCO₂");
    await runTurn($, [ORDINARY, opusAgent], 21000);
    expect(await durationLine($, 38000)).toContain("5,7 gCO₂");
    const drawn = await durationLine($, 21000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    // 5.662 + 9.912 + 4.006 + 9.912 = 29.492 g in the session
    expect(plain(statuses.at(-1))).toBe("Cette session : 29 gCO₂ · 0,37 $");
    // 5.662 and 4.006 for the median, with no background request in them
    expect(storedValues()).toEqual([5.662, 4.006]);
  });

  test("a subagent started in the background stays out of the next answer", async ($: any, on: any) => {
    const { statuses, storedValues } = world(on);
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 18 gCO₂ · 0,25 $");
    expect(storedValues()).toEqual([4.006, 4.006]);
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 14 gCO₂ · 0,18 $");
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
        { model: "claude-haiku-5-5", output: 8000, agentId: "slow-child" },
      ],
      21000,
      async () => spawn($, "slow-child", false, "slow-1"),
    );
    const drawn = await durationLine($, 21000);
    expect(drawn).toContain("4,0 gCO₂");
    expect(drawn).not.toContain("sous-agent");
    // 4.006 + 4.006 + 9.912 + 1.656 = 19.58 g in the session
    expect(plain(statuses.at(-1))).toBe("Cette session : 20 gCO₂ · 0,25 $");
  });

  test("a subagent of a foreground subagent counts in its parent's answer", async ($: any, on: any) => {
    world(on, { history: ONE_GRAM_HISTORY });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [HEAVY, { model: "claude-haiku-5-5", output: 8000, agentId: "child-2" }],
      90000,
      async () => {
        await spawn($, "fg-2");
        await spawn($, "child-2", false, "fg-2");
      },
    );
    // 10.068 + 1.656 = 11.724 g, named as one subagent
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
      expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
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
      "Cette session : 4,0 gCO₂ · 0,06 $",
    );
  });

  // The surface already heads the entry with the plugin's name, and the entry gives
  // the session alone: no last answer's figure.
  const expectNoPluginName = (statuses: Array<string | undefined>) => {
    for (const text of statuses) {
      expect(text).not.toContain("claude-carbon");
      expect(text).not.toContain("dernière réponse");
      expect(text).not.toContain("last answer");
    }
  };

  test("an ordinary answer shows the session total in the pinned entry", async ($: any, on: any) => {
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
      "Cette session : 4,0 gCO₂ · 0,06 $",
    );
  });

  test("the entry adds up the answers, CO2 and cost", async ($: any, on: any) => {
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
      "Cette session : 8,0 gCO₂ · 0,13 $",
    );
  });

  test("an unusual answer: ratio under the answer, session total in the entry", async ($: any, on: any) => {
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
      "Cette session : 10 gCO₂ · 0,13 $",
    );
  });

  test("an excluded answer adds nothing to the entry", async ($: any, on: any) => {
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
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
  });

  test("a background subagent counts in the entry", async ($: any, on: any) => {
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
    // 4.006 + 9.912 = 13.918 g and $0.064 + $0.12 in the session
    expect(plain(statuses.at(-1))).toBe(
      "Cette session : 14 gCO₂ · 0,18 $",
    );
  });

  test("a terminal attached shows the same entry", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["terminal", "desktop"],
      history: ONE_GRAM_HISTORY,
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expectNoPluginName(statuses);
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
  });

  test(
    "showPerTurn off: the entry stays the same on Desktop",
    { options: { showPerTurn: false } },
    async ($: any, on: any) => {
      const { statuses } = world(on, { surfaces: ["desktop"] });
      engineSteps(on);
      await startSession($);
      await runTurn($, [ORDINARY], 38000);
      expectNoPluginName(statuses);
      expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
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
        "Cette session : 4,0 gCO₂ · 0,06 $",
      );
    },
  );

  test("in English, the dollar sign goes first", async ($: any, on: any) => {
    const { statuses } = world(on, {
      surfaces: ["desktop"],
      lang: "en_US.UTF-8",
    });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("This session: 4.0 gCO₂ · $0.06");
  });

  test("the entry spaces its French colon and its unit with no-break spaces", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"] });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(statuses.at(-1)).toBe(
      `Cette session${NBSP}: 4,0${NBSP}gCO₂ · 0,06${NBSP}$`,
    );
  });

  test("a session under a cent says so", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"] });
    engineSteps(on);
    await startSession($);
    // 8 000 output on Haiku 5.5: 1.656 g, $0.004
    await runTurn($, [{ model: "claude-haiku-5-5", output: 8000 }], 9000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 1,7 gCO₂ · < 0,01 $");
  });

  test("no price list: the entry shows the CO2 alone", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"], prices: null });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂");
  });

  test("a price list that is not JSON: the CO2 alone", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"], prices: "{" });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂");
  });

  test("a price list read only after a reload: the CO2 alone, never a part of the cost", async ($: any, on: any) => {
    const options: World = { surfaces: ["desktop"], prices: null };
    const { statuses } = world(on, options);
    engineSteps(on);
    await startSession($);
    await runTurn($, [HEAVY], 90000);
    // A reload raises session.start again and keeps $.state.
    options.prices = undefined;
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 14 gCO₂");
  });

  test("a total kept from code that counted no cost: the CO2 alone", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"] });
    engineSteps(on);
    // The session value as the earlier code wrote it, before a reload: no usd.
    const held = { value: { grams: 10.068, turns: 1 } as unknown, version: 1 };
    on("state.get", ($inner: any, e: any, next: any) =>
      e.key === "session" ? { value: { ...held } } : next(e),
    );
    on("state.set", ($inner: any, e: any, next: any) => {
      if (e.key !== "session") return next(e);
      if (e.ifVersion !== undefined && e.ifVersion !== held.version) {
        return { value: { isSet: false, version: held.version } };
      }
      held.value = JSON.parse(JSON.stringify(e.value));
      held.version += 1;
      return { value: { isSet: true, version: held.version } };
    });
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 14 gCO₂");
  });

  test("/clear starts the cost over with the CO2", async ($: any, on: any) => {
    const { statuses } = world(on, { surfaces: ["desktop"] });
    engineSteps(on);
    await startSession($);
    await runTurn($, [HEAVY], 90000);
    await $.session.end({
      reason: "clear",
      sessionId: "s1",
      resume: { sessionId: "s1" },
    });
    await runTurn($, [ORDINARY], 38000);
    expect(plain(statuses.at(-1))).toBe("Cette session : 4,0 gCO₂ · 0,06 $");
  });
});

const FR_TOAST = "Le CO₂ s'affiche maintenant pour chaque réponse.";
const EN_TOAST = "CO₂ now shows for each answer.";

describe("first run", () => {
  test("the welcome toast shows once", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    await startSession($);
    expect(toasts).toEqual([FR_TOAST]);
  });

  test("in English", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false, lang: "en_US.UTF-8" });
    engineSteps(on);
    await startSession($);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("the same text on Desktop", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false, surfaces: ["desktop"] });
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(toasts).toEqual([FR_TOAST]);
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
    expect(toasts).toEqual([EN_TOAST]);
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
    expect(toasts).toEqual([FR_TOAST]);
  });
});

describe("language without LANG", () => {
  test("nothing set gives French, and no process is started", async ($: any, on: any) => {
    const { toasts, processes } = world(on, { welcomed: false, lang: null });
    await startSession($);
    expect(processes).toEqual([]);
    expect(toasts).toEqual([FR_TOAST]);
  });

  test("the language setting decides", async ($: any, on: any) => {
    const { toasts, processes } = world(on, {
      welcomed: false,
      lang: null,
      language: "English",
    });
    await startSession($);
    expect(processes).toEqual([]);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("the language setting in French words", async ($: any, on: any) => {
    const { toasts } = world(on, {
      welcomed: false,
      lang: null,
      language: "Anglais",
    });
    await startSession($);
    expect(toasts).toEqual([EN_TOAST]);
  });

  test("LANG wins over the language setting", async ($: any, on: any) => {
    const { toasts } = world(on, {
      welcomed: false,
      lang: "en_US.UTF-8",
      language: "Français",
    });
    await startSession($);
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
  const { storedValues } = world(on, { legacyHistory: ONE_GRAM_HISTORY });
  engineSteps(on);
  await startSession($);
  await runTurn($, [HEAVY], 90000);
  expect(await durationLine($, 90000)).not.toContain("médiane");
  expect(storedValues()).toEqual([10.068]);
});
