# Saved sensitivity fits

[Download native.tar.gz](https://raw.githubusercontent.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/main/reproduce/native.tar.gz). It is included in a normal clone;
[files.json](files.json) lists the archived files and checksums.

The small archive retains all 17 original final PARs. Their six native inputs
and `doitall.sh` reuse the frozen case files in this repository; the MFCL
executable comes from a checksum-verified public Git file.

On 64-bit x86 Linux, from the repository root:

```sh
make verify
make rerun CASE=all OUT=/tmp/bet-sensitivity
```

Choose a case such as `steepness-0.80` instead of `all` for one fit. Each run
uses a function-evaluation ceiling of 1, preserves every input, checks the saved objective
and compares native biomass and MSY quantities with the original REP sections,
plus annual biomass and depletion with the original public CSV. Detailed native outputs stay in the new folder.

`make verify` checks saved bytes without running MFCL. For a full fit, use
`make refit CASE=steepness-0.80 OUT=/tmp/bet-refit`; the original runner stages the nested configuration and selectivity
files required by `doitall.sh`.

The annual comparison matches all 1,241 saved rows across the 17 fits.
The original CSV extractor and historical executed binary hash remain
unconfirmed. `validation.json` records the checks and source hashes.

## Saved Hessians

[Model index](hessian-index.csv) lists the original Hessian files, final PARs and
checksums. Download only the required case:

```sh
make hessian CASE=steepness-0.80 OUT=/tmp/bet-hessian
```

Native part archives retain the original row blocks and matching final PAR.
They do not require another derivative calculation. `make hessian-verify` checks
the manifest; pass `CASE=... ARCHIVE=/absolute/model.tar.gz` to verify an offline archive.

All 17 cases include their original Hessian parts and final PAR. The index
retains the published PDH indicators.

To assemble the saved parts with the pinned MFCL executable on
Linux x86-64:

```sh
make hessian-stitch-plan CASE=steepness-0.80
make hessian-stitch CASE=steepness-0.80 OUT=/tmp/bet-hessian-stitch
```

This uses switch `145=11`; original parts and PAR remain alongside the derived
`stitched/` files and `stitch.json` checks. The historical executable hash and
byte equality to the historical merged matrix are unconfirmed.

To calculate native derivatives again, use this recorded historical recipe.
Give each part a new directory with the matching `make restore` inputs,
executable and `final.par`. For a new fit, run `make refit` above and use its
last PAR as `final.par`. Check the parameter layout before reusing that case's
inclusive `row_bounds` in [hessians.json](hessians.json).

```sh
./mfclo64 bet.frq final.par hessian.par \
  -switch 3 1 145 1 1 223 FIRSTROW 1 224 LASTROW
```

Replace `FIRSTROW` and `LASTROW` with those bounds; repeat for every part.
Each writes `bet.hes` with `145=1`. `make hessian-stitch` uses saved parts only.
This derivative calculation has not been tested by CI.

Original records say `completed` with `nonzero_status`. The scanner labels them
`failed` for "Only one non zero slot in this sample", sometimes with tag reporting
warnings during mixing. These labels do not establish convergence; the published
PDH indicators remain unchanged.
