import { describe, expect, mock, test } from "claude-code/testing";

const PLUGIN = "claude-carbon";
const NBSP = "\u00a0";
const DAY = 86_400_000;
// 12 Oct 2026, noon UTC
const NOW = Date.UTC(2026, 9, 12, 12);
const SESSION_ID = "session-now";

const FACTORS = JSON.stringify({
  equivalences: {
    fr: [
      {
        id: "car",
        divisor: 142,
        unit: "km",
        tag: "142 g/km, ADEME 2025",
        decimals: 0,
        label: "km en voiture",
        source: "142 gCO2e/km, ADEME 2025",
      },
    ],
  },
  models: {
    fable: { input: 156, output: 3304 },
    opus: { input: 78, output: 1652 },
    sonnet: { input: 39, output: 826 },
    haiku: { input: 10, output: 207 },
  },
  cache_read_factor: 0.08,
  exclude_models: [],
});

// `count` past sessions, one a day back from now, 100 to 500 g; the running session's own
// row (a partial total) is in the file too, as the Stop hook writes it.
function historyText(count: number): string {
  const lines = Array.from({ length: count }, (_, i) => {
    const at = Math.floor((NOW - (count - i) * DAY) / 1000);
    return `past-${i}\t${at}\t${100 * ((i % 5) + 1)}`;
  });
  lines.push(`${SESSION_ID}\t${Math.floor(NOW / 1000)}\t9999`);
  return `${lines.join("\n")}\n`;
}

type World = {
  // The history file's text, or what it holds when read; null: no file (an install
  // without the database)
  history?: string | null | (() => string);
  // This session's id when read (/clear changes it in the same process)
  sessionId?: () => string;
  welcomed?: boolean;
  hinted?: boolean;
  // Another extension already took /carbon-panel
  commandTaken?: boolean;
  // What the prompt box holds
  draft?: string;
  // The surfaces the session draws on: the desktop app unless a test says a terminal
  surfaces?: string[];
};

const PANE = {
  plugin: PLUGIN,
  component: "Pane",
  requestId: "carbon",
  viewport: { columns: 100, rows: 30 },
  props: {
    title: "Carbone",
    isFocused: false,
    bodyColumns: 60,
    placement: "inline",
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const;

// The band above a terminal's prompt, where /carbon-panel shows the molecule there
const BAND = {
  plugin: PLUGIN,
  component: "AbovePrompt",
  surface: "terminal",
  requestId: "band",
  viewport: { columns: 100, rows: 30 },
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 12,
    bodyColumns: 95,
    scroll: { offset: 0, bodyRows: 12 },
    view: {},
  },
} as const;

let clock: any;

function world(on: any, options: World = {}) {
  clock = mock.clock(on, { now: NOW });
  const toasts: string[] = [];
  const opened: any[] = [];
  const closed: string[] = [];
  const blits: any[] = [];
  const registered: any[] = [];
  // What the mod must never do: write a file, call the network, start a process
  const writes: string[] = [];
  const fetches: string[] = [];
  const processes: string[][] = [];
  const open = new Set<string>();
  const store = new Map<string, unknown>([
    ["history.v2", { values: [], welcomed: options.welcomed ?? true }],
    ...(options.hinted === false ? [] : [["pane.hinted", true] as const]),
  ]);
  on("store.get", ($: any, e: any) => ({ value: store.get(e.key) }));
  on("store.set", ($: any, e: any) => {
    store.set(e.key, JSON.parse(JSON.stringify(e.value)));
    return { value: undefined };
  });
  mock.env(on, { LANG: "fr_FR.UTF-8", HOME: "/home/test" });
  on("fs.read", ($: any, e: any) => {
    const path = String(e.path);
    if (path.endsWith("/sessions-history.tsv")) {
      expect(path).toBe(
        "/home/test/.claude/claude-carbon/sessions-history.tsv",
      );
      const text =
        options.history === undefined
          ? historyText(20)
          : typeof options.history === "function"
            ? options.history()
            : options.history;
      return text === null ? { deny: "not found" } : { value: text };
    }
    if (path.endsWith("/data/prices.json")) return { deny: "not found" };
    return { value: FACTORS };
  });
  on("fs.write", ($: any, e: any) => {
    writes.push(String(e.path));
    return { deny: "not expected" };
  });
  on("http.fetch", ($: any, e: any) => {
    fetches.push(String(e.url));
    return { deny: "not expected" };
  });
  on("process.run", ($: any, e: any) => {
    processes.push([...e.argv]);
    return { deny: "not expected" };
  });
  on("settings.read", () => ({ value: {} }));
  on("session.surfaces", () => ({ value: options.surfaces ?? ["desktop"] }));
  // The engine's own band: an empty Box, nothing of its own above the prompt
  on("ui.render", { component: "AbovePrompt" }, ($: any, e: any) => {
    const { Box } = $.ui.resolve(e);
    return <Box key="engine-band" />;
  });
  on("session.id", () => ({ value: options.sessionId?.() ?? SESSION_ID }));
  on("command.register", ($: any, e: any) => {
    if (options.commandTaken) return { deny: "taken" };
    registered.push(e);
    return { value: undefined };
  });
  on("ui.status", () => ({ value: undefined }));
  on("ui.toast", ($: any, e: any) => {
    toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.open", ($: any, e: any) => {
    opened.push({ ...e });
    open.add(e.id);
    return { value: { isPlaced: true } };
  });
  on("ui.close", ($: any, e: any) => {
    closed.push(e.id);
    open.delete(e.id);
    return { value: undefined };
  });
  on("ui.panes", () => ({
    value: [...open].map((id) => ({
      id,
      title: "Carbone",
      isShown: true,
      isFocused: false,
      isPlaced: true,
    })),
  }));
  const fills: any[] = [];
  const submits: string[] = [];
  on("prompt.read", () => ({ value: { text: options.draft ?? "", cursor: 0 } }));
  on("prompt.fill", ($: any, e: any) => {
    fills.push({ ...e });
    return { isFilled: true };
  });
  on("prompt.submit", ($: any, e: any) => {
    submits.push(e.text);
    return { text: e.text };
  });
  on("ui.blit", ($: any, e: any) => {
    blits.push(e);
    return { value: {} };
  });
  on("session.start", ($: any, e: any) => ({ cwd: e.cwd }));
  on("session.end", ($: any, e: any) => ({ sessionId: e.sessionId }));
  on("turn.start", ($: any, e: any) => ({ turnId: e.turnId }));
  on("turn.complete", ($: any, e: any) => ({ text: e.answer }));
  on("turn.step", async function* ($: any, e: any) {
    return {
      turnId: e.turnId,
      index: e.index,
      answer: "",
      toolUses: [],
      stopReason: "end_turn",
      usage: null,
    };
  });
  return {
    toasts,
    opened,
    closed,
    blits,
    registered,
    writes,
    fetches,
    processes,
    store,
    fills,
    submits,
  };
}

async function startSession($: any) {
  await $.session.start({
    cwd: "/tmp/project",
    surface: "terminal",
    isInteractive: true,
  });
}

async function openPane($: any) {
  await $.command.run({ command: "carbon-panel", args: "" });
}

const texts = (node: any): string[] => {
  if (node === null || node === undefined) return [];
  if (typeof node === "string") return [node];
  if (Array.isArray(node)) return node.flatMap(texts);
  return texts(node.children);
};

async function drawn(ui: any): Promise<string> {
  return texts(await ui.drawn())
    .join("\n")
    .replaceAll(NBSP, " ");
}

describe("the /carbon-panel pane", () => {
  test("after /clear the pane follows the new conversation, the one before counted as past", async ($: any, on: any) => {
    const at = (hours: number) => Math.floor((NOW - hours * 3_600_000) / 1000);
    const before = [`past\t${at(30)}\t300`, `${SESSION_ID}\t${at(2)}\t1000`];
    let id = SESSION_ID;
    let history = `${before.join("\n")}\n`;
    world(on, { history: () => history, sessionId: () => id });
    await startSession($);
    await openPane($);
    let ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    // The running conversation's own row is left out (its total is live, none yet)
    expect(await drawn(ui)).toContain("Sur la période\n300 gCO₂\nSessions\n1");
    await ui.unmount();
    // /clear: the same process goes on under a new id; the Stop hook has written the new
    // conversation's first answer
    await $.session.end({ sessionId: SESSION_ID, reason: "clear" });
    id = "session-new";
    history = `${[...before, `session-new\t${at(0)}\t30`].join("\n")}\n`;
    ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(ui);
    // The conversation before /clear is now a past session; the new one's row is its own
    expect(text).toContain("Sur la période\n1,3 kgCO₂\nSessions\n2");
    await ui.unmount();
  });
  test("/carbon-panel is registered, opens the pane without the keyboard, and closes it", async ($: any, on: any) => {
    const { opened, closed, registered } = world(on);
    await startSession($);
    expect(registered.map((c) => c.name)).toEqual(["carbon-panel"]);
    expect(registered[0].immediate).toBe(true);
    await openPane($);
    expect(opened).toEqual([
      { id: "carbon", title: "claude-carbon", closeOnEscape: true },
    ]);
    await openPane($);
    expect(closed).toEqual(["carbon"]);
  });

  test("in a terminal /carbon-panel shows the session in the band above the prompt", async ($: any, on: any) => {
    const { opened } = world(on, { surfaces: ["terminal"] });
    await startSession($);
    const ui = await $.ui.mount(BAND);
    // Off until asked: the band is the engine's
    expect(await ui.find({ key: "mascot" })).toBeUndefined();
    await openPane($);
    // No pane: it would dock as a whole column in fullscreen rendering
    expect(opened).toEqual([]);
    await ui.redraw();
    const mascot = await ui.find({ key: "mascot" });
    expect(mascot.type).toBe("Raster");
    expect(mascot.props.columns).toBe(13);
    expect(mascot.props.rows).toBe(4);
    const text = await drawn(ui);
    expect(text).toContain("Cette session : en attente de la première réponse");
    // Over what the band already held
    expect(await ui.find({ key: "engine-band" })).toBeDefined();
    // Nothing of the period: no stripes, no figures, no buttons, no links
    expect(await ui.find({ type: "Button" })).toBeUndefined();
    expect(await ui.find({ type: "Link" })).toBeUndefined();
    expect(text).not.toContain("sur la période");
    // Again: off
    await openPane($);
    await ui.redraw();
    expect(await ui.find({ key: "mascot" })).toBeUndefined();
    await ui.unmount();
  });
  test("a survey keeps the band", async ($: any, on: any) => {
    world(on, { surfaces: ["terminal"] });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true } });
    expect(await ui.find({ key: "mascot" })).toBeUndefined();
  });
  test("a pane the desktop opened shows the session alone in a terminal", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect((await ui.find({ key: "mascot" })).type).toBe("Raster");
    expect(await drawn(ui)).toContain("Cette session : en attente de la première réponse");
    expect(await ui.find({ type: "Button" })).toBeUndefined();
    await ui.unmount();
  });
  test("the desktop app draws SVGs and no cells", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    expect(await ui.find({ type: "Raster" })).toBeUndefined();
    const svgs = (await ui.drawn()) as any;
    const all = JSON.stringify(svgs);
    expect(all).toContain('"type":"Svg"');
    expect(all).not.toContain("<script");
    // At rest it breathes: the slow pace, 2 x 1.2 s
    expect(all).toContain("2400ms");
    await ui.unmount();
  });

  test("the desktop side pane stacks the controls, with no key badges", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const range = await ui.find({ key: "range-30d" });
    expect(range.props.hotkey).toBeUndefined();
    expect(range.props.variant).toBe("primary");
    // The settings are a gear beside "Mon usage"
    const gear = await ui.find({ key: "customize" });
    expect(gear.props.label).toBe("\u2699");
    expect(gear.props.plain).toBe(true);
    expect(await ui.find({ key: "block-cost" })).toBeUndefined();
    await ui.press({ key: "customize" });
    expect(await ui.find({ key: "block-cost" })).toBeDefined();
    await ui.press({ key: "customize" });
    // The month lists show only for a custom range
    expect(await ui.find({ key: "from" })).toBeUndefined();
    // The stripes' caption stays short: what one stripe is and its median
    expect(await drawn(ui)).toContain("une bande par jour · médiane 300 gCO₂ par jour");
    await ui.unmount();
  });
  test("the pane sums the period and names the heaviest projects", async ($: any, on: any) => {
    const lines = [
      ["a", 3, 600, "carbonara"],
      ["b", 2, 300, "studio"],
      ["c", 1, 100, "carbonara"],
    ].map(([id, days, g, project]) => {
      const at = Math.floor((NOW - (days as number) * DAY) / 1000);
      return `${id}\t${at}\t${g}\t2\t${project}`;
    });
    const { store } = world(on, { history: `${lines.join("\n")}\n` });
    await startSession($);
    await openPane($);
    const desk = await $.ui.mount({ ...PANE, surface: "desktop" });
    // Projects are off until the person turns them on
    expect(await drawn(desk)).not.toContain("% carbonara");
    await desk.press({ key: "customize" });
    await desk.press({ key: "block-projects" });
    expect((store.get("pane.blocks") as any).projects).toBe(true);
    const text = await drawn(desk);
    expect(text).toContain("Sur la période\n1,0 kgCO₂");
    expect(text).toContain("70 % carbonara · 700 gCO₂");
    expect(text).toContain("30 % studio · 300 gCO₂");
    expect(text.indexOf("% carbonara") < text.indexOf("% studio")).toBe(true);
    await desk.unmount();
  });

  test("no main-model line, the car in a tile", async ($: any, on: any) => {
    // Three Opus sessions and one Sonnet
    const at = (days: number) => Math.floor((NOW - days * DAY) / 1000);
    const lines = [
      `a\t${at(4)}\t300\t2\tsite\t1\tclaude-opus-5-5`,
      `b\t${at(3)}\t300\t2\tsite\t1\tclaude-opus-5-5`,
      `c\t${at(2)}\t300\t2\tsite\t1\tclaude-opus-5-5`,
      `d\t${at(1)}\t100\t2\tsite\t1\tclaude-sonnet-5-5`,
    ];
    world(on, { history: lines.join("\n") });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(ui);
    expect(text).toContain("Mon usage");
    // The main model is not shown; the car is a tile of the period
    expect(text).not.toContain("Surtout");
    expect(text).toContain("En voiture\n≈ 7 km");
    expect(text).toContain("Développé par");
    const links = JSON.stringify(await ui.drawn());
    expect(links).toContain("https://gaetanwittebolle.com/?ref=carbon-panel");
    expect(links).toContain("https://tokenclimate.com/?ref=carbon-panel");
    expect(links).toContain("https://github.com/gwittebolle/claude-carbon/blob/main/METHODOLOGY.md");
    // The stripes' credit lives in the README only
    expect(links).not.toContain("showyourstripes.info");
    expect(text).not.toContain("Ed Hawkins");
    // The foot is the pane's last element, held at the bottom
    const tree = (await ui.drawn()) as any;
    // As tall as the rows the surface gives the pane's body (20 in these props)
    expect(tree.props.minHeight).toBe(20);
    expect(tree.props.justifyContent).toBe("space-between");
    expect(JSON.stringify(tree.children.at(-1))).toContain("TokenClimate");
    await ui.unmount();
  });

  test("the session block counts its answers and subagents", async ($: any, on: any) => {
    world(on);
    on("agent.spawn", ($: any, e: any) => ({ model: "claude-haiku-5-5", agentId: e.description }));
    await startSession($);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await $.agent.spawn({
      prompt: "explore",
      description: "agent-1",
      subagentType: "Explore",
      provider: { kind: "engine" },
      parentModel: "claude-opus-5-5",
      background: false,
    });
    await $.turn.complete({ answer: "ok", durationMs: 10, isAborted: false, turnId: "turn-1", reason: "answer" });
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    expect(await drawn(ui)).toContain("1 réponse · 1 sous-agent");
    // A small molecule for the subagent, under the big one
    const row = JSON.stringify(await ui.drawn());
    expect(row).toContain("1 sous-agent de cette session");
    await ui.unmount();
  });

  test("past eight subagents the row says how many more", async ($: any, on: any) => {
    world(on);
    on("agent.spawn", ($: any, e: any) => ({ model: "claude-haiku-5-5", agentId: e.description }));
    await startSession($);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    for (let i = 1; i <= 10; i++)
      await $.agent.spawn({
        prompt: "explore",
        description: `agent-${i}`,
        subagentType: "Explore",
        provider: { kind: "engine" },
        parentModel: "claude-opus-5-5",
        background: false,
      });
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const svgs: any[] = [];
    const walk = (node: any) => {
      if (node === null || typeof node !== "object") return;
      if (Array.isArray(node)) return node.forEach(walk);
      if (node.type === "Svg") svgs.push(node);
      walk(node.children);
    };
    walk(await ui.drawn());
    const row = svgs.find((s) => String(s.props.alt).startsWith("10 sous-agents"));
    expect(row).toBeDefined();
    expect((row.props.source.match(/<g class="m\d+">/g) ?? []).length).toBe(8);
    expect(await drawn(ui)).toContain("+2");
    await ui.unmount();
    // The terminal has no room for molecules: a coloured dot each, eight then "+2"
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    const dots = texts(await term.drawn()).filter((t) => t === "●");
    expect(dots.length).toBe(8);
    expect(await drawn(term)).toContain("+2");
    await term.unmount();
  });

  test("the card button puts /carbon-card in the prompt and never sends it", async ($: any, on: any) => {
    const { fills, submits } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "card" });
    await clock.settle();
    await ui.unmount();
    expect(fills.map((f) => f.text)).toEqual(["/carbon-card"]);
    expect(submits).toEqual([]);
  });

  test("after the card button the pane says the command waits in the prompt", async ($: any, on: any) => {
    const { toasts } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "card" });
    await clock.settle();
    const ready = "/carbon-card est dans le prompt : appuyez sur Entrée pour créer la carte.";
    expect(toasts.map((x) => x.replaceAll(NBSP, " "))).toContain(ready);
    expect(await drawn(ui)).toContain(ready);
    await ui.unmount();
    // Ten seconds later the line is gone
    await clock.advance(11_000);
    const again = await $.ui.mount({ ...PANE, surface: "desktop" });
    expect(await drawn(again)).not.toContain(ready);
    await again.unmount();
  });

  test("the card button leaves a draft alone", async ($: any, on: any) => {
    const { fills, toasts } = world(on, { draft: "half a thought" });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "card" });
    await clock.settle();
    await ui.unmount();
    expect(fills).toEqual([]);
    expect(toasts.map((t) => t.replaceAll(NBSP, " "))).toEqual([
      "Le prompt contient déjà un brouillon : videz-le pour obtenir la carte.",
    ]);
  });

  test("on the desktop the molecule walks in its SVG while Claude works", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const all = JSON.stringify(await ui.drawn());
    expect(all).toContain("@keyframes");
    expect(all).toContain("prefers-reduced-motion");
    await ui.unmount();
  });

  test("with no history file the pane says where the history comes from", async ($: any, on: any) => {
    world(on, { history: null });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(ui);
    expect(text).toContain(
      "L'historique de vos sessions vient avec l'installation complète",
    );
    expect(text).toContain(
      "Couleur provisoire : elle s'ajustera à vos habitudes après 10 sessions (0 pour l'instant).",
    );
    await ui.unmount();
    // The terminal says there is no history, not a count of none
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    const told = await drawn(term);
    expect(told).toContain("L'historique de vos sessions vient avec l'installation complète");
    expect(told).not.toContain("(0 pour l'instant)");
    await term.unmount();
  });

  test("under 10 past sessions the colour compares with 0.5 kgCO₂", async ($: any, on: any) => {
    world(on, { history: historyText(4) });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect(await drawn(ui)).toContain(
      "Couleur provisoire : elle s'ajustera à vos habitudes après 10 sessions (4 pour l'instant).",
    );
    await ui.unmount();
  });

  test("legacy sessions join the one series, with no divider", async ($: any, on: any) => {
    // 5 legacy sessions 60 to 56 days back, then the 20 current ones
    const legacy = Array.from({ length: 5 }, (_, i) => {
      const at = Math.floor((NOW - (60 - i) * DAY) / 1000);
      return `old-${i}\t${at}\t${1000 * (i + 1)}\t1`;
    });
    world(on, { history: `${legacy.join("\n")}\n${historyText(20)}` });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "range-1y" });
    const text = await drawn(ui);
    expect(text).toContain("Sur la période\n21,0 kgCO₂");
    expect(text).toContain("Sessions\n25");
    expect(text).toContain("une bande par semaine");
    expect(text).not.toContain("méthode");
    await ui.unmount();
  });
  test("the comparison, the API cost and the car equivalence under the total", async ($: any, on: any) => {
    // 300 g with $3 in the last 30 days, 200 g in the 30 days before
    const line = (id: string, days: number, g: number, usd: number) =>
      `${id}\t${Math.floor((NOW - days * DAY) / 1000)}\t${g}\t2\tsite\t${usd}`;
    world(on, {
      history: [line("a", 3, 200, 2), line("b", 2, 100, 1), line("c", 40, 200, 1)].join("\n"),
    });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(ui);
    // The tiles: the period, its change, its sessions, its API-price value
    expect(text).toContain(
      "Sur la période\n300 gCO₂\nPar rapport à avant\n+50 %\nSessions\n2\nValeur au prix API\n3,00 $",
    );
    expect(text).toContain("En voiture\n≈ 2 km");
    // The value never says who paid it: its tile has an (i) button, and a click shows
    // the note under the tiles, a second hides it
    const API_NOTE = "Le prix de cet usage facturé à l'API ; un abonnement Pro ou Max en couvre tout ou partie.";
    expect(text).not.toContain(API_NOTE);
    expect(await ui.find({ key: "note-cost" })).toBeDefined();
    expect(await ui.find({ key: "note-car" })).toBeDefined();
    await ui.press({ key: "note-cost" });
    expect(await drawn(ui)).toContain(API_NOTE);
    await ui.press({ key: "note-car" });
    expect(await drawn(ui)).toContain("142 gCO₂/km, ADEME 2025");
    expect(await drawn(ui)).not.toContain(API_NOTE);
    await ui.press({ key: "note-car" });
    expect(await drawn(ui)).not.toContain("142 gCO₂/km, ADEME 2025");
    // A tile with nothing to explain has no (i)
    expect(await ui.find({ key: "note-sessions" })).toBeUndefined();
    // Two days with sessions: the stripes wait for a third, and say so
    expect(text).toContain("Vos bandes de couleur apparaissent après 3 jours d'usage (2 pour l'instant)");
    // A rise is drawn in the error colour
    const rise = await ui.find({ type: "Text", text: "+50\u00a0%" });
    expect(rise.props.color).toBe("error");
    // Each one can be turned off
    await ui.press({ key: "customize" });
    await ui.press({ key: "block-cost" });
    expect(await drawn(ui)).not.toContain("prix API");
    await ui.unmount();
  });

  test("the range buttons and the custom dates change the view and keep it", async ($: any, on: any) => {
    const { store, toasts } = world(on, { history: historyText(200) });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "range-1y" });
    expect(store.get("pane.view")).toEqual({ range: "1y" });
    expect(await drawn(ui)).toContain("une bande par semaine");
    await ui.press({ key: "range-custom" });
    // Opens on the last 30 days
    expect(store.get("pane.view")).toEqual({ range: "custom", from: "2026-09-13", to: "2026-10-12" });
    await ui.input({ key: "from", text: "01/09/2026" });
    expect(store.get("pane.view")).toEqual({ range: "custom", from: "2026-09-01", to: "2026-10-12" });
    // A start after the end swaps them
    await ui.input({ key: "to", text: "2026-08-15" });
    expect(store.get("pane.view")).toEqual({ range: "custom", from: "2026-08-15", to: "2026-09-01" });
    // A date that does not read leaves the range and says how to type it
    await ui.input({ key: "from", text: "31/02/2026" });
    expect(store.get("pane.view")).toEqual({ range: "custom", from: "2026-08-15", to: "2026-09-01" });
    expect(toasts.map((x) => x.replaceAll(NBSP, " "))).toContain("Date non reconnue : tapez-la comme 01/05/2026.");
    const text = await drawn(ui);
    expect(text).toContain("une bande par jour");
    expect(text).toContain("15 août → 1 sept.");
    await ui.unmount();
  });
  test("the molecule walks while Claude works, then breathes slowly", async ($: any, on: any) => {
    const { blits } = world(on, { surfaces: ["terminal"] });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount(BAND);
    // At rest a slow bob, a blit at each hop and each change of face: it looks around
    await clock.advance(6000);
    const atRest = blits.length;
    expect(atRest >= 4 && atRest <= 14).toBe(true);
    expect(blits[0].key).toBe("mascot");
    expect(blits[0].requestId).toBe("band");
    expect(blits[0].columns).toBe(13);
    expect(new Set(blits.map((b: any) => b.cells)).size > 2).toBe(true);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    const before = blits.length;
    await clock.advance(3000);
    // Grey molecule, middle pace: a hop every 316 ms, faster than at rest
    const working = blits.length - before;
    expect(working >= 9).toBe(true);
    expect(working / 3 > atRest / 6).toBe(true);
    await $.turn.complete({
      answer: "done",
      durationMs: 3000,
      isAborted: false,
      turnId: "turn-1",
      reason: "answer",
    });
    const after = blits.length;
    await clock.advance(6000);
    expect(blits.length - after <= 14).toBe(true);
    await ui.unmount();
  });
  test("a turn the module lost track of still slows the walk down", async ($: any, on: any) => {
    const { blits } = world(on, { surfaces: ["terminal"] });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount(BAND);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(2000);
    // As after a reload: the end of a turn this module never saw start
    await $.turn.complete({
      answer: "done",
      durationMs: 2000,
      isAborted: false,
      turnId: "turn-unknown",
      reason: "answer",
    });
    await clock.advance(1300);
    const after = blits.length;
    await clock.advance(6000);
    // Walking, six seconds would take some twenty
    expect(blits.length - after <= 14).toBe(true);
    expect(blits.length > 0).toBe(true);
    await ui.unmount();
  });
  test("the band off, the walk stops", async ($: any, on: any) => {
    const { blits } = world(on, { surfaces: ["terminal"] });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount(BAND);
    await clock.advance(3000);
    await openPane($);
    const after = blits.length;
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(5000);
    expect(blits.length).toBe(after);
    await ui.unmount();
  });
  test("the desktop molecule reacts to an answer, then falls asleep", async ($: any, on: any) => {
    world(on, { history: historyText(40) });
    await startSession($);
    await openPane($);
    const faces = async () => {
      const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
      const sources: string[] = [];
      const walk = (node: any) => {
        if (node === null || typeof node !== "object") return;
        if (Array.isArray(node)) return node.forEach(walk);
        if (node.type === "Svg") sources.push(node.props.source);
        walk(node.children);
      };
      walk(await ui.drawn());
      await ui.unmount();
      // The big molecule is the first drawing
      return sources[0] ?? "";
    };
    // No answer yet: it looks around
    expect(await faces()).toContain("f-lookLeft");
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await $.turn.complete({
      answer: "done",
      durationMs: 1000,
      isAborted: false,
      turnId: "turn-1",
      reason: "answer",
    });
    // Right after the answer, a smile and nothing else
    const pleased = await faces();
    expect(pleased).toContain("f-happy");
    expect(pleased).not.toContain("f-blink");
    await clock.advance(5 * 60_000 + 1000);
    expect(await faces()).toContain("f-sleep");
  });
  test("no walk without the pane open", async ($: any, on: any) => {
    const { blits } = world(on);
    await startSession($);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(5000);
    expect(blits).toEqual([]);
  });

  test("someone welcomed before the pane existed hears of /carbon-panel once", async ($: any, on: any) => {
    const { toasts } = world(on, { hinted: false });
    await startSession($);
    await startSession($);
    expect(toasts.map((t) => t.replaceAll(NBSP, " "))).toEqual([
      "Tapez /carbon-panel pour voir votre molécule et l'historique de vos sessions.",
    ]);
  });

  test("no hint for a /carbon-panel that is someone else's", async ($: any, on: any) => {
    const { toasts } = world(on, { hinted: false, commandTaken: true });
    await startSession($);
    expect(toasts).toEqual([]);
  });

  test("the whole history stays within the desktop app's Svg limit", async ($: any, on: any) => {
    world(on, { history: historyText(3000) });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "range-all" });
    const tree = await ui.drawn();
    const sources: string[] = [];
    const walk = (node: any) => {
      if (node === null || typeof node !== "object") return;
      if (Array.isArray(node)) return node.forEach(walk);
      if (node.type === "Svg") sources.push(node.props.source);
      walk(node.children);
    };
    walk(tree);
    // The molecule, its colour scale and the stripes
    expect(sources.length).toBe(3);
    expect(sources.every((s) => s.length <= 131072)).toBe(true);
    // About eight years, one stripe a month, with the years written out
    expect(await drawn(ui)).toContain("une bande par mois");
    await ui.unmount();
  });
  test("a first welcome comes alone: the hint waits for the next session", async ($: any, on: any) => {
    const { toasts } = world(on, { welcomed: false, hinted: false });
    await startSession($);
    expect(toasts).toEqual([
      "Le CO₂ s'affiche maintenant pour chaque réponse.",
    ]);
  });

  test("the pane writes nothing, calls no network and starts no process", async ($: any, on: any) => {
    const { writes, fetches, processes } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    await ui.press({ key: "range-all" });
    await ui.press({ key: "customize" });
    await ui.press({ key: "block-projects" });
    await ui.unmount();
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(2000);
    await term.unmount();
    expect(writes).toEqual([]);
    expect(fetches).toEqual([]);
    expect(processes).toEqual([]);
  });
});
