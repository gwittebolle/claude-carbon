import { describe, expect, mock, test } from "claude-code/testing";

const PLUGIN = "claude-carbon";
const NBSP = "\u00a0";
const DAY = 86_400_000;
// 12 Oct 2026, noon UTC
const NOW = Date.UTC(2026, 9, 12, 12);
const SESSION_ID = "session-now";

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
      { id: "carbon", title: "Carbone", closeOnEscape: true, rows: 10, columns: 48 },
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
    // 20 past sessions in 30 days, two columns each in 58; the running one has no
    // total yet
    expect(stripes.props.columns).toBe(40);
    expect(stripes.props.rows).toBe(2);
    const text = await drawn(ui);
    expect(text).toContain("Cette session : < 0,1 gCO₂");
    expect(text).toContain(
      "30 derniers jours · 20 sessions · médiane 300 gCO₂",
    );
    // The running session's own row in the file is not a past session
    expect(text).not.toContain("21 sessions");
    // The range's first and last stripe on one line
    expect(text).toContain("22 sept. → 11 oct.");
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
    // Standing: frame A alone, no animation
    expect(all).not.toContain("@keyframes");
    await ui.unmount();
  });

  test("the desktop side pane stacks the controls, with no key badges", async ($: any, on: any) => {
    world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(ui);
    expect(text).toContain("Période");
    expect(text).toContain("Une bande par");
    const range = await ui.find({ key: "range-30d" });
    expect(range.props.hotkey).toBeUndefined();
    expect(range.props.variant).toBe("primary");
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
    world(on, { history: `${lines.join("\n")}\n` });
    await startSession($);
    await openPane($);
    const desk = await $.ui.mount({ ...PANE, surface: "desktop" });
    const text = await drawn(desk);
    expect(text).toContain("Sur la période : 1,0 kgCO₂ · 3 sessions");
    expect(text).toContain("carbonara · 700 gCO₂ · 70 %");
    expect(text).toContain("studio · 300 gCO₂ · 30 %");
    expect(text.indexOf("carbonara ·") < text.indexOf("studio ·")).toBe(true);
    await desk.unmount();
    const term = await $.ui.mount({ ...PANE, surface: "terminal" });
    expect(await drawn(term)).toContain("surtout carbonara 70 %, studio 30 %");
    await term.unmount();
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
      "Le prompt contient déjà un brouillon : videz-le pour préparer la carte.",
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

  test("legacy sessions show apart, after a divider, with their own median", async ($: any, on: any) => {
    // 5 legacy sessions 60 to 56 days back, then the 20 current ones
    const legacy = Array.from({ length: 5 }, (_, i) => {
      const at = Math.floor((NOW - (60 - i) * DAY) / 1000);
      return `old-${i}\t${at}\t${1000 * (i + 1)}\t1`;
    });
    world(on, { history: `${legacy.join("\n")}\n${historyText(20)}` });
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    await ui.press({ key: "range-90d" });
    const text = await drawn(ui);
    // The molecule's median is the current sessions' alone: 300, not pulled by 1-5 kg
    expect(text).toContain("médiane 300 gCO₂");
    expect(text).toContain("25 sessions");
    expect(text).toContain("┃ changement de méthode");
    const stripes = await ui.find({ key: "stripes" });
    // 25 stripes and a divider in 58 columns: two columns each, one for the divider
    expect(stripes.props.columns).toBe(51);
    await ui.unmount();
  });

  test("the range and step buttons change the view and keep it for next time", async ($: any, on: any) => {
    const { store } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    await ui.press({ key: "step-week" });
    await ui.press({ key: "range-90d" });
    expect(store.get("pane.view")).toEqual({ range: "90d", step: "week" });
    const text = await drawn(ui);
    expect(text).toContain("90 derniers jours · ");
    expect(text).toContain("semaines");
    expect(text).toContain("par semaine");
    await ui.unmount();
  });

  test("the molecule walks while Claude works, and stops after", async ($: any, on: any) => {
    const { blits } = world(on);
    await startSession($);
    await openPane($);
    const ui = await $.ui.mount({ ...PANE, surface: "terminal" });
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(3000);
    expect(blits.length > 3).toBe(true);
    expect(blits[0].key).toBe("mascot");
    expect(blits[0].columns).toBe(13);
    await $.turn.complete({
      answer: "done",
      durationMs: 3000,
      isAborted: false,
      turnId: "turn-1",
      reason: "answer",
    });
    const after = blits.length;
    await clock.advance(5000);
    expect(blits.length).toBe(after);
    await ui.unmount();
  });

  test("a turn the module lost track of still stops the walk", async ($: any, on: any) => {
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
    const after = blits.length;
    await clock.advance(5000);
    expect(blits.length).toBe(after);
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

  test("thousands of sessions stay within the desktop app's Svg limit", async ($: any, on: any) => {
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
    expect(sources.length).toBe(2);
    expect(sources.every((s) => s.length <= 131072)).toBe(true);
    expect((await drawn(ui)).includes("180 sessions les plus récentes sur 3000")).toBe(true);
    await ui.unmount();
  });

  test("a terminal Raster never goes past 512 columns", async ($: any, on: any) => {
    world(on, { history: historyText(1000) });
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
    await ui.press({ key: "step-month" });
    await $.turn.start({ text: "go", turnId: "turn-1" });
    await clock.advance(2000);
    await ui.unmount();
    expect(writes).toEqual([]);
    expect(fetches).toEqual([]);
    expect(processes).toEqual([]);
  });
});
