# Methodology

## Overview

Emissions are estimated from token counts using per-token factors derived from peer-reviewed research. The approach is intentionally simple: one number per model family per token direction. No real-time data, no per-request tracing.

## Source

Jegham et al. (2025), "Measuring the Carbon Footprint of AI Inference"
[arxiv.org/abs/2505.09598](https://arxiv.org/abs/2505.09598)

The paper measures inference energy consumption on AWS infrastructure for a range of models, then converts to CO2e using grid-average carbon intensity.

## Formula

```
session_co2_grams = (input_tokens * input_factor + output_tokens * output_factor) / 1_000_000
```

Factors are in gCO2e per million tokens.

## Infrastructure parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| PUE | 1.14 | AWS datacenter power usage effectiveness |
| CIF | 0.287 kgCO2e/kWh | Carbon intensity factor (US grid average) |
| WUE | 0.18 L/kWh | Water usage effectiveness (not used in CO2 calc) |

## Per-model factors (gCO2e per million tokens)

| Model family | Input | Output | Source |
|-------------|-------|--------|--------|
| Opus | 500 | 3000 | Extrapolated (3x Sonnet) |
| Sonnet | 190 | 1140 | Measured (Jegham et al.) |
| Haiku | 95 | 570 | Extrapolated (0.5x Sonnet) |

## Why input and output factors differ

Output tokens are ~6x more expensive than input tokens in terms of compute. During prefill (input processing), the model processes all input tokens in parallel. During decoding (output generation), each token requires a full forward pass through the model sequentially. This autoregressive step dominates energy consumption.

## Why Opus and Haiku are extrapolated

The Jegham paper measured Sonnet-class models directly. Opus and Haiku factors are estimated by scaling:
- Opus = 3x Sonnet (larger model, roughly proportional parameter count)
- Haiku = 0.5x Sonnet (smaller model, lighter compute)

These are order-of-magnitude estimates. Actual values depend on Anthropic's specific hardware configuration and batching strategies, which are not publicly available.

## Limitations

- Order of magnitude only. Do not use these numbers for regulatory reporting or lifecycle assessments.
- Inference only. Training costs, hardware manufacturing, and cooling water are not included.
- Cache not separated. Prompt cache hits are counted at full input token rate, which overestimates emissions when cache is used heavily.
- Grid-average, not real-time. The CIF is a static US grid average. Actual emissions depend on Anthropic's datacenter location, energy mix, and time of day.
- No multi-region awareness. AWS runs inference in multiple regions with different grid intensities.

## Equivalences used in reports

| Activity | Emission factor | Source |
|----------|----------------|--------|
| Car | 120 gCO2e/km | ADEME 2024 (thermal vehicle, average) |
| Google search | 0.2 gCO2e | Google Environmental Report 2023 |
| Email with attachment | 19 gCO2e | ADEME 2024 |
| TGV | 2.4 gCO2e/km | SNCF 2023 Environmental Report |
