# Provenance

## Diagnostic reference

The frozen model directory and `mfclo64` come from
[`ofp-sam-bet-2026-diagnostic`](https://github.com/PacificCommunity/ofp-sam-bet-2026-diagnostic)
at commit `be953e4271e7f8119f982d5efebb21a5e8e364b3`. The model manifest is verified
before any sensitivity is prepared. The executable is a statically linked
Linux x86-64 binary and is the same executable distributed with that repository.

## External input sources

- KS D-statistic cutoffs and their derived release-group mixing periods:
  [`ofp-sam-2026-BET-YFT-build-ini`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-build-ini/tree/SC22-IP10-regionMean/BET/ini.mix-period),
  branch `SC22-IP10-regionMean`, commit
  `efe3107c72774ee73b5e6dc45e44cf51f0fc20e8`.
- CAAL: [`ofp-sam-2026-BET-YFT-age-length-build`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-age-length-build/blob/96a06d21ef3c666f39ce456d3a6818b6c17324c4/BET/bet.2026.sub.basin.1.age_length),
  commit `96a06d21ef3c666f39ce456d3a6818b6c17324c4`.
- High effort creep: [`ofp-sam-2026-BET-YFT-frq-build`](https://github.com/PacificCommunity/ofp-sam-2026-BET-YFT-frq-build/blob/504bfd2e0f100b76962d98762b68885fbddbe7dc/BET/bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq),
  commit `504bfd2e0f100b76962d98762b68885fbddbe7dc`.
- Regional scaling: the frozen 292 by 5 full-period matrix used by the BET 2026
  stepwise model, SHA-256
  `dea4c281f7dc46a7412b7ad2e78906ee57b51b62cf1a18c4609381132bf752ed`.

The preparation script verifies fixed SHA-256 hashes for every copied source
file. A source change therefore cannot silently alter a sensitivity.

## Scientific design

This is a one-at-a-time design. The Diagnostic model is the single reference;
no alternative combines two sensitivity axes. Parameters represented in
`bet.ini` and the seed-23 phase checkpoints are changed in both locations so
the checkpoint restoration cannot reset the selected sensitivity. Every
materialized model folder contains `sensitivity-metadata.csv`, a refreshed
`MANIFEST.sha256`, and an `INPUTS.sha256` audit.
