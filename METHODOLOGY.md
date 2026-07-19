# Methodology

## Overview

Emissions are estimated from token counts using per-token factors derived from peer-reviewed research. The approach is intentionally simple: one number per model family per token direction. No real-time data, no per-request tracing.

## Source

Jegham et al. (2025), "How Hungry is AI? Benchmarking the Energy, Water, and Carbon Footprint of LLM Inference" (v6)
[arxiv.org/abs/2505.09598](https://arxiv.org/abs/2505.09598)

The paper measures inference energy consumption on AWS infrastructure for a range of models, then converts to CO2e using grid-average carbon intensity. For Claude 3.7 Sonnet it reports three per-query energies (Table 4, PUE included): **0.950 Wh** (100 input / 300 output), **2.989 Wh** (1k / 1k) and **5.671 Wh** (10k input / 1.5k output).

### Deriving the Sonnet input/output factors

The three measured points are fit with an ordinary least-squares regression through the origin in (energy per input token, energy per output token), matching the per-token model below (no per-query constant). That gives ~1.35e-4 Wh per input token and ~2.88e-3 Wh per output token. At CIF 0.287 gCO2e/Wh (= 0.287 kgCO2e/kWh) that is **~39 gCO2e/Mtok input** and **~826 gCO2e/Mtok output**, a marginal ratio of ~21:1. The fit matches the two high-token configurations (1k/1k, 10k/1.5k) to within 1%, the regime real Claude Code sessions live in.

These are the best available data to date and will keep being refined as measurements improve. Earlier releases used 190/1140, calibrated against an earlier revision of the same preprint; the move to v6's three measured points refines that.

### Cross-validation against EcoLogits

[EcoLogits](https://ecologits.ai) (GenAI Impact / Data For Good) estimates inference impact by a completely independent route: model parameter counts plus a full lifecycle model, rather than measured AWS telemetry. Its estimate for Claude 3.7 Sonnet brackets **~565-1385 gCO2e/Mtok output** (parameter range, USA grid, full lifecycle), with a usage-only central value near ~630. The Jegham-derived **826** sits inside that band. Two unrelated methodologies agreeing is strong corroboration. Note one structural difference: EcoLogits charges zero energy to input tokens, whereas Jegham's measurements show a small but real input cost (the 10k-input query consumes more), which this tool keeps via the input factor.

### A third independent estimate (Couch, 2026)

[Simon Couch's January 2026 analysis of AI coding agents](https://simonpcouch.com/blog/2026-01-20-cc-impact/) derives Claude per-token energy by yet another route: Epoch AI's GPT-4o per-query estimate scaled by Anthropic's API price ratios. His self-described pessimistic figures are ~390 Wh/Mtok input and ~1,950 Wh/Mtok output. The Jegham-derived Sonnet factors used here are equivalent to ~136 Wh/Mtok input and ~2,880 Wh/Mtok output. Three unrelated routes (measured AWS telemetry, parameter-count lifecycle modeling, price-ratio scaling) landing within ~1.5x of each other on output tokens is about as much corroboration as public data allows today.

## Formula

```
session_co2_grams = (
    (input_tokens + cache_write_tokens) * input_factor
  + cache_read_tokens * (input_factor * cache_read_factor)
  + output_tokens * output_factor
) / 1_000_000
```

Factors are in gCO2e per million tokens. `cache_write_tokens` (`cache_creation_input_tokens`) are a full prefill, so they count at the input factor. `cache_read_tokens` count at a reduced `cache_read_factor` (default 0.08) of the input factor (see Cache read energy below).

## Infrastructure parameters

| Parameter      | Value            | Description                                                                   |
| -------------- | ---------------- | ----------------------------------------------------------------------------- |
| PUE            | 1.14             | AWS datacenter power usage effectiveness                                      |
| CIF            | 0.287 kgCO2e/kWh | AWS region grid CIF, location-based (Jegham et al.); US average is ~380 g/kWh |
| WUE (on-site)  | 0.18 L/kWh       | Water for datacenter cooling (not used in CO2 calc)                           |
| WUE (off-site) | 5.11 L/kWh       | Water for electricity generation (not used in CO2 calc)                       |

## Per-model factors (gCO2e per million tokens)

| Model family | Input | Output | Source                         |
| ------------ | ----- | ------ | ------------------------------ |
| Fable        | 156   | 3304   | Extrapolated (2x Opus)         |
| Opus         | 78    | 1652   | Extrapolated (2x Sonnet)       |
| Sonnet       | 39    | 826    | 3-point fit (Jegham et al. v6) |
| Haiku        | 20    | 413    | Extrapolated (0.5x Sonnet)     |

## Why input and output factors differ

Output tokens are far more energy-intensive per token than input tokens. During prefill (input processing), the model processes all input tokens in parallel in one batched forward pass. During decoding (output generation), each token requires its own sequential forward pass through the model. This autoregressive step dominates energy consumption.

The exact ratio is not assumed, it is recovered from the three measured Sonnet points (see Deriving the Sonnet input/output factors above): the fit yields a marginal output:input ratio of ~21:1 (826 vs 39 gCO2e/Mtok). A large input (long context) adds little energy relative to the same number of generated tokens, which a flat low ratio would miss.

## Why Fable, Opus and Haiku are extrapolated

The Jegham paper measured Sonnet-class models directly. The other families are estimated by scaling:

- Opus = 2x Sonnet. The current EcoLogits parameter assumptions for Opus 4.5+ (670B vs Sonnet 4.x 440B, active ~133B vs ~88B) and the Anthropic list-price ratio ($5/$25 vs $3/$15) both imply roughly 1.7-2x, not the 3x used in earlier releases. Honest band: 2x-5x Sonnet (Opus is unmeasured; EcoLogits' absolute Opus number is unstable across model generations).
- Haiku = 0.5x Sonnet (smaller model, lighter compute). Wide band: Jegham's measured 3.5 Haiku reads higher than Sonnet (a serving/latency artifact), while EcoLogits' modern dense Haiku reads far lower; 0.5x is a physically-plausible middle.
- Fable = 2x Opus (no published measurement for Fable 5 / Mythos 5; the list-price ratio, $10/$50 vs $5/$25, is used as a compute proxy)

These are order-of-magnitude estimates. Actual values depend on Anthropic's specific hardware configuration and batching strategies, which are not publicly available. Only Sonnet is measured; the others carry the uncertainty bands noted above.

## Excluded models (non-Anthropic)

Claude Code can be pointed at non-Anthropic models (e.g. local models behind `ANTHROPIC_BASE_URL`). Their impact profile is not an AWS datacenter's, so neither the emission factors nor the API pricing apply. Sessions whose dominant model string does not contain `claude` (including the `<synthetic>` marker) are stored with their raw token counts but `cost_usd = 0`, `co2_grams = 0` and `excluded = 1`, and are left out of all report aggregates. Additional models can be excluded by name via the `exclude_models` patterns in `data/factors.json`. Because raw tokens are preserved, excluded sessions can be re-priced later by `recompute.sh` if factors for local models are ever added.

## Token counting and deduplication

Token counts come from parsing the JSONL transcripts (`message.usage`). Assistant messages are deduplicated by `(message.id, requestId)`, keeping the last occurrence, before summing. This matters because resumed and compacted sessions replay earlier messages within the same file, and streaming writes the same message multiple times with a growing `output_tokens`. Without dedup the raw line sum over-counts by roughly 3x (on observed data, 55% of assistant lines are replays). This matches the deduplication ccusage performs.

## Surviving the 30-day transcript purge

Claude Code purges JSONL transcripts after about 30 days, so the SQLite DB is the only durable record. Two design choices follow:

1. **Capture before purge.** The `Stop` hook (`persist-session.sh`) writes each session to the DB when it ends, while the JSONL still exists. A throttled `SessionStart` hook (`safety-rescan.sh`) re-runs `backfill.sh` once a day in the background to catch any session the `Stop` hook missed (crash, kill, hook disabled), as long as its transcript is still within the 30-day window. The only unavoidable gaps are history older than the install date and downtime longer than 30 days.

2. **Store raw tokens, derive on demand.** Each row stores the raw token breakdown: `input_tokens` (regular input + cache write), `cache_creation_tokens` (cache write), `cache_read_tokens`, and `output_tokens`. Cost and CO2 are pure functions of these counts plus `data/factors.json` and `data/prices.json`, so they can be regenerated at any time with `recompute.sh` without re-reading the (purged) JSONL. When a CO2 factor is revised, run `recompute.sh` (CO2-only by default); when a price changes, run `recompute.sh --with-cost` (cost re-pricing collapses mixed-model rows to the dominant model, ~6% high on subagent sessions, so it is opt-in). Rows are tagged `methodology_version`; only version >= 2 carries the full raw-token breakdown, so older rows captured before this change are left untouched as legacy.

`recompute.sh` recomputes a mixed-model session (subagents on a different model) at the row's dominant model, a small approximation; the original insert is model-accurate per subagent.

## Cache read energy

A `cache_read` token is a previously-processed context token whose key/value tensors are reused, so its prefill compute is skipped. It is not free in energy: during decode, every generated token re-reads the entire KV cache from HBM, including the cached tokens (GreenCache, SIGMETRICS: "caching does not reduce computation in the decode phase"). So the energy of a cached token is the decode-phase KV-read residual that survives caching.

No study directly measures the cache_read-to-input energy ratio. The default `cache_read_factor` of **0.08** (defensible range 0.05-0.15, hard bound 0-0.20) is an engineering estimate derived from adjacent measurements: prefill is ≤ 3.4% of total inference energy for generation workloads (Solovyeva & Castor), a larger KV cache amplifies per-token decode energy by 1.3-51.8%, and per-token energy rises ~3x from 2K to 10K context (TokenPowerBench, H100). The factor is workload-dependent and grows with context length; a flat constant understates very long reused prefixes.

This factor is **not** Anthropic's 0.1x cache_read billing ratio. That is a price, not an energy measurement (OpenAI prices the same mechanism at 0.5x). Setting `cache_read_factor` to 0 is a defensible lower bound but treats a reused 100K-token system prompt as carbon-free, which understates a real memory-bandwidth cost.

Sources: GreenCache (arXiv:2505.23970), TokenPowerBench (arXiv:2512.03024), Solovyeva & Castor (arXiv:2602.05712), From Prompts to Power (arXiv:2511.05597).

## Cost estimate

The `cost_usd` column is the theoretical API list value of the usage (what it would cost on pay-as-you-go), not the subscription price actually paid. It uses current Anthropic list pricing per million tokens (reconfirmed 2026-06-22): Opus 4.6+ at $5 input / $25 output (not the retired $15/$75 of Opus 4.0/4.1), Sonnet at $3/$15, Haiku at $1/$5, Fable 5 at $10/$50. Cache write is billed at 1.25x input (the 5-minute tier, Claude Code's default; the 1-hour tier is 2x) and cache read at 0.1x input. On deduplicated data this reconciles to within a few percent of ccusage.

For EUR, `data/prices.json` carries `eur_per_usd` (ECB euro reference rate, 0.8729 as of 2026-06-22); convert `cost_usd` at display time rather than storing EUR amounts, so a single dated rate stays the only source of truth and historical rows never need re-conversion. The recent USD/EUR range is tight (~±1%), so a monthly refresh keeps EUR accurate well within the CO2/cost uncertainty.

## Limitations

- Order of magnitude only. Do not use these numbers for regulatory reporting or lifecycle assessments.
- Inference only. Training costs, hardware manufacturing, and cooling water are not included.
- Cache read energy is a derived estimate, not a measurement (see Cache read energy below). Cache reads are 90%+ of tokens in Claude Code, so the chosen factor (default 0.08) is the single biggest lever on the headline number.
- Status line is approximate. Claude Code does not expose `cache_read_input_tokens` separately in the statusline hook JSON, and parsing JSONL incrementally at each turn would be too slow. The live display uses `context_window.total_input_tokens` (current context size, includes cache reads, no subagents). This is not used in reports.
- Grid-average, not real-time. The CIF is the static AWS region grid intensity (location-based, 0.287); the US national average is higher (~380 g/kWh). Actual emissions depend on Anthropic's datacenter location, energy mix, and time of day.
- Single-fleet assumption. Since 2026 Anthropic serves Claude from a mixed fleet: AWS (Trainium and GPUs, the infrastructure Jegham measured), Google Cloud TPUs (1+ GW coming online during 2026), and, per SpaceX's May 2026 S-1 filing, the leased ~300 MW Colossus 1 site in Memphis, largely powered by gas turbines (~350-450 gCO2e/kWh vs the 287 used here). A single CIF and a single per-model energy cannot capture per-request routing across hardware and grids. The weighted effect of Memphis alone is roughly +5-10% on the CIF, within this tool's order-of-magnitude uncertainty; the TPU share pulls the other way. Watch item: revisit the CIF if the fleet mix shifts further toward gas-powered capacity.

## Equivalences used in reports

| Activity              | Emission factor | Source                                |
| --------------------- | --------------- | ------------------------------------- |
| Car                   | 120 gCO2e/km    | ADEME 2024 (thermal vehicle, average) |
| Google search         | 0.2 gCO2e       | Google Environmental Report 2023      |
| Email with attachment | 19 gCO2e        | ADEME 2024                            |
| TGV                   | 2.4 gCO2e/km    | SNCF 2023 Environmental Report        |
