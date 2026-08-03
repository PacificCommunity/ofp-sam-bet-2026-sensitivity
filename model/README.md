# Frozen Job 21641 sensitivity reference

This directory is the common BET 2026 Diagnostic Job 21641 input recipe. It is
copied into a fresh run directory before one permitted sensitivity change is
applied. Do not fit it in place.

The reference is fixed `h=0.90`, direct negative-binomial `tau=2`, and the
explicit 33-independent-group Diagnostic selectivity with weak non-decreasing
penalties 10,000 on F10 and F33. `doitall.sh` starts from ordinary
`bet.ini -makepar`; it applies no seed, jitter or fitted checkpoint.

`model-inputs/Diagnostic.conf` records the fixed steepness, tau row-4 value and
Lorenzen M intercept used by the audits. Materialized folders contain their
actual sensitivity values in both the relevant MFCL input and this short
configuration file. Tau remains fixed and direct in every model.

The script audits tau, steepness, M, DM concentration and selectivity after
every fitted phase. The final fitted file is `11.par`.
