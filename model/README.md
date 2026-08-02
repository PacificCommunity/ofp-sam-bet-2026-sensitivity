# Frozen Diagnostic model

This directory contains the unmodified Diagnostic inputs, eleven-phase
`doitall.sh`, and seed-23 checkpoints used as the reference for every
sensitivity.

Do not edit these files. Run a sensitivity from the repository root:

```sh
./run.sh steepness-0.65
```

`scripts/prepare-sensitivity.R` verifies `MANIFEST.sha256`, copies this directory
to a new run directory, applies one selected change, and refreshes the run
manifest before fitting.
