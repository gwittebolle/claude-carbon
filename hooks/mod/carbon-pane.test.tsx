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
    haiku: { input: 20, output: 413 },
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
  // The history file's text; null: no file (an install without the database)
  history?: string | null;
  welcomed?: boolean;
  hinted?: boolean;
  // Another extension already took /carbon-panel
  commandTaken?: boolean;
  // What the prompt box holds
  draft?: string;
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
        options.history === undefined ? historyText(20) : options.history;
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
  on("session.surfaces", () => ({ value: ["terminal"] }));
  on("session.id", () => ({ value: SESSION_ID }));
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
  test("/carbon-panel is registered, opens the pane without the keyboard, and closes it", async ($: any, on: any) => {
    const { opened, closed, registered } = world(on);
    await startSession($);
    expect(registered.map((c) => c.name)).toEqual(["carbon-panel"]);
    expect(registered[0].immediate).toBe(true);
    await openPane($);
    expect(opened).toEqual([
      { id: "carbon", title: "claude-carbon", closeOnEscape: true, rows: 10, columns: 48 },
    ]);
    await openPane($);
    expect(closed).toEqual(["carbon"]);
  });

  test("the terminal draws the molecule and the stripes as cells", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    const mascot = await ui.find({ key: "mascot" });
    expect(mascot.type).toBe("Raster");
    expect(mascot.props.columns).toBe(13);
    expect(mascot.props.rows).toBe(4);
    const stripes = await ui.find({ key: "stripes" });
    expect(stripes.type).toBe("Raster");
    // From the first session, 20 days back, to today: 21 days, two columns each
    expect(stripes.props.columns).toBe(42);
    expect(stripes.props.rows).toBe(2);
    const text = await drawn(ui);
    expect(text).toContain("Cette session : en attente de la première réponse");
    expect(text).toContain("22 sept. → 12 oct. · une bande par jour · médiane 300 gCO₂ par jour");
    // 20 past sessions; the running one's own row is not counted twice
    expect(text).toContain("6,0 kgCO₂ sur la période");
    expect(text).toContain("20 sessions");
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
    expect(await ui.find({ key: "block-portrait" })).toBeUndefined();
    await ui.press({ key: "customize" });
    expect(await ui.find({ key: "block-portrait" })).toBeDefined();
    await ui.press({ key: "customize" });
    // The month lists show only for a custom range
    expect(await ui.find({ key: "from" })).toBeUndefined();
    // The stripes' caption stays short: what one stripe is and its median
    expect(await drawn(ui)).toContain("une bande par jour · médiane 300 gCO₂ par jour");
    await ui.unmount();
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect((await term.find({ key: "range-30d" })).props.hotkey).toBe("2");
    await term.unmount();
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
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect(await drawn(term)).toContain("surtout carbonara 70 %, studio 30 %");
    await term.unmount();
  });

  test("the main model under the stripes, the car in a tile", async ($: any, on: any) => {
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
    // The model on its own line, the car in a tile of the period: side by side, the km
    // read as Opus's share
    expect(text).toContain("Surtout Opus (90 %)");
    expect(text).not.toContain("Surtout Opus (90 %) ·");
    expect(text).toContain("En voiture\n≈ 7 km");
    expect(text).toContain("Développé par");
    const links = JSON.stringify(await ui.drawn());
    expect(links).toContain("https://gaetanwittebolle.com/?ref=carbon-panel");
    expect(links).toContain("https://tokenclimate.com/?ref=carbon-panel");
    expect(links).toContain("https://github.com/gwittebolle/claude-carbon/blob/main/METHODOLOGY.md");
    // The foot is the pane's last element, held at the bottom
    const tree = (await ui.drawn()) as any;
    // As tall as the rows the surface gives the pane's body (20 in these props)
    expect(tree.props.minHeight).toBe(20);
    expect(tree.props.justifyContent).toBe("space-between");
    expect(JSON.stringify(tree.children.at(-1))).toContain("TokenClimate");
    // The main model can be turned off under the gear
    await ui.press({ key: "customize" });
    await ui.press({ key: "block-portrait" });
    expect(await drawn(ui)).not.toContain("Surtout Opus");
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
  });

  test("the card button puts /carbon-card in the prompt and never sends it", async ($: any, on: any) => {
    const { fills, submits } = world(on);
    await startSession($);
    await openPane($);
    for (const surface of ["terminal", "desktop"] as const) {
      const ui = await $.ui.mount({ ...PANE, surface });
      await ui.press({ key: "card" });
      await clock.settle();
      await ui.unmount();
    }
    expect(fills.map((f) => f.text)).toEqual(["/carbon-card", "/carbon-card"]);
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
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
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
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    const text = await drawn(ui);
    expect(text).toContain(
      "L'historique de vos sessions vient avec l'installation complète",
    );
    expect(text).toContain(
      "La couleur arrive après 10 sessions (0 pour l'instant).",
    );
    expect(await ui.find({ key: "stripes" })).toBeUndefined();
    await ui.unmount();
  });

  test("under 10 past sessions the molecule waits for its colour", async ($: any, on: any) => {
    world(on, { history: historyText(4) });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect(await drawn(ui)).toContain(
      "La couleur arrive après 10 sessions (4 pour l'instant).",
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
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    await ui.press({ key: "range-1y" });
    const text = await drawn(ui);
    expect(text).toContain("21,0 kgCO₂ sur la période");
    expect(text).toContain("25 sessions");
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
    // The value never says who paid it: its (i) explains on hover, taking no line
    expect(text).not.toContain("un abonnement Pro ou Max");
    expect(JSON.stringify(await ui.drawn()).replaceAll("\u00a0", " ")).toContain(
      "Le prix de cet usage facturé à l'API ; un abonnement Pro ou Max en couvre tout ou partie.",
    );
    expect(text).toContain("En voiture\n≈ 2 km");
    expect(JSON.stringify(await ui.drawn()).replaceAll("\u00a0", " ")).toContain(
      "142 gCO₂/km, ADEME 2025",
    );
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
    const { blits } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    // At rest, one frame every 1.2 s
    await clock.advance(6000);
    expect(blits.length).toBe(5);
    expect(blits[0].key).toBe("mascot");
    expect(blits[0].columns).toBe(13);
    await $.turn.start({ text: "go", turnId: "turn-1" });
    const before = blits.length;
    await clock.advance(3000);
    // Grey molecule, middle pace: a step every 316 ms once the rest step is done
    expect(blits.length - before >= 5).toBe(true);
    await $.turn.complete({
      answer: "done",
      durationMs: 3000,
      isAborted: false,
      turnId: "turn-1",
      reason: "answer",
    });
    const after = blits.length;
    await clock.advance(6000);
    expect(blits.length - after <= 6).toBe(true);
    await ui.unmount();
  });
  test("a turn the module lost track of still slows the walk down", async ($: any, on: any) => {
    const { blits } = world(on);
    await startSession($);
    await openPane($);
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
    expect(blits.length - after).toBe(5);
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
    // The molecule, the stripes, and the car tile's (i)
    expect(sources.length).toBe(3);
    expect(sources.every((s) => s.length <= 131072)).toBe(true);
    // About eight years, one stripe a month, with the years written out
    expect(await drawn(ui)).toContain("une bande par mois");
    await ui.unmount();
  });
  test("a terminal Raster never goes past 512 columns", async ($: any, on: any) => {
    // Some 55 years of daily sessions: 660 months
    world(on, { history: historyText(20000) });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({
      ...PANE,
      surface: "terminal",
      props: { ...PANE.props, bodyColumns: 900 },
    });
    await ui.press({ key: "range-all" });
    expect((await ui.find({ key: "stripes" })).props.columns).toBe(512);
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
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    await ui.press({ key: "range-all" });
    await ui.press({ key: "customize" });
    await ui.press({ key: "block-projects" });
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(2000);
    await ui.unmount();
    expect(writes).toEqual([]);
    expect(fetches).toEqual([]);
    expect(processes).toEqual([]);
  });
});
