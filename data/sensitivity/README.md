# Public sensitivity report payload

This directory contains the compact, checksum-locked data needed to reproduce
the BET 2026 sensitivity figures and table without rerunning MFCL.

- `sensitivity-timeseries.rds` and `sensitivity-timeseries.csv` contain the
  same annual derived quantities for the Diagnostic model and 17 completed
  one-at-a-time sensitivity fits.
- `sensitivity-design.csv` records the eight sensitivity axes, their
  Diagnostic-model settings and their alternatives.
- `completed-output-audit.csv` records the controls and SHA-256 hashes verified
  against each completed model's final PAR and REP files.

The public payload contains derived quantities and audit metadata only. It does
not contain credentials, internal host names or internal filesystem paths.

