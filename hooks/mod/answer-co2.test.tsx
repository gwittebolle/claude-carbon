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
  surfaces?: string[];
  statusLine?: string;
  history?: number[];
  welcomed?: boolean;
};

// The engine beneath the plugin: each noun the mod calls, answered as a session would.
// A mods API call answers { value } (or { deny }).
function world(on: any, options: World = {}) {
  const statuses: Array<string | undefined> = [];
  const toasts: string[] = [];
  const values = options.history ?? [];
  mock.store(on, {
    history: {
      values,
      turns: values.length,
      steps: values.length,
      subagentSteps: 0,
      welcomed: options.welcomed ?? true,
    },
  });
  mock.env(on, { LANG: "fr_FR.UTF-8" });
  on("fs.read", () => ({ value: FACTORS }));
  on("settings.read", () => ({
    value: options.statusLine
      ? { statusLine: { type: "command", command: options.statusLine } }
      : {},
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
  on("session.start", ($: any, e: any) => ({ cwd: e.cwd }));
  on("session.end", ($: any, e: any) => ({ sessionId: e.sessionId }));
  on("turn.start", ($: any, e: any) => ({ turnId: e.turnId }));
  on("turn.complete", ($: any, e: any) => ({ text: e.answer }));
  return { statuses, toasts };
}

let queue: Step[] = [];

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

async function startSession($: any) {
  await $.session.start({
    cwd: "/tmp/project",
    surface: "terminal",
    isInteractive: true,
  });
}

async function spawn($: any, id: string, background = false) {
  await $.agent.spawn({
    prompt: "explore",
    description: id,
    subagentType: "Explore",
    provider: { kind: "engine" },
    parentModel: "claude-opus-5-5",
    background,
  });
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
  const turnId = `turn-${durationMs}`;
  await $.turn.start({ text: "go", turnId });
  if (before !== undefined) await before();
  for (const [index, s] of steps.entries()) await step($, s, turnId, index);
  return $.turn.complete({
    answer: "done",
    durationMs,
    isAborted: false,
    turnId,
    reason: "answer",
  });
}

async function durationLine($: any, durationMs: number) {
  const ui = await $.ui.mount({
    plugin: PLUGIN,
    surface: "terminal",
    component: "TurnDuration",
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
const TWENTY_GRAMS = Array.from({ length: 20 }, () => 1);

describe("terminal", () => {
  test("an ordinary answer gets its CO2 on its duration line, in grey", async ($: any, on: any) => {
    const { statuses } = world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    const drawn = await durationLine($, 38000);
    expect(drawn).toContain("✻ Baked for 38s");
    expect(drawn).toContain("4,0 g CO₂");
    expect(drawn).not.toContain("warning");
    expect(plain(statuses.at(-1))).toBe("claude-carbon · 4,0 g cette session");
  });

  test("an unusual answer shows its ratio to the median and its subagents", async ($: any, on: any) => {
    world(on, { history: TWENTY_GRAMS });
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
    expect(drawn).toContain("13 g CO₂ · 13× votre médiane");
    expect(drawn).toContain("warning");
    expect(drawn).toContain("dont 2 sous-agents : 3,3 g");
  });

  test("engine work under an unknown agent counts but is not named a subagent", async ($: any, on: any) => {
    world(on, { history: TWENTY_GRAMS });
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
    expect(drawn).toContain("12 g CO₂ · 12× votre médiane");
    expect(drawn).not.toContain("sous-agent");
  });

  test("a background subagent counts in the session total, not in the answer", async ($: any, on: any) => {
    const { statuses } = world(on, { history: TWENTY_GRAMS });
    engineSteps(on);
    await startSession($);
    await runTurn(
      $,
      [ORDINARY, { model: "claude-opus-5-5", output: 6000, agentId: "bg-1" }],
      38000,
      async () => spawn($, "bg-1", true),
    );
    const drawn = await durationLine($, 38000);
    expect(drawn).toContain("4,0 g CO₂");
    expect(drawn).not.toContain("médiane");
    // 4.006 + 9.912 = 13.918 g in the session
    expect(plain(statuses.at(-1))).toBe("claude-carbon · 14 g cette session");
  });

  test("requests after an answer ended never land on the next answer", async ($: any, on: any) => {
    const { statuses } = world(on, { history: TWENTY_GRAMS });
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
    expect(drawn).toContain("4,0 g CO₂");
    expect(drawn).not.toContain("sous-agent");
    // 4.006 + 9.912 + 4.006 = 17.924 g in the session
    expect(plain(statuses.at(-1))).toBe("claude-carbon · 18 g cette session");
  });

  test("a line only shows its own turn's CO2", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 38000);
    expect(await durationLine($, 38400)).not.toContain("CO₂");
  });

  test("an uncounted turn next to a counted one shows nothing", async ($: any, on: any) => {
    world(on);
    engineSteps(on);
    await startSession($);
    await runTurn($, [ORDINARY], 4200);
    await runTurn(
      $,
      [{ model: "glm-4.7-flash", input: 5000, output: 5000 }],
      4700,
    );
    expect(await durationLine($, 4700)).not.toContain("CO₂");
    expect(await durationLine($, 4200)).toContain("4,0 g CO₂");
  });

  test(
    "the newest figure survives once a hundred are kept",
    { timeoutMs: 30000 },
    async ($: any, on: any) => {
      world(on);
      engineSteps(on);
      await startSession($);
      for (let i = 0; i < 100; i += 1) await runTurn($, [ORDINARY], 10000 + i);
      await runTurn($, [HEAVY], 4200);
      expect(await durationLine($, 4200)).toContain("10 g CO₂");
      expect(await durationLine($, 10000)).not.toContain("CO₂");
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
    expect(plain(statuses.at(-1))).toBe("claude-carbon · 4,0 g cette session");
  });
});

describe("desktop", () => {
  test("an ordinary answer adds no line", async ($: any, on: any) => {
    world(on, { surfaces: ["desktop"], history: TWENTY_GRAMS });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [ORDINARY], 38000);
    expect(result.text).toBe("done");
  });

  test("an unusual answer gets one line under it", async ($: any, on: any) => {
    world(on, { surfaces: ["desktop"], history: TWENTY_GRAMS });
    engineSteps(on);
    await startSession($);
    const result = await runTurn($, [HEAVY], 90000);
    expect(plain(result.text)).toBe("10 g CO₂ · 10× votre médiane");
  });

  test("a terminal session never gets the line under the answer", async ($: any, on: any) => {
    world(on, { surfaces: ["terminal", "desktop"], history: TWENTY_GRAMS });
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
    expect(plain(statuses.at(-1))).toBe("claude-carbon · 4,0 g cette session");
  });
});

describe("first run", () => {
  test("the welcome toast shows once", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false });
    engineSteps(on);
    await startSession($);
    await startSession($);
    expect(toasts.length).toBe(1);
    expect(toasts[0]).toContain("Le CO₂ de chaque réponse");
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

test("/carbon-stats reports the median and requests per prompt", async ($: any, on: any) => {
  world(on, { history: TWENTY_GRAMS });
  engineSteps(on);
  await startSession($);
  const answer = await $.command.run({ command: "carbon-stats", args: "" });
  expect(plain(answer.text)).toContain(
    "Médiane de vos 20 dernières réponses : 1,0 g CO₂",
  );
  expect(plain(answer.text)).toContain(
    "Requêtes au modèle par prompt : 1,0 en moyenne sur 20 prompts",
  );
});
