# Saved sensitivity fits

The small archive retains all 17 original final PARs. Their six native inputs
and `doitall.sh` reuse the frozen case files in this repository; the MFCL
executable comes from a checksum-verified public Git file.

On 64-bit x86 Linux, from the repository root:

```sh
python3 reproduce/run-native.py all /tmp/bet-sensitivity
```

Choose a case such as `steepness-0.80` instead of `all` for one fit. Each run
uses one function evaluation, preserves every input, checks the saved objective
and compares native biomass and MSY quantities with the original REP sections,
plus annual biomass and depletion with the original public CSV. Detailed native outputs stay in the new folder.

`python3 reproduce/restore.py --verify` checks the compact archive without
running MFCL. Full fits use the original runner, for example
`./run.sh steepness-0.80`; it stages the nested configuration and selectivity
files required by `doitall.sh`.

The annual comparison matches all 1,241 saved rows across the 17 fits.
The original CSV extractor and historical executed binary hash remain
unconfirmed. `validation.json` records the checks and source hashes.
