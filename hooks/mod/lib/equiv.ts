// The car equivalence of the /carbon-panel pane: the same set, factor, label and source
// as /carbon-report and the cards (data/factors.json "equivalences", set picked as
// scripts/equiv-lib.sh detect_equiv_set picks it). Pure: no Claude Code API.

export type CarEquivalence = {
  // gCO2e per unit driven
  divisor: number;
  // "km" or "miles"
  unit: string;
  // "km en voiture", "miles driven by car"
  label: string;
  // "142 g/km, ADEME 2025"
  tag: string;
};

// The first locale variable that speaks (C and POSIX are sentinels), as the bash
// does: France's set for fr / fr_FR, the US set for a US locale, the world set
// otherwise. None set (the desktop app): French when the language is French, else
// the world set.
export function equivalenceSet(
  envValues: ReadonlyArray<string | undefined>,
  lang: "fr" | "en",
): "fr" | "us" | "world" {
  const value = envValues.find(
    (v) =>
      v !== undefined &&
      v !== "" &&
      v !== "C" &&
      !v.startsWith("C.") &&
      v !== "POSIX" &&
      !v.startsWith("POSIX."),
  );
  if (value === undefined) return lang === "fr" ? "fr" : "world";
  if (/^(fr|fr\..*|fr_FR.*|fr-FR.*)$/.test(value)) return "fr";
  if (/^(us|US|.*_US.*|.*-US.*)$/.test(value)) return "us";
  return "world";
}

// The set's car row, or null when the file does not hold one that reads.
export function carEquivalence(
  factorsJson: unknown,
  set: string,
): CarEquivalence | null {
  const sets = (factorsJson as { equivalences?: Record<string, unknown> })
    ?.equivalences;
  const rows = sets?.[set];
  if (!Array.isArray(rows)) return null;
  const car = rows.find(
    (r): r is Record<string, unknown> =>
      typeof r === "object" && r !== null && (r as { id?: unknown }).id === "car",
  );
  if (car === undefined) return null;
  const { divisor, unit, label, tag } = car;
  if (
    typeof divisor !== "number" ||
    !(divisor > 0) ||
    typeof unit !== "string" ||
    typeof label !== "string" ||
    typeof tag !== "string"
  )
    return null;
  return { divisor, unit, label, tag };
}
