# Provenance

## Diagnostic reference

The frozen inputs and executable come from
[`ofp-sam-bet-2026-diagnostic`](https://github.com/PacificCommunity/ofp-sam-bet-2026-diagnostic)
main at commit `e93b9bc6284b17cc5ab2af4ccabb1cfe776e76a5`. They reproduce Kflow Job
21641: fixed `h=0.90`, Diagnostic F10/F33 weak non-decreasing selectivity,
direct negative-binomial `tau=2` fixed, and ordinary makepar initialization.

The MFCL executable SHA-256 is
`8995f72019869863c1d1c0b4f44fc6a6268d1f79031f5bc79dc354ee10f0a63e`.
The model manifest is verified before every sensitivity is prepared.

## Tau definition

MFCL source commit `b3984d5e40096eecfa506a3d768f76ef59a32688` defines the direct
negative-binomial parameter as:

```text
tau = 1 + exp(fish_pars(4))
```

With `parest 305=1` and `parest 306=0`, the source uses default
`fish_pars(4)` bounds of -5 to 5. Therefore the lowest sensitivity is
`1 + exp(-5) = 1.006737947`, not exactly 1. Each tau run retains `parest
111/305/306 = 4/1/0`, fish flags 43/44 fixed at zero, and changes only all 33
copies of the fixed row-4 value created before Phase 1.

The previous Diagnostic used the legacy `parest 305=0` branch. Its fixed
`fish_pars(4)=0` corresponds to an effective direct tau of approximately 1.02,
but that legacy parameterization is not mixed into this sensitivity grid.

## External input sources

- Tag mixing periods:
  [`ofp-sam-2026-BET-YFT-build-ini`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-build-ini/tree/SC22-IP10-regionMean/BET/ini.mix-period),
  branch `SC22-IP10-regionMean`, commit
  `efe3107c72774ee73b5e6dc45e44cf51f0fc20e8`.
- CAAL:
  [`ofp-sam-2026-BET-YFT-age-length-build`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-age-length-build/blob/96a06d21ef3c666f39ce456d3a6818b6c17324c4/BET/bet.2026.sub.basin.1.age_length),
  commit `96a06d21ef3c666f39ce456d3a6818b6c17324c4`.
- High effort creep:
  [`ofp-sam-2026-BET-YFT-frq-build`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-frq-build/blob/504bfd2e0f100b76962d98762b68885fbddbe7dc/BET/bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq),
  commit `504bfd2e0f100b76962d98762b68885fbddbe7dc`.
- Whole-period regional scaling: frozen source matrix SHA-256
  `dea4c281f7dc46a7412b7ad2e78906ee57b51b62cf1a18c4609381132bf752ed`.

Preparation verifies fixed SHA-256 hashes for every copied source file.

## Scientific design

This is a one-at-a-time design. No alternative combines two sensitivity axes.
All effective input folders are materialized and committed. Each folder has
`sensitivity-metadata.csv`, `MANIFEST.sha256` and `INPUTS.sha256`; validation
checks both the permitted difference and exact reproducibility from the frozen
Diagnostic reference.
