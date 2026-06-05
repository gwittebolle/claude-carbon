# Methodology

## Overview

Emissions are estimated from token counts using per-token factors derived from peer-reviewed research. The approach is intentionally simple: one number per model family per token direction. No real-time data, no per-request tracing.

## Source

Jegham et al. (2025), "Measuring the Carbon Footprint of AI Inference"
[arxiv.org/abs/2505.09598](https://arxiv.org/abs/2505.09598)

The paper measures inference energy consumption on AWS infrastructure for a range of models, then converts to CO2e using grid-average carbon intensity.

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

| Parameter | Value            | Description                                      |
| --------- | ---------------- | ------------------------------------------------ |
| PUE       | 1.14             | AWS datacenter power usage effectiveness         |
| CIF       | 0.287 kgCO2e/kWh | Carbon intensity factor (US grid average)        |
| WUE       | 0.18 L/kWh       | Water usage effectiveness (not used in CO2 calc) |

## Per-model factors (gCO2e per million tokens)

| Model family | Input | Output | Source                     |
| ------------ | ----- | ------ | -------------------------- |
| Opus         | 500   | 3000   | Extrapolated (3x Sonnet)   |
| Sonnet       | 190   | 1140   | Measured (Jegham et al.)   |
| Haiku        | 95    | 570    | Extrapolated (0.5x Sonnet) |

## Why input and output factors differ

Output tokens are ~6x more expensive than input tokens in terms of compute. During prefill (input processing), the model processes all input tokens in parallel. During decoding (output generation), each token requires a full forward pass through the model sequentially. This autoregressive step dominates energy consumption.

## Why Opus and Haiku are extrapolated

The Jegham paper measured Sonnet-class models directly. Opus and Haiku factors are estimated by scaling:

- Opus = 3x Sonnet (larger model, roughly proportional parameter count)
- Haiku = 0.5x Sonnet (smaller model, lighter compute)

These are order-of-magnitude estimates. Actual values depend on Anthropic's specific hardware configuration and batching strategies, which are not publicly available.

## Token counting and deduplication

Token counts come from parsing the JSONL transcripts (`message.usage`). Assistant messages are deduplicated by `(message.id, requestId)`, keeping the last occurrence, before summing. This matters because resumed and compacted sessions replay earlier messages within the same file, and streaming writes the same message multiple times with a growing `output_tokens`. Without dedup the raw line sum over-counts by roughly 3x (on observed data, 55% of assistant lines are replays). This matches the deduplication ccusage performs.

## Surviving the 30-day transcript purge

Claude Code purges JSONL transcripts after about 30 days, so the SQLite DB is the only durable record. Two design choices follow:

1. **Capture before purge.** The `Stop` hook (`persist-session.sh`) writes each session to the DB when it ends, while the JSONL still exists. A throttled `SessionStart` hook (`safety-rescan.sh`) re-runs `backfill.sh` once a day in the background to catch any session the `Stop` hook missed (crash, kill, hook disabled), as long as its transcript is still within the 30-day window. The only unavoidable gaps are history older than the install date and downtime longer than 30 days.

2. **Store raw tokens, derive on demand.** Each row stores the raw token breakdown: `input_tokens` (regular input + cache write), `cache_creation_tokens` (cache write), `cache_read_tokens`, and `output_tokens`. Cost and CO2 are pure functions of these counts plus `data/factors.json` and `data/prices.json`, so they can be regenerated at any time with `recompute.sh` without re-reading the (purged) JSONL. When Anthropic changes a price, or a factor is revised, edit the config and run `recompute.sh`. Rows are tagged `methodology_version`; only version >= 2 carries the full raw-token breakdown, so older rows captured before this change are left untouched as legacy.

`recompute.sh` recomputes a mixed-model session (subagents on a different model) at the row's dominant model, a small approximation; the original insert is model-accurate per subagent.

## Cache read energy

A `cache_read` token is a previously-processed context token whose key/value tensors are reused, so its prefill compute is skipped. It is not free in energy: during decode, every generated token re-reads the entire KV cache from HBM, including the cached tokens (GreenCache, SIGMETRICS: "caching does not reduce computation in the decode phase"). So the energy of a cached token is the decode-phase KV-read residual that survives caching.

No study directly measures the cache_read-to-input energy ratio. The default `cache_read_factor` of **0.08** (defensible range 0.05-0.15, hard bound 0-0.20) is an engineering estimate derived from adjacent measurements: prefill is ≤ 3.4% of total inference energy for generation workloads (Solovyeva & Castor), a larger KV cache amplifies per-token decode energy by 1.3-51.8%, and per-token energy rises ~3x from 2K to 10K context (TokenPowerBench, H100). The factor is workload-dependent and grows with context length; a flat constant understates very long reused prefixes.

This factor is **not** Anthropic's 0.1x cache_read billing ratio. That is a price, not an energy measurement (OpenAI prices the same mechanism at 0.5x). Setting `cache_read_factor` to 0 is a defensible lower bound but treats a reused 100K-token system prompt as carbon-free, which understates a real memory-bandwidth cost.

Sources: GreenCache (arXiv:2505.23970), TokenPowerBench (arXiv:2512.03024), Solovyeva & Castor (arXiv:2602.05712), From Prompts to Power (arXiv:2511.05597).

## Cost estimate

The `cost_usd` column is the theoretical API list value of the usage (what it would cost on pay-as-you-go), not the subscription price actually paid. It uses current Anthropic list pricing per million tokens: Opus 4.6+ at $5 input / $25 output (not the retired $15/$75 of Opus 4.0/4.1), Sonnet at $3/$15, Haiku at $1/$5. Cache write is billed at 1.25x input and cache read at 0.1x input. On deduplicated data this reconciles to within a few percent of ccusage.

## Limitations

- Order of magnitude only. Do not use these numbers for regulatory reporting or lifecycle assessments.
- Inference only. Training costs, hardware manufacturing, and cooling water are not included.
- Cache read energy is a derived estimate, not a measurement (see Cache read energy below). Cache reads are 90%+ of tokens in Claude Code, so the chosen factor (default 0.08) is the single biggest lever on the headline number.
- Status line is approximate. Claude Code does not expose `cache_read_input_tokens` separately in the statusline hook JSON, and parsing JSONL incrementally at each turn would be too slow. The live display uses `context_window.total_input_tokens` (current context size, includes cache reads, no subagents). This is not used in reports.
- Grid-average, not real-time. The CIF is a static US grid average. Actual emissions depend on Anthropic's datacenter location, energy mix, and time of day.
- No multi-region awareness. AWS runs inference in multiple regions with different grid intensities.

## Equivalences used in reports

| Activity              | Emission factor | Source                                |
| --------------------- | --------------- | ------------------------------------- |
| Car                   | 120 gCO2e/km    | ADEME 2024 (thermal vehicle, average) |
| Google search         | 0.2 gCO2e       | Google Environmental Report 2023      |
| Email with attachment | 19 gCO2e        | ADEME 2024                            |
| TGV                   | 2.4 gCO2e/km    | SNCF 2023 Environmental Report        |
