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
