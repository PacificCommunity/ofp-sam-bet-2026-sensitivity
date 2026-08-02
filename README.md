# BET 2026 sensitivity models

This repository runs one-at-a-time sensitivities from the frozen BET 2026
**Diagnostic model**. Every run starts from the same Diagnostic inputs and the
same deterministic seed-23 initialization path. The preparation script changes
only the selected sensitivity setting, including the archived phase checkpoint
when that parameter is stored in the PAR file, and then runs the original
11-phase `doitall.sh`.

The Diagnostic model is the common reference and is not fitted again here.
Its checked reference settings are steepness 0.8, mixing period 0.2, CAAL 0.75
sub-basin, Lorenzen M scalar 0.078, low effort creep (1% then 0.5%), the
current five-year regional-scaling window, and pre-mixing reporting exclusion.

## Sensitivities

`sensitivities.csv` is the machine-readable source of truth. The eleven new
fits are:

| Axis | New fits | Diagnostic reference |
|---|---|---|
| Steepness | `Steepness 0.65`, `Steepness 0.95` | 0.8 |
| Tag mixing period | `Mixing period 0.1`, `Mixing period 0.3` | 0.2 |
| Conditional age-at-length | `CAAL 0.5 sub-basin`, `CAAL 1.0 sub-basin` | 0.75 sub-basin |
| Natural mortality | `Lorenzen M scalar 0.062`, `Lorenzen M scalar 0.1` | 0.078 |
| Effort creep | `Effort creep high (2.5% / 1.25%)` | 1% / 0.5% |
| Regional scaling | `Regional scaling whole period` | current five-year window |
| Pre-mixing tag reporting | `Pre-mixing tag reporting inclusion` | pre-mixing exclusion |

Dirichlet-multinomial settings are unchanged from the Diagnostic model.

## Run one model

Linux x86-64 and R are required. The repository includes the statically linked
MFCL executable.

```sh
chmod +x mfclo64 run.sh scripts/*
./run.sh steepness-0.65
```

Each complete frozen input set is also available directly under `models/` for
inspection. The fit is written to `outputs/models/steepness-0.65/`, with the
final PAR at `outputs/models/steepness-0.65/final.par`. To list all valid names:

```sh
Rscript scripts/list-sensitivities.R
```

Set `SENSITIVITY_SELECT` to the same name when submitting through Kflow. Each
Kflow job runs one sensitivity and uses the pinned tuna-flow v2.5 image in
`kflow.yaml`.

## Validate before fitting

```sh
Rscript scripts/validate-sensitivities.R
./scripts/smoke-test
```

The first command independently rebuilds all eleven inputs in temporary
directories, checks that each differs from the Diagnostic model only in its
permitted fields, and byte-compares it with the corresponding committed
`models/<case>/` folder. The second runs MFCL `-makepar` from every committed
input folder.

Notable input rules are:

- Mixing-period runs copy only tag flag column 1 from the pinned 0.1 or 0.3
  source INI. Tag flag column 2 and reporting-rate matrices remain Diagnostic.
- CAAL 0.5 multiplies every effective-sample-size value in the authoritative
  1.0 sub-basin file by 0.5; all age-length records remain unchanged.
- Lorenzen M scalar runs replace only the first Lorenzen M coefficient with
  `log(0.062)` or `log(0.1)` and retain the length coefficient of -1.
- High effort creep copies only field 6 for F29-F33 from the authoritative high
  FRQ, matched by year, month, week and fishery. All 1,458 records are checked;
  1,440 change and the 18 records in the 1952 baseline year remain equal.
- Whole-period regional scaling uses the headerless 290 by 5 matrix for periods
  3-292. F32 begins in period 3. Flags 77-81 are `100, 1, 290, 0, 1`.
- Reporting inclusion changes only tag flag column 2 from 1 to 0.

See `PROVENANCE.md` for source commits and file hashes.
