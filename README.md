# BET 2026 sensitivity models

This repository runs one-at-a-time sensitivities from the BET 2026
**Diagnostic model** reproduced by Kflow Job 21641. The previous main branch is
preserved unchanged on
[`tau=1`](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/tree/tau%3D1).

The common reference has fixed steepness `h=0.90`, 33 independent selectivity
groups with weak non-decreasing penalties 10,000 on F10 and F33, and direct
negative-binomial tag overdispersion fixed at `τ=2`. Every sensitivity is fitted
independently from an ordinary `bet.ini -makepar` initial PAR, rather than from
the fitted final PAR of the Diagnostic model; no seed, jitter or fitted checkpoint
is used.

## Sensitivities

`sensitivities.csv` is the machine-readable source of truth. The 17 fits
are:

| Axis | New fits | Diagnostic reference |
|---|---|---|
| Steepness | `0.65`, `0.80`, `0.95` | `0.90` fixed |
| Tag overdispersion τ | `1`, `1.2`, `1.4`, `1.6`, `1.8` | `2.0` fixed |
| Tag mixing periods | K=`0.1`, K=`0.3` | K=`0.2` |
| Conditional age-at-length | 0.5, 1.0 sub-basin | 0.75 sub-basin |
| Natural mortality | Lorenzen scalar 0.062, 0.1 | 0.078 |
| Effort creep | 2.5% then 1.25% | 1% then 0.5% |
| Regional scaling | whole period | current five-year window |
| Reporting rates during tag-mixing periods | applied | excluded |

The τ runs retain the Diagnostic direct parameterization
`τ = 1 + exp(fish_pars(4))`, `parest 305=1`, and fixed fish flags 43/44. The
lowest supported direct value uses the MFCL default lower bound
`fish_pars(4)=-5`, giving `τ=1.006737947`; report legends and tables use the
short label `τ=1`, with the finite value documented in their captions.
Exactly `τ=1` would require `fish_pars(4)=log(0)=-Inf`, so it cannot be
represented by a finite direct parameter.
The other four values use `fish_pars(4)=log(τ-1)`. No τ is estimated.

Each fit changes only its named axis. Data, selectivity, DM settings, mixing
period, biology and all other Diagnostic controls remain unchanged unless they
are the selected sensitivity axis.

## Additional fixed-tau campaign (`more_tau_sens`)

The `more_tau_sens` branch adds a separate, exploratory grid of 18 fixed values:
the original `tau=4,8,12,16,20,24,28,32` campaign and a finer
`tau=4.2,4.4,...,6.0` grid, all defined in `more_tau_sens.csv`. It does not alter
the original 17-case registry or its published report data. Each model retains the direct
parameterization `tau=1+exp(fish_pars(4))`, fixes all 33 copies of
`fish_pars(4)` at `log(tau-1)`, and starts from ordinary makepar before running
Diagnostic phases 1-11. The largest target, `tau=32`, maps to
`fish_pars(4)=log(31)=3.43398720448515`, within the supported `[-5,5]` bound
(`tau` upper bound `1+exp(5)=149.413159...`). Phase 10 and Phase 11 both use
convergence `-4`; no fitted `final.par`, checkpoint, jitter, or seed is used.

The campaign has its own frozen model folders, registry, validator, Phase-0
smoke test, Kflow configuration and submitter. The submitter preserves and
verifies the completed original eight jobs and creates the ten fine-grid jobs
as independent concurrent Suva fits from branch `more_tau_sens`:

```sh
Rscript scripts/validate-more-tau.R
./scripts/smoke-test-more-tau
./scripts/submit-kflow-more-tau
KFLOW_API_TOKEN=... ./scripts/submit-kflow-more-tau --submit
```

The existing branch-specific prerelease viewer combines the five original
fixed-tau sensitivities, the Diagnostic `tau=2` reference and the first eight
additional fits. Download
[`bet-2026-more-tau-interactive-viewer.html`](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/releases/download/more-tau-sens-v2026.08.11/bet-2026-more-tau-interactive-viewer.html)
from the branch-specific prerelease and open it locally in a web browser. This
exploratory viewer is separate from the published sensitivity report and does
not replace the stock-assessment results.

A separate completed-only fan-in Kflow job rebuilds a snapshot from the 16
completed campaign fits and the committed main public series for the five
original fixed-tau cases plus Diagnostic: 22 models are plotted. Its Fit
Summary retains all 24 requested rows, explicitly marking running `tau=4.6`
and failed `tau=4.8` (native Choleski exception) as excluded with unavailable
fit quantities. Its only artefacts are the self-contained HTML and audited
compact data below `outputs/more-tau-viewer-completed-only/`; it does not
change the report, PDFs, GitHub Pages, the existing prerelease asset, or
tracked repository data. Preview the exact completed cohort payload, then
submit it only after the viewer branch is committed and pushed:

```sh
./scripts/submit-kflow-more-tau-viewer
KFLOW_API_TOKEN=... ./scripts/submit-kflow-more-tau-viewer --submit
```

The helper discovers and verifies all 18 job records by `more-tau-<key>`, but
both its separate task and single job carry only the exact 16 completed jobs as
`input_jobs`. Preview overrides use `MORE_TAU_FIT_JOB_REFS` for those 16 jobs
and `MORE_TAU_EXCLUDED_JOB_REFS=tau-4.6=JOB,tau-4.8=JOB` for the two status-only
rows. The original eight source fits are pinned to commit `dcd289e`; the fine
grid fits are pinned to `0043eea`. The task uses `input_jobs_override`, refuses
failed dependencies, and has empty triggers and no attachment metadata.

## Inspect and run one model

Every complete frozen input set is committed under `models/`, so the effective
INI, FRQ, TAG, age-length, regional-scaling, selectivity and fitting controls can
be inspected before submission.

```sh
chmod +x mfclo64 run.sh scripts/*
./run.sh steepness-0.65
```

The fit is written to `outputs/models/steepness-0.65/`, with the final PAR at
`outputs/models/steepness-0.65/final.par`. To list all valid names:

```sh
Rscript scripts/list-sensitivities.R
```

Set `SENSITIVITY_SELECT` to the same key for Kflow. The pinned Tuna Flow 2.5
image and current report package revisions are recorded in `kflow.yaml`.

To register the `BET-2026-sensitivity-tau2` task and submit all 17 fits as
independent concurrent jobs through Suva, first inspect the payload and then
submit it:

```sh
./scripts/submit-kflow-grid
KFLOW_API_TOKEN=... ./scripts/submit-kflow-grid --submit
```

The submitter uses `sensitivities.csv` for every job title, description and
scientific-change field, skips existing `JOB_KEY` values on rerun, and verifies
each accepted job against the Kflow API.

## Validate before fitting

```sh
Rscript scripts/validate-sensitivities.R
./scripts/smoke-test
```

Validation rebuilds all 17 model folders, checks that each differs from the
Diagnostic model only in its permitted fields, verifies all manifests, and
byte-compares the generated files with the committed inputs. The smoke test
runs makepar and the fixed-value audits for every model, including the actual
tau and steepness written into the Phase-0 PAR.

Notable input rules are:

- K runs copy only release-group mixing periods from tag flag column 1 of the
  pinned K=0.1 or K=0.3 source INI.
- CAAL 0.5 halves every effective-sample-size value in the authoritative 1.0
  sub-basin file; all age-length observations remain unchanged.
- Lorenzen M runs replace only the first fixed coefficient; the length slope
  remains -1.
- High effort creep replaces only the effort field for F29-F33.
- Whole-period regional scaling uses source periods 3-292 and changes only the
  matching regional-scaling controls.
- The tag-reporting alternative changes only tag flag column 2 from 1 to 0.
  MFCL therefore applies the fitted reporting rates during each release group's
  specified mixing period; the Diagnostic setting excludes their application
  during that period. Reporting-rate values and post-mixing treatment are unchanged.

See `PROVENANCE.md` for source commits, formulas and file provenance.

## Reproduce the sensitivity report

The repository includes a compact public payload reconstructed from the final
PAR and REP files of all 17 completed fits. It contains the annual derived
quantities needed for the report and a checksum audit of each source output; it
does not rerun MFCL.

```sh
./run-report
```

This validates the public payload and writes a self-contained HTML report,
an interactive HTML viewer, eight A4-landscape figure sets in PNG and vector PDF formats, and copy-ready
Word/LaTeX design and fit/Hessian tables under `results/`. Each sensitivity axis is presented on
its own page with annual dynamic spawning depletion, recruitment, spawning
potential and fishing mortality. The Diagnostic model is shown in red, and
each alternative changes only the named axis.

The report captions open the browser-hosted GitHub Pages viewer:
[`bet-2026-sensitivity-interactive-viewer.html`](https://pacificcommunity.github.io/ofp-sam-bet-2026-sensitivity/bet-2026-sensitivity-interactive-viewer.html).
The viewer is self-contained, uses only the checksum-locked public payload and
allows individual configurations to be shown or hidden without rerunning MFCL.

The `Render BET 2026 sensitivity report` GitHub Action uses the pinned public
TunaFlow v2.7 image, checks the outputs and publishes the viewer through GitHub
Pages.
