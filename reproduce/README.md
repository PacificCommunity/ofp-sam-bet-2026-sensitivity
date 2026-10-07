# Saved sensitivity fits

[standalone.zip](standalone.zip) is included in a normal clone. It contains
17 original final PARs, native inputs, `doitall.sh`, required nested fitting
settings, compact reference values and shared MFCL engines. The native archive
uses ordinary named files, with no Python reader or runtime.

From the repository root:

```sh
make list
make verify
make prepare CASE=steepness-0.80 OUT=/tmp/bet-inputs
make rerun CASE=steepness-0.80 OUT=/tmp/bet-native
```

Choose a fresh absolute OUT. Preparation and verification use base R plus system
archive/hash tools. `rerun` requires Linux x86-64: it uses the original ceiling-one
controls `1 1 1` and `1 246 1`, checks the reported zero iteration/function
counters, and compares the saved objective, case-specific parameter count,
dimensions and central REP values. Detailed outputs stay in OUT.
Use `CASE=all` for every saved case.

For a full fit:

```sh
make refit CASE=steepness-0.80 OUT=/tmp/bet-refit
```

This runs the preserved `doitall.sh` from the saved inputs. It is a longer fit,
not part of the saved-PAR CI checks. `models.csv` records each engine and the
refit-dependency status; unsupported full-fit cases refuse to run.

The ZIP can also be unzipped and used independently with its own Makefile.
`FILES.csv`, `models.csv` and `CONTENTS.sha256` bind the native files and reference
values. The original [native.tar.gz](native.tar.gz), [closure](closure.json) and
[validation policies](validation.json) remain available for provenance.
Historical externally executed binary identities remain unconfirmed.
Published report data and HTML links are unchanged.

The annual comparison retains all 1,241 original rows: quarterly region sums
divided by four and 1,000, with depletion as annual SB/SBF0. The original CSV
extractor remains unconfirmed; the retained native references provide the
direct numerical comparison.

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

## Original derivative logs

The optional archive keeps all 17 original native MFCL derivative logs,
including likelihood, penalty and row-progress traces. Restore them without
running MFCL:

```sh
make hessian-logs OUT=/absolute/bet-native-mfcl-logs
```

Files are arranged as `CASE/part_N/mfcl_hessian_log.txt`.
[native-logs.json](native-logs.json) records exact file hashes and matches each
part to the saved Hessian row bounds. Original execution-directory lines remain
in the logs. To check a downloaded archive, use
`make hessian-logs-verify ARCHIVE=/absolute/archive.tar.gz`.
