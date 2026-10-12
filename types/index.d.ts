// The values the claude-carbon mod keeps in $.state for the session.

export type AnswerCo2 = {
  main: string;
  sub: string | null;
  isUnusual: boolean;
};

// One main-loop turn, written when it ends (`at`, ms since the epoch). Its duration
// line takes it when first drawn within a second of that (hooks/mod/lib/lines.ts).
// A turn that counted nothing (an excluded model, no usage) keeps a null co2.
export type AnswerCo2Entry = {
  turnId: string;
  durationMs: number;
  at: number;
  co2: AnswerCo2 | null;
};

// usd: the API-price cost (data/prices.json) of the same requests as grams. Absent once
// one of them could not be priced (no price list read, or a total kept from code that
// counted no cost): a part of the cost is never shown as the whole.
export type SessionTotal = {
  grams: number;
  usd?: number;
  turns: number;
};

// What the /carbon pane shows: how far back, and one stripe per session, week or month.
export type PaneView = {
  range: "7d" | "30d" | "90d" | "1y" | "all";
  step: "session" | "week" | "month";
};

declare module "claude-code" {
  interface PluginState {
    "claude-carbon": {
      answers: AnswerCo2Entry[];
      session: SessionTotal;
      // True from a main-loop turn's start to its end: the molecule walks.
      working: boolean;
      view: PaneView;
    };
  }
}
