// The values the claude-carbon mod keeps in $.state for the session.

export type AnswerCo2 = {
  main: string;
  sub: string | null;
  isUnusual: boolean;
};

// One main-loop turn, keyed by the duration turn.complete reports and its line draws.
// A turn that counted nothing (an excluded model, no usage) keeps a null co2.
export type AnswerCo2Entry = {
  durationMs: number;
  co2: AnswerCo2 | null;
};

export type SessionTotal = {
  grams: number;
  turns: number;
};

declare module "claude-code" {
  interface PluginState {
    "claude-carbon": {
      answers: AnswerCo2Entry[];
      session: SessionTotal;
    };
  }
}
