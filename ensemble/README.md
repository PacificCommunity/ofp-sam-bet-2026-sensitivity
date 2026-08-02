# BET 2026 joint ensemble design

This directory defines 100 reproducible joint model draws from the frozen
Diagnostic model. These are structural ensemble draws, not optimizer jitters.
Every model retains the same Diagnostic inputs and deterministic seed-23
initialization path except for the five sampled settings below.

| Setting | Distribution in the 100-model design |
|---|---|
| Steepness | `0.2 + 0.8 × Beta(17.541500, 3.403575)`, represented by 100 stratified quantiles; mean 0.87 and SD 0.063 |
| Tag mixing period | 0.05, 0.10, 0.15, **0.20**, 0.25, 0.30 and 0.35 with counts 6, 12, 19, **26**, 19, 12 and 6 |
| Tag reporting | MFCL tag flag column 2 is 0 (inclusion) for 50 models and 1 (exclusion) for 50 models |
| Natural mortality | quarterly M at age 40 follows a truncated lognormal distribution on 0.050–0.165, with mode 0.0702 and median 0.078136 |
| Effort creep | the five official FRQ scenarios are equally weighted, with exactly 20 models per scenario |

The steepness prior follows the 2024 South Pacific albacore assessment. Its
censored beta prior was specified on 0.2–1.0 with mean 0.87 and SD 0.063.

The M distribution synthesises three assessment-relevant sources on the
quarterly scale. The 2026 tag analysis gives mean M at age 40 of 0.0624 with a
90% interval of 0.0500–0.0745; the 2023 assessment used 0.078; and the
Hamel–Cope longevity prior for a 15-year maximum age has median 0.090 and
log-scale SD 0.31. The mode is set to 0.0702, the midpoint of the tag estimate
and the previous assessment. The median is 0.078136, which is both the current
Diagnostic value and approximately the mean of the three central estimates.
The truncation limits 0.050 and 0.165 retain the stated evidence range.

A truncated lognormal calibrated to those bounds, mode and median has log-scale
SD 0.2876, close to the Hamel–Cope value of 0.31. This retains a standard,
positive and right-skewed natural-mortality prior without treating the tag
estimate or the previous assessment as exact point masses. MFCL uses four
recruitment periods per year, so these are quarterly values. The model input is
the natural logarithm of the draw in Lorenzen `age_pars(5,1)`; no factor of four
is applied.

Effort creep is sampled directly from the five files in the official BET/YFT
FRQ-build repository:

| Primary | Secondary | Models |
|---:|---:|---:|
| 0.5% | 0.25% | 20 |
| 1.0% | 0.50% | 20 |
| 1.5% | 0.75% | 20 |
| 2.0% | 1.00% | 20 |
| 2.5% | 1.25% | 20 |

The discrete margins are exact. Continuous variables use deterministic
quantiles rather than unrestricted random draws. Independent permutations are
searched with design seed `20260802`, and the lowest-association design among
20,000 candidates is retained. This preserves each marginal distribution while
reducing accidental association among the five settings.

Recreate all files with:

```sh
Rscript scripts/create-ensemble-design.R
```

`model-draws.csv` is the machine-readable source of truth.
`distribution-parameters.csv` records the exact prior parameters. Summary
tables, the rank-correlation audit and `distributions.png` are generated
alongside them.

## Sources

- [2024 South Pacific albacore stock assessment](https://meetings.wcpfc.int/system/files/2024-08/SC20-SA-WP-02%20Sth_Pacific_albacore_assessment2024_rev3.pdf)
- [2026 WCPO bigeye tag-based natural-mortality analysis](https://meetings.wcpfc.int/meetings/sc22?order=changed&sort=asc), WCPFC-SC22-2026-SA-IP14
- [Hamel and Cope (2022), Development and considerations for application of a longevity-based prior for the natural mortality rate](https://repository.library.noaa.gov/view/noaa/68311)
- [BET/YFT effort-creep FRQ files](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-frq-build/tree/main/BET), source commit `26a4d6e3b41066c6d3b32dd4a38d381f616a0cff`
