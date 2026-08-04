# BET 2026 sensitivity models

This repository runs one-at-a-time sensitivities from the BET 2026
**Diagnostic model** reproduced by Kflow Job 21641. The previous main branch is
preserved unchanged on
[`tau=1`](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/tree/tau%3D1).

The common reference has fixed steepness `h=0.90`, 33 independent selectivity
groups with weak non-decreasing penalties 10,000 on F10 and F33, and the direct
negative-binomial tag parameter fixed at `tau=2`. Every fit starts from ordinary
`bet.ini -makepar`; no seed, jitter or fitted checkpoint is used.

## Sensitivities

`sensitivities.csv` is the machine-readable source of truth. The 20 fits
are:

| Axis | New fits | Diagnostic reference |
|---|---|---|
| Steepness | `0.65`, `0.80`, `0.95` | `0.90` fixed |
| Tag overdispersion tau | `1.006737947`, `1.2`, `1.4`, `1.6`, `1.8`, `4`, `8`, `16` | `2.0` fixed |
| Tag mixing periods | K=`0.1`, K=`0.3` | K=`0.2` |
| Conditional age-at-length | 0.5, 1.0 sub-basin | 0.75 sub-basin |
| Natural mortality | Lorenzen scalar 0.062, 0.1 | 0.078 |
| Effort creep | 2.5% then 1.25% | 1% then 0.5% |
| Regional scaling | whole period | current five-year window |
| Pre-mixing tag reporting | inclusion | exclusion |

The tau runs retain the Diagnostic direct parameterization
`tau = 1 + exp(fish_pars(4))`, `parest 305=1`, and fixed fish flags 43/44. The
lowest supported direct value uses the MFCL default lower bound
`fish_pars(4)=-5`, giving `tau=1.006737947`; it is not labelled as exactly 1.
The other seven values use `fish_pars(4)=log(tau-1)`. No tau is estimated.

Each fit changes only its named axis. Data, selectivity, DM settings, mixing
period, biology and all other Diagnostic controls remain unchanged unless they
are the selected sensitivity axis.

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

To register the `BET-2026-sensitivity-tau2` task and submit all 20 fits as
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

Validation rebuilds all 20 model folders, checks that each differs from the
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
- Reporting inclusion changes only tag flag column 2.

See `PROVENANCE.md` for source commits, formulas and file provenance.
