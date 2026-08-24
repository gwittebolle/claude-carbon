# Methodology

## Overview

Emissions are estimated from token counts using per-token factors derived from published academic research. The approach is intentionally simple: one number per model family per token direction. No real-time data, no per-request tracing.

## Source

Jegham et al. (2025), "How Hungry is AI? Benchmarking the Energy, Water, and Carbon Footprint of LLM Inference" (v6, arXiv preprint, not peer-reviewed)
[arxiv.org/abs/2505.09598](https://arxiv.org/abs/2505.09598)

The paper estimates inference energy for a range of models from public API performance data (time to first token, tokens per second) via Monte Carlo simulation over inferred hardware configurations, then converts to CO2e using grid-average carbon intensity. It does not measure hardware power draw: its per-query energies are model outputs resting on assumed GPU nodes and fixed utilization rates, not telemetry. For Claude 3.7 Sonnet it reports three per-query energies (Table 4, PUE included): **0.950 Wh** (100 input / 300 output), **2.989 Wh** (1k / 1k) and **5.671 Wh** (10k input / 1.5k output).

### Deriving the Sonnet input/output factors

The three estimated points are fit with an ordinary least-squares regression through the origin in (energy per input token, energy per output token), matching the per-token model below (no per-query constant). That gives ~1.35e-4 Wh per input token and ~2.88e-3 Wh per output token. At CIF 0.287 gCO2e/Wh (= 0.287 kgCO2e/kWh) that is **~39 gCO2e/Mtok input** and **~826 gCO2e/Mtok output**, a marginal ratio of ~21:1. The fit matches the two high-token configurations (1k/1k, 10k/1.5k) to within 1%, the regime real Claude Code sessions live in.

These are the best available public data to date and will keep being refined as estimates improve. Earlier releases used 190/1140, calibrated against an earlier revision of the same preprint; the move to v6's three per-query energies refines that.

### Cross-validation against EcoLogits

[EcoLogits](https://ecologits.ai) (GenAI Impact / Data For Good) estimates inference impact by an independent route: model parameter counts plus a full lifecycle model, rather than API-derived energy estimates. Its estimate for Claude 3.7 Sonnet brackets **~565-1385 gCO2e/Mtok output** (parameter range, USA grid, full lifecycle), with a usage-only central value near ~630. The Jegham-derived **826** sits inside that band. That is a useful consistency check rather than strong corroboration: the EcoLogits band spans a factor of ~2.5 (almost any plausible value lands inside it), and its parameter counts for closed models are educated guesses. Note one structural difference: EcoLogits charges zero energy to input tokens, whereas Jegham's estimates show a small but real input cost (the 10k-input query consumes more), which this tool keeps via the input factor.

### A third independent estimate (Couch, 2026)

[Simon Couch's January 2026 analysis of AI coding agents](https://simonpcouch.com/blog/2026-01-20-cc-impact/) derives Claude per-token energy by yet another route: Epoch AI's GPT-4o per-query estimate scaled by Anthropic's API price ratios. His self-described pessimistic figures are ~390 Wh/Mtok input and ~1,950 Wh/Mtok output. The Jegham-derived Sonnet factors used here are equivalent to ~136 Wh/Mtok input and ~2,880 Wh/Mtok output. Three routes (API-based energy estimation, parameter-count lifecycle modeling, price-ratio scaling) landing within ~1.5x of each other on output tokens is encouraging, with caveats. Couch's figures are anchored on Opus-class pricing while the comparison here is against Sonnet factors. The routes share assumptions: price-ratio scaling is the same proxy this tool uses for Opus and Fable, and Epoch AI's anchor is itself a parameter-count model, so the three are not fully independent. And the agreement does not extend to input tokens, where the routes span 0 (EcoLogits) to ~390 Wh/Mtok (Couch).

## Formula

```
session_co2_grams = (
    (input_tokens + cache_write_tokens) * input_factor
  + cache_read_tokens * (input_factor * cache_read_factor)
  + output_tokens * output_factor
) / 1_000_000
```

Factors are in gCO2e per million tokens. `cache_write_tokens` (`cache_creation_input_tokens`) are a full prefill, so they count at the input factor. `cache_read_tokens` count at a reduced `cache_read_factor` (default 0.08) of the input factor (see Cache read energy below).

The cache-write TTL tier does not appear in this formula. Writing a 5-minute entry and writing a 1-hour entry run the same prefill; what differs is how long the entry is retained, which is storage rather than compute. The tier changes the price only (see Cost estimate below).

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

Output tokens are far more energy-intensive per token than input tokens, but not because they need more math: FLOPs per token are similar in prefill and decode (~2x parameters either way for a dense model). The difference is hardware utilization. Prefill processes the whole prompt in parallel and saturates compute; each decode step re-reads the model weights and the KV cache to produce a single token, so decoding is memory-bandwidth-bound and burns far more energy per token. The exact multiple depends on batch size and serving stack.

The ratio used here is not assumed, it is recovered from the three Jegham Sonnet points (see Deriving the Sonnet input/output factors above): the fit yields a marginal output:input ratio of ~21:1 (826 vs 39 gCO2e/Mtok). Three points and two coefficients leave one degree of freedom, so 21:1 is a point estimate without error bars: the direction is robust, the exact multiple is not. A large input (long context) adds little energy relative to the same number of generated tokens, which a flat low ratio would miss.

## Why Fable, Opus and Haiku are extrapolated

The Jegham paper covers Sonnet-class models directly. The other families are estimated by scaling:

- Opus = 2x Sonnet. The current EcoLogits parameter assumptions for Opus 4.5+ (670B vs Sonnet 4.x 440B, active ~133B vs ~88B) and the Anthropic list-price ratio ($5/$25 vs $3/$15) both imply roughly 1.7-2x, not the 3x used in earlier releases. Honest band: 2x-5x Sonnet (Opus is unmeasured; EcoLogits' absolute Opus number is unstable across model generations).
- Haiku = 0.5x Sonnet (smaller model, lighter compute). Wide band: Jegham's 3.5 Haiku estimate reads higher than Sonnet (a serving/latency artifact), while EcoLogits' modern dense Haiku reads far lower; 0.5x is a physically-plausible middle. Taken at face value instead, the Haiku estimate would put Haiku ≈ Sonnet and erase most of the gain from routing tasks to smaller models; the artifact reading is better supported, but the unfavorable reading exists and this is the widest band in the tool.
- Fable = 2x Opus (no published measurement for Fable 5 / Mythos 5; the list-price ratio, $10/$50 vs $5/$25, is used as a compute proxy)

These are order-of-magnitude estimates. Actual values depend on Anthropic's specific hardware configuration and batching strategies, which are not publicly available. Only Sonnet is covered by the Jegham estimates; the others carry the uncertainty bands noted above.

## Excluded models (non-Anthropic)

Claude Code can be pointed at non-Anthropic models (e.g. local models behind `ANTHROPIC_BASE_URL`). Their impact profile is not an AWS datacenter's, so neither the emission factors nor the API pricing apply. Sessions whose dominant model string does not contain `claude` (including the `<synthetic>` marker) are stored with their raw token counts but `cost_usd = 0`, `co2_grams = 0` and `excluded = 1`, and are left out of all report aggregates. Additional models can be excluded by name via the `exclude_models` patterns in `data/factors.json`. Because raw tokens are preserved, excluded sessions can be re-priced later by `recompute.sh` if factors for local models are ever added.

## Token counting and deduplication

Token counts come from parsing the JSONL transcripts (`message.usage`). Assistant messages are deduplicated by `(message.id, requestId)`, keeping the last occurrence, before summing. This matters because resumed and compacted sessions replay earlier messages within the same file, and streaming writes the same message multiple times with a growing `output_tokens`. Without dedup the raw line sum over-counts by roughly 3x (on observed data, 55% of assistant lines are replays). This matches the deduplication ccusage performs.

## Surviving the 30-day transcript purge

Claude Code purges JSONL transcripts after about 30 days, so the SQLite DB is the only durable record. Two design choices follow:

1. **Capture before purge.** The `Stop` hook (`persist-session.sh`) writes each session to the DB when it ends, while the JSONL still exists. A throttled `SessionStart` hook (`safety-rescan.sh`) re-runs `backfill.sh` once a day in the background to catch any session the `Stop` hook missed (crash, kill, hook disabled), as long as its transcript is still within the 30-day window. The only unavoidable gaps are history older than the install date and downtime longer than 30 days.

2. **Store raw tokens, derive on demand.** Each row stores the raw token breakdown: `input_tokens` (regular input + cache write), `cache_creation_tokens` (cache write), `cache_creation_1h_tokens` (the subset of that write made at the 1-hour TTL), `cache_read_tokens`, and `output_tokens`. Cost and CO2 are pure functions of these counts plus `data/factors.json` and `data/prices.json`, so they can be regenerated at any time with `recompute.sh` without re-reading the (purged) JSONL. When a CO2 factor is revised, run `recompute.sh` (CO2-only by default); when a price changes, run `recompute.sh --with-cost` (cost re-pricing collapses mixed-model rows to the dominant model, ~6% high on subagent sessions, so it is opt-in). Rows are tagged `methodology_version`; only version >= 2 carries the full raw-token breakdown, so older rows captured before this change are left untouched as legacy.

`recompute.sh` recomputes a mixed-model session (subagents on a different model) at the row's dominant model, a small approximation; the original insert is model-accurate per subagent.

## Cache read energy

A `cache_read` token is a previously-processed context token whose key/value tensors are reused, so its prefill compute is skipped. It is not free in energy.

### What this term is, and what it is not

The formula applies `cache_read_tokens * input_factor * cache_read_factor`, i.e. a fraction of the energy of an uncached input token. So it is a **prefill residual**: what is still paid at prefill when the prefix is already cached.

Earlier versions of this document justified the same term as the decode-phase KV re-read residual: during decode, every generated token re-reads the entire KV cache from HBM, including the cached tokens (GreenCache, SIGMETRICS: "caching does not reduce computation in the decode phase"). That is a different object, and it is **not linear in `cache_read_tokens`** - it scales with the product (context size x generated tokens). Today that cost sits absorbed inside a constant output factor, calibrated at context lengths the source does not publish. Stated plainly: **in long-context agentic use, this model underestimates that term.**

### What is measured

A direct hit/miss measurement has existed since May 2026. Irminsul (arXiv:2605.05696, Table 1) instruments prefill energy per cache event with NVML hardware counters, at 4,096 prefix tokens:

| Attention | Model | Miss | Hit | Hit / miss |
| --- | --- | ---: | ---: | ---: |
| GQA | Qwen3-32B | 262.3 J | 37.5 J | 14% |
| MLA | DeepSeek-V2-Lite | 47.1 J | 17.2 J | 37% |
| MHA | DeepSeek-MoE-16B | 45.2 J | 15.3 J | 34% |
| Hybrid SSM | Mamba2, GDN, KDA | - | - | 0% saving |

Three reservations. The measurement is at **4,096** prefix tokens, while the median Claude Code step carries 126,180 (TraceLab, arXiv:2606.30560v2, Table 8): at that scale the fixed kernel-launch costs that dominate small cells amortise away and the real ratio falls, which the paper acknowledges for its own small cells. The two high rows are 16B models, exactly where those fixed costs weigh most. And Claude's attention architecture is not published, so which row applies is unknown.

### The value

The default `cache_read_factor` stays **0.08**, published range **0.05-0.20** (previously 0.05-0.15). We do not adopt 0.14: applying a 4K-context measurement to usage that runs at 126K would move a Claude Code-heavy total by 25-30% on a basis that cannot be defended. The upper bound does move, because two of the three measured architectures sit above the old ceiling - the stated uncertainty was understating the upside.

The bracketing measurements still hold: prefill is ≤ 3.4% of total inference energy for generation workloads and a larger KV cache amplifies per-token decode energy by 1.3-51.8% (both Solovyeva & Castor, measured on 3B-7B models with short prompts), and per-token energy rises ~3x from 2K to 10K context (TokenPowerBench, H100, Llama3 70B).

The real fix is a different equation shape, with a residual prefill term and a decode term that depends on context length, not a different constant.

This factor is **not** Anthropic's 0.1x cache_read billing ratio. That is a price, not an energy measurement (OpenAI prices the same mechanism at 0.5x). Setting `cache_read_factor` to 0 is a defensible lower bound but treats a reused 100K-token system prompt as carbon-free, which understates a real memory-bandwidth cost.

Sources: Irminsul (arXiv:2605.05696), GreenCache (arXiv:2505.23970, SIGMETRICS 2026), TokenPowerBench (arXiv:2512.03024), Solovyeva & Castor (arXiv:2602.05712), TraceLab (arXiv:2606.30560v2).

## Cost estimate

The `cost_usd` column is the theoretical API list value of the usage (what it would cost on pay-as-you-go), not the subscription price actually paid. It uses current Anthropic list pricing per million tokens (reconfirmed 2026-06-22): Opus 4.6+ at $5 input / $25 output (not the retired $15/$75 of Opus 4.0/4.1), Sonnet at $3/$15, Haiku at $1/$5, Fable 5 at $10/$50. Cache read is billed at 0.1x input. Cache writes are billed per TTL tier, 1.25x input for the 5-minute tier and 2x for the 1-hour tier, and the tier is not assumed: each session's split is read from `usage.cache_creation.ephemeral_1h_input_tokens` and stored alongside the total, so a session mixing both tiers is priced correctly.

Claude Code writes at the 1-hour tier. Measured on 2026-08-24 over 24,978 assistant requests of local transcripts: 174,465,500 tokens in `ephemeral_1h`, 0 in `ephemeral_5m`. Before this correction the tool applied the 5-minute multiplier to every cache write, understating that line item by a factor 1.6, which on the same sample is +12.5% on total cost ($5,216 -> $5,870 at Opus list price). Rows captured before the split existed carry `cache_creation_1h_tokens = 0` and stay priced at the 5-minute tier; `backfill.sh` repairs the column from any transcript still inside the 30-day window, and `recompute.sh --with-cost` then re-derives their cost. On deduplicated data this reconciles to within a few percent of ccusage.

For EUR, `data/prices.json` carries `eur_per_usd` (ECB euro reference rate, 0.8729 as of 2026-06-22); convert `cost_usd` at display time rather than storing EUR amounts, so a single dated rate stays the only source of truth and historical rows never need re-conversion. The recent USD/EUR range is tight (~±1%), so a monthly refresh keeps EUR accurate well within the CO2/cost uncertainty.

## Limitations

- Order of magnitude only. Do not use these numbers for regulatory reporting or lifecycle assessments. Reports show a single point estimate by design; combining the documented bands (Opus 2x-5x, cache read 0-0.20, the low-end CIF, usage-only scope), the plausible range around any displayed total is roughly 0.7x to 3x, and the excluded items (embodied hardware, amortized training) make the true location-based value more likely above the displayed figure than below it.
- The primary source is an arXiv preprint, and its method has been publicly criticized: a [November 2025 analysis](https://mementohumani.com/an-analysis-of-how-hungry-is-ai-benchmarking-energy-water-and-carbon-footprint-of-llm-inference/) argues the paper conflates API speed with hardware efficiency, ignores queueing, and that its absolute values are best used as a relative benchmark between models. The cross-checks above (EcoLogits, Couch) mitigate this but do not remove it.
- Inference only. Training costs, hardware manufacturing, and cooling water are not included.
- Cache read energy is a derived estimate, not a measurement (see Cache read energy below). Cache reads are 90%+ of tokens in Claude Code, and across its hard bound (0-0.20) the chosen factor (default 0.08) swings the headline number from ~0.65x to ~1.5x, the widest single-parameter lever in the tool. At the default, output tokens still dominate the CO2 total.
- Status line lags by one turn. It reads the session's own row from `carbon.db`, written by the `Stop` hook at the end of every turn, so it shows the same cumulative figure as the reports rather than an independent estimate. Until that row exists (first turn of a session, or no DB) it falls back to a `context_window.total_input_tokens` estimate, which is a snapshot of the current context: no subagents, and it drops back after every compaction. On a long agentic session that fallback understates the total by orders of magnitude, which is why it is only a fallback. Neither value is used in reports.
- Grid-average, not real-time. The CIF is the static AWS region grid intensity (location-based, 0.287); the US national average is higher (~380 g/kWh). Actual emissions depend on Anthropic's datacenter location, energy mix, and time of day.
- Single-fleet assumption. Since 2026 Anthropic serves Claude from a mixed fleet: AWS (Trainium and GPUs, the infrastructure Jegham measured), Google Cloud TPUs (1+ GW coming online during 2026), and, per SpaceX's May 2026 S-1 filing, the leased ~300 MW Colossus 1 site in Memphis, largely powered by gas turbines (~350-450 gCO2e/kWh vs the 287 used here). A single CIF and a single per-model energy cannot capture per-request routing across hardware and grids. The weighted effect of Memphis alone is roughly +5-10% on the CIF, within this tool's order-of-magnitude uncertainty; the TPU share pulls the other way. Watch item: revisit the CIF if the fleet mix shifts further toward gas-powered capacity.

## Equivalences used in reports

Equivalences are locale-dependent. A car, a kWh and a kilo of beef each differ by a factor of 2 or more between countries, so a single set is wrong for most readers: ADEME and SNCF factors describe a French fleet and a nuclear-heavy grid (and a TGV means nothing outside France), while EPA factors describe the heaviest car fleet in the OECD. Three sets ship.

### Default (world average)

| Activity                        | Emission factor   | Source                              |
| ------------------------------- | ----------------- | ----------------------------------- |
| Car (world average, real-world) | 200 gCO2/km       | Derived, see below                  |
| Median Gemini prompt            | 0.03 gCO2e        | Google, Aug 2025 (arXiv:2508.15734) |
| Smartphone charge               | 8.7 gCO2e         | Derived, see below                  |
| Beef steak (150 g)              | 14900 gCO2e/steak | Derived, see below                  |

The car figure is derived because no institution publishes a real-world global fleet average. The only global number is GFEI/IEA's **167 gCO2/km rated** for new light-duty vehicles (2019), a type-approval value, and rated values understate on-road emissions. The gap used here is ~20%, the EU-average gap in the JRC's OBFCM on-board fuel-consumption data for 2021 (~22%) as reported by [ICCT](https://theicct.org/wp-content/uploads/2024/01/ID-76-%E2%80%93-EU-WLTP_final.pdf); note that the same paper's own spritmonitor-based estimate is lower (14% for 2022 Germany) while the US gap is larger, so ~20% is a middle, not a measurement. 167 x 1.2 = 200, which lands between the two published real-world anchors, EU ~171-180 and US ~215-244, the expected place for a world average. The gap is EU-measured but applied to a global rated figure: one more reason not to read the third digit as meaningful.

The smartphone charge is EPA's published per-charge energy (0.019 kWh) at the world grid intensity: 0.019 kWh x 458 gCO2e/kWh = 8.7 g. The intensity is Ember's [Global Electricity Review 2026](https://ember-energy.org/latest-insights/global-electricity-review-2026/electricity-demand-and-supply-trends/) figure for 2025 (generation-side, so grid transmission losses are not counted). EPA's own 12.4 g US figure runs the unrounded charge energy at 637 g/kWh, which is EPA's national **marginal** (non-baseload) rate for delivered electricity, not the US average delivered intensity (~393 g/kWh on the same EPA page). The US-vs-world gap on this row is therefore mostly marginal-vs-average rate, on top of the grid-mix difference.

The steak is the global mean for beef from dedicated beef herds, [99.48 kgCO2e/kg of product](https://ourworldindata.org/grapher/ghg-per-kg-poore) (Poore & Nemecek, Science 2018, 38,700 farms in 119 countries), times the same 150 g portion the French row uses. It is 3.5x the ADEME figure mainly because the global mean carries land-use change, above all Amazon pasture conversion, which French and US production do not.

### US locale

| Activity                        | Emission factor  | Source                                                     |
| ------------------------------- | ---------------- | ---------------------------------------------------------- |
| Car (US average, tailpipe CO2e) | 393 gCO2e/mile   | EPA GHG Equivalencies (3.93e-4 tCO2e/mile, 2022 fleet)     |
| Median Gemini prompt            | 0.03 gCO2e       | Google, Aug 2025 (arXiv:2508.15734)                        |
| Smartphone charge               | 12.4 gCO2        | EPA GHG Equivalencies (1.24e-5 tCO2/charge, US marginal grid rate, 2022) |
| Beef steak (150 g)              | 6400 gCO2e/steak | Putman et al. 2023, 42.7 kgCO2e/kg x the portion           |

Both EPA factors come from the [Greenhouse Gas Equivalencies Calculator references](https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references). The car row stays in miles, the unit EPA publishes and the unit a US reader measures a drive in; converted it is 244 gCO2e/km. The charge row uses EPA's non-baseload marginal electricity rate (see the world-set note above), the rate EPA itself uses for this equivalency. The steak is [Putman et al. 2023](https://www.sciencedirect.com/science/article/pii/S0959652623009241) (Journal of Cleaner Production), a cradle-to-grave assessment of US beef whose functional unit is consumed boneless beef, so it counts processing, distribution, retail and consumption on top of production.

### French locale

| Activity                 | Emission factor  | Source                                                                   |
| ------------------------ | ---------------- | ------------------------------------------------------------------------ |
| Car (thermal, lifecycle) | 142 gCO2e/km     | ADEME Impact CO2, 2025 car footprint model                               |
| Median Gemini prompt     | 0.03 gCO2e       | Google, Aug 2025 (arXiv:2508.15734)                                      |
| TGV (full scope)         | 3.5 gCO2e/km     | SNCF open data 2024, per passenger-km                                    |
| Beef steak (150 g)       | 4200 gCO2e/steak | [ADEME Impact CO2](https://impactco2.fr/outils/alimentation/boeuf), 2025 |

The steak factor is the Impact CO2 beef average (28.0 kgCO2e/kg, Agribalyse 3.2, page updated 15/01/2025) times a 150 g portion.

### Locale detection

Read in order: `CLAUDE_CARBON_LOCALE`, `LC_ALL`, `LC_MESSAGES`, `LANG`, then macOS `AppleLocale` (hooks and GUI-launched shells often carry no `LANG`). `C` and `POSIX` values are skipped: they are sentinels scripts export to stabilize parsing, not user locales. `fr` and any `fr_FR`/`fr-FR` variant (`fr.UTF-8`, `fr_FR.UTF-8`, ...) select the French set, and so does an undetected locale: the French set is this tool's original default, and a detection failure must reproduce the previous behavior, not silently switch factor sets. Anything containing `_US` or `-US` selects the US set; everything else, including non-France francophone locales (`fr_BE`, `fr_CA`, `fr_CH`), gets the world average. `CLAUDE_CARBON_LOCALE` forces a set (a set name or a locale string). The factors live in `data/factors.json` under `equivalences`; the selection logic is `scripts/equiv-lib.sh`, shared by `/carbon-report` and the card generator.

The PNG cards: the FR card always carries the ADEME factor in km, the EN card follows the detected locale down to the unit (miles on a US locale). The EN card and `/carbon-report` therefore always use the same factor set, but their totals can still differ: `/carbon-report` equivalences run on the all-time total while a card covers its report window. Each card names its car factor under the figure, and the `Totals since` line prints it after the distance: the PNG travels alone, so the same "car equivalent" would otherwise mean three different things depending on the set.

Scope varies across the sets and across rows. The EPA car factor is tailpipe combustion (CO2, CH4, N2O), the world one tailpipe CO2, the ADEME one lifecycle including vehicle manufacture. The three steak factors come from three different LCA traditions and span 4200 to 14900 gCO2e, driven by land-use change and by where the system boundary stops. So the numbers in one row are not comparable across sets, and none is scope-matched against this tool's usage-only compute figure. The equivalences are illustrative.

Refreshed 2026-07-31: earlier releases used 120 g/km (car, close to the EU new-vehicle homologation average, misattributed to ADEME), 0.2 g per Google search (a 2009 blog figure misattributed to the 2023 environmental report), 19 g per email with attachment (ADEME 2011, withdrawn; the current ADEME reference email is ~2.5 g) and 2.4 g/km (TGV, untraceable).
