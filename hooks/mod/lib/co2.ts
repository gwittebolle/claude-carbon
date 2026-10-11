// CO2 of one model request, with the same formula, factors and model resolution as the
// bash plugin (METHODOLOGY.md, scripts/portable-lib.sh: cc_family, cc_params,
// cc_is_excluded_model). Checked against tests/methodology-vectors*.json by
// tests/run-mod-tests.mjs. Pure: no Claude Code API, so Node runs it directly.

export type Family = "fable" | "opus" | "sonnet" | "haiku";

export type FamilyFactors = { input: number; output: number };

export type Factors = {
  models: Record<Family, FamilyFactors>;
  cacheReadFactor: number;
  excludeModels: string[];
};

export type TokenUsage = {
  input_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  output_tokens: number;
};

// The jq fallbacks in CC_JQ_MODEL_DEFS, used when factors.json lacks a value.
export const DEFAULT_FACTORS: Factors = {
  models: {
    fable: { input: 156, output: 3304 },
    opus: { input: 78, output: 1652 },
    sonnet: { input: 39, output: 826 },
    haiku: { input: 20, output: 413 },
  },
  cacheReadFactor: 0.08,
  excludeModels: [],
};

const FAMILIES: Family[] = ["fable", "opus", "sonnet", "haiku"];

export function family(model: string): Family {
  const m = model.toLowerCase();
  if (m.includes("haiku")) return "haiku";
  if (m.includes("opus")) return "opus";
  if (/fable|mythos/.test(m)) return "fable";
  return "sonnet";
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

// Reads data/factors.json as parsed JSON, falling back per value like `//` in jq.
export function parseFactors(json: unknown): Factors {
  const root = (
    typeof json === "object" && json !== null ? json : {}
  ) as Record<string, unknown>;
  const models = (
    typeof root.models === "object" && root.models !== null ? root.models : {}
  ) as Record<string, Record<string, unknown> | undefined>;
  const resolved = {} as Record<Family, FamilyFactors>;
  for (const name of FAMILIES) {
    const entry = models[name] ?? {};
    resolved[name] = {
      input: numberOr(entry.input, DEFAULT_FACTORS.models[name].input),
      output: numberOr(entry.output, DEFAULT_FACTORS.models[name].output),
    };
  }
  const exclude = Array.isArray(root.exclude_models)
    ? root.exclude_models.filter(
        (p): p is string => typeof p === "string" && p !== "",
      )
    : [];
  return {
    models: resolved,
    cacheReadFactor: numberOr(
      root.cache_read_factor,
      DEFAULT_FACTORS.cacheReadFactor,
    ),
    excludeModels: exclude,
  };
}

// Not an Anthropic Claude model (a local model behind ANTHROPIC_BASE_URL, the
// "<synthetic>" marker), or matching one of the user's exclude_models patterns.
export function isExcluded(model: string, patterns: string[]): boolean {
  if (!/claude/i.test(model)) return true;
  return patterns.some((pattern) => {
    try {
      return new RegExp(pattern, "i").test(model);
    } catch {
      return false;
    }
  });
}

// input_tokens is the uncached input; cache writes are a full prefill at the input
// factor; cache reads at cache_read_factor of it.
export function co2Grams(
  usage: TokenUsage,
  model: string,
  factors: Factors,
): number {
  const f = factors.models[family(model)];
  const input = usage.input_tokens + usage.cache_creation_input_tokens;
  return (
    (input * f.input +
      usage.cache_read_input_tokens * (f.input * factors.cacheReadFactor) +
      usage.output_tokens * f.output) /
    1e6
  );
}
