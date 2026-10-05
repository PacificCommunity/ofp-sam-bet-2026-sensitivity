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

The index preserves the published PDH indicators. Cases whose original parts
are still being recovered are not included yet.

To assemble the saved parts with the pinned MFCL executable on
Linux x86-64:

```sh
make hessian-stitch-plan CASE=steepness-0.80
make hessian-stitch CASE=steepness-0.80 OUT=/tmp/bet-hessian-stitch
```

This uses switch `145=11`; original parts and PAR remain alongside the derived
`stitched/` files and `stitch.json` checks. The historical executable hash and
byte equality to the historical merged matrix are unconfirmed.
