# Fixed-tau branch viewer data

These files support the standalone exploratory fixed-tau viewer on the
`more_tau_sens` branch. They are additional sensitivity work and are not a
stock-assessment update.

The committed snapshot combines only the fixed-tau cases from the published main
sensitivity payload (`tau = 1.006738, 1.2, 1.4, 1.6, 1.8`), the Diagnostic
reference (`tau = 2`), and the eight additional Kflow fits (`tau = 4, 8, 12,
16, 20, 24, 28, 32`). Every model has annual values for 1952--2024 for dynamic
depletion, recruitment, spawning potential and fishing mortality.

The refreshed completed-only Kflow fan-in rebuild is intentionally not committed
here. It plots the 17 completed more-tau fits (23 models including the main five
and Diagnostic), while its Fit Summary retains all 18 requested more-tau rows
(24 rows total). Completed `tau=4.6` is plotted and explicitly flagged above the
`1e-4` MGC threshold. Failed `tau=4.8` is the only status-only row with missing
fit quantities and is excluded from plots. Output is written only to
`outputs/more-tau-viewer-completed-only-v2/`. The runner rebuilds
`model_payload.rds` from each completed dependency archive's raw `final.par`
and `plot-11.par.rep` with pinned FLR4MFCL, mfclkit and mfclshiny packages; it
does not assume payloads were stored in the fit archives.

- `fixed-tau-design.csv` defines the 14 displayed models and their sources.
- `fixed-tau-timeseries.csv` contains the compact annual plotting data.
- `fixed-tau-fit-diagnostics.csv` records objective, MGC and source details.
  The additional eight jobs did not evaluate Hessians, so no PDH result is
  claimed for them. All eight completed; seven have MGC at or below `1e-4`,
  while `tau = 28` is retained and explicitly flagged above that threshold.
- `original-tau-output-provenance.csv` records the exact Kflow jobs and source
  commit for the five original fixed-tau cases. Four retained local archives
  are hashed and checked for their expected model members. The Job 22188
  archive is not retained in the local cache, so its verified `raw-minimal`
  `final.par`, `plot-11.par.rep` and payload hashes are retained explicitly
  without inventing an archive hash.
- `more-tau-output-provenance.csv` records each new Kflow job, source commit,
  archive and output hashes, and the exact `mfclkit` and `mfclshiny` commits
  used for extraction.
- `source-inputs-sha256.csv` records the inputs used to assemble this payload
  without retaining machine-private paths.
- `SHA256SUMS` protects the five committed CSV payloads.

The fan-in output additionally includes `fit-cohort.csv` for all 18 requested
fits and `kflow-input-provenance.csv` for the exact 17 completed dependencies,
binding keys to dynamically resolved Kflow jobs and immutable fit commits. Job
numbers are never hard-coded in the viewer builder.

Rebuild the HTML from the committed CSVs with:

```sh
Rscript scripts/build-more-tau-viewer.R
Rscript scripts/validate-more-tau-viewer.R
```

Maintainers can refresh the compact payload from staged completed outputs by
setting `MORE_TAU_DERIVED_SERIES`, `MORE_TAU_RAW_ROOT`,
`MORE_TAU_JOB_PROVENANCE`, `MORE_TAU_FIT_COHORT`,
`MORE_TAU_INCLUDED_KEYS` and `MORE_TAU_VIEWER_OUTPUT_ROOT`, then adding
`--refresh-data` to the build command. Normally
`scripts/run-more-tau-viewer.R` performs that audited staging and refresh from
`KFLOW_INPUT_DIR` automatically.
