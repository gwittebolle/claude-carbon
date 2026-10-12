// Which turn a duration line belongs to. Pure: no Claude Code API, so Node runs it
// directly (tests/run-mod-tests.mjs).

// A line drawn for the first time this close to a turn's end is that turn's line.
// Measured in a terminal: 8 to 13 ms from turn.complete to the line's first draw.
export const BIND_WINDOW_MS = 1000;

// What the rules read of an entry. An entry written before the turnId was kept has
// none and is never bound.
export type LineEntry = {
  turnId?: unknown;
  at?: unknown;
};

export type LineMatch<E> = { entry: E; isNew: boolean } | undefined;

// The lines bound so far: each line's turn, and the turns that have a line.
export type Bound = {
  turnOf: ReadonlyMap<string, string>;
  taken: ReadonlySet<string>;
};

// 1. The entry of the turn this line was bound to. 2. A line drawn for the first
// time within a second of a turn's end takes the newest such entry no line holds
// yet. 3. None: the engine's line stays as it is. The duration is never compared:
// after background agents the line can show another one than the turn reports.
export function lineEntry<E extends LineEntry>(
  entries: readonly E[],
  requestId: string,
  firstDrawnAt: number,
  bound: Bound,
): LineMatch<E> {
  const turnId = bound.turnOf.get(requestId);
  if (turnId !== undefined) {
    const entry = entries.find((x) => x.turnId === turnId);
    return entry === undefined ? undefined : { entry, isNew: false };
  }
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i];
    if (
      entry !== undefined &&
      typeof entry.turnId === "string" &&
      typeof entry.at === "number" &&
      !bound.taken.has(entry.turnId) &&
      Math.abs(firstDrawnAt - entry.at) < BIND_WINDOW_MS
    ) {
      return { entry, isNew: true };
    }
  }
  return undefined;
}
