// API-price cost of one model request, with the same formula, prices and model resolution
// as the bash plugin's cost_usd (METHODOLOGY.md, scripts/portable-lib.sh: cc_override,
// cc_params, CC_AWK_PRICE). Checked against the expected_cost_usd of
// tests/methodology-vectors*.json by tests/run-mod-tests.mjs. Pure: no Claude Code API,
// so Node runs it directly.

import { family } from "./co2.ts";
import type { Family, TokenUsage } from "./co2.ts";

export type FamilyPrices = { input: number; output: number };

// What a model_overrides entry may set; anything left out falls back to the family
// price and the global multipliers.
export type PriceOverride = {
  input?: number;
  output?: number;
  cacheWriteMultiplier?: number;
  cacheWriteMultiplier1h?: number;
  cacheReadMultiplier?: number;
};

export type Prices = {
  models: Record<Family, FamilyPrices>;
  overrides: Array<[string, PriceOverride]>;
  cacheWriteMultiplier: number;
  cacheWriteMultiplier1h: number;
  cacheReadMultiplier: number;
};

// One model's prices once resolved, in USD per million tokens.
export type ModelPrices = {
  input: number;
  output: number;
  cacheWriteMultiplier: number;
  cacheWriteMultiplier1h: number;
  cacheReadMultiplier: number;
};

// The jq fallbacks in CC_JQ_MODEL_DEFS, used when prices.json lacks a value.
export const DEFAULT_PRICES: Prices = {
  models: {
    fable: { input: 10, output: 50 },
    opus: { input: 4, output: 20 },
    sonnet: { input: 2, output: 10 },
    haiku: { input: 0.1, output: 0.5 },
  },
  overrides: [],
  cacheWriteMultiplier: 1.25,
  cacheWriteMultiplier1h: 2.0,
  cacheReadMultiplier: 0.1,
};

const FAMILIES: Family[] = ["fable", "opus", "sonnet", "haiku"];

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

// Reads data/prices.json as parsed JSON, falling back per value like `//` in jq. Null
// when it is not a JSON object: there is no price to show then.
export function parsePrices(json: unknown): Prices | null {
  if (!isObject(json)) return null;
  const models = isObject(json.models) ? json.models : {};
  const resolved = {} as Record<Family, FamilyPrices>;
  for (const name of FAMILIES) {
    const entry = isObject(models[name]) ? models[name] : {};
    resolved[name] = {
      input: numberOr(entry.input, DEFAULT_PRICES.models[name].input),
      output: numberOr(entry.output, DEFAULT_PRICES.models[name].output),
    };
  }
  const overrides: Array<[string, PriceOverride]> = [];
  if (isObject(json.model_overrides)) {
    for (const [key, value] of Object.entries(json.model_overrides)) {
      if (key.startsWith("_") || !isObject(value)) continue;
      overrides.push([
        key.toLowerCase(),
        {
          input: numberOrUndefined(value.input),
          output: numberOrUndefined(value.output),
          cacheWriteMultiplier: numberOrUndefined(value.cache_write_multiplier),
          cacheWriteMultiplier1h: numberOrUndefined(
            value.cache_write_multiplier_1h,
          ),
          cacheReadMultiplier: numberOrUndefined(value.cache_read_multiplier),
        },
      ]);
    }
  }
  return {
    models: resolved,
    overrides,
    cacheWriteMultiplier: numberOr(
      json.cache_write_multiplier,
      DEFAULT_PRICES.cacheWriteMultiplier,
    ),
    cacheWriteMultiplier1h: numberOr(
      json.cache_write_multiplier_1h,
      DEFAULT_PRICES.cacheWriteMultiplier1h,
    ),
    cacheReadMultiplier: numberOr(
      json.cache_read_multiplier,
      DEFAULT_PRICES.cacheReadMultiplier,
    ),
  };
}

// A key matches the id exactly, or as a prefix followed by nothing but a dated snapshot
// suffix "-YYYYMMDD"; a trailing context marker such as "[1m]" is ignored; the longest
// matching key wins.
export function priceOverride(
  model: string,
  overrides: Array<[string, PriceOverride]>,
): PriceOverride {
  const m = model.toLowerCase().replace(/\[[^\]]*\]$/, "");
  let best: [string, PriceOverride] | undefined;
  for (const entry of overrides) {
    const [key] = entry;
    const isMatch =
      m === key ||
      (m.startsWith(`${key}-`) && /^[0-9]{8}$/.test(m.slice(key.length + 1)));
    if (isMatch && (best === undefined || key.length > best[0].length)) {
      best = entry;
    }
  }
  return best?.[1] ?? {};
}

export function modelPrices(model: string, prices: Prices): ModelPrices {
  const base = prices.models[family(model)];
  const o = priceOverride(model, prices.overrides);
  return {
    input: o.input ?? base.input,
    output: o.output ?? base.output,
    cacheWriteMultiplier: o.cacheWriteMultiplier ?? prices.cacheWriteMultiplier,
    cacheWriteMultiplier1h:
      o.cacheWriteMultiplier1h ?? prices.cacheWriteMultiplier1h,
    cacheReadMultiplier: o.cacheReadMultiplier ?? prices.cacheReadMultiplier,
  };
}

// cacheWrite1h is the part of the cache writes at the 1-hour tier, clamped to the
// total write; the rest is priced at the 5-minute tier. turn.step does not split the
// writes by tier: left out, they are all at the 1-hour tier, the one Claude Code writes
// at (data/prices.json, _cache_write_multipliers).
export function costUsd(
  usage: TokenUsage,
  model: string,
  prices: Prices,
  cacheWrite1h: number = usage.cache_creation_input_tokens,
): number {
  const p = modelPrices(model, prices);
  const write = usage.cache_creation_input_tokens;
  const write1h = Math.min(Math.max(cacheWrite1h, 0), write);
  return (
    (usage.input_tokens * p.input +
      write1h * (p.input * p.cacheWriteMultiplier1h) +
      (write - write1h) * (p.input * p.cacheWriteMultiplier) +
      usage.cache_read_input_tokens * (p.input * p.cacheReadMultiplier) +
      usage.output_tokens * p.output) /
    1e6
  );
}
