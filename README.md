[![Preservation checks](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/actions/workflows/verify-preserved-results.yml/badge.svg?branch=main)](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/actions/workflows/verify-preserved-results.yml?query=branch%3Amain) [![Model checks](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/actions/workflows/validate.yml?query=branch%3Amain)

# BET 2026 sensitivity models

<a id="sensitivities"></a>
<a id="inspect-and-run-one-model"></a>
<a id="validate-before-fitting"></a>
<a id="reproduce-the-sensitivity-report"></a>

[Report](https://pacificcommunity.github.io/ofp-sam-bet-2026-sensitivity/bet-2026-sensitivity-report.html)
· [Interactive viewer](https://pacificcommunity.github.io/ofp-sam-bet-2026-sensitivity/bet-2026-sensitivity-interactive-viewer.html).

Seventeen independent fits test eight axes around the BET 2026 Diagnostic
model. `sensitivities.csv` lists every configuration; `models/` contains the
complete frozen inputs. Each fit begins with ordinary `bet.ini -makepar`.

From the repository root:

```sh
make verify
make results
make rerun CASE=steepness-0.80 OUT=/tmp/bet-steepness
```

`verify` checks the self-contained [native bundle](reproduce/standalone.zip).
`results` rebuilds the cached report. `rerun` evaluates the original final PAR
on Linux x86-64, checks the native zero counters, objective and reference values,
and writes detailed outputs to a fresh OUT. Use `CASE=all` for all 17 fits.

Only base R and system archive/hash tools are needed to list, verify or prepare
files. `make prepare CASE=steepness-0.80 OUT=/tmp/bet-inputs` restores a working
copy without executing MFCL. `make refit CASE=steepness-0.80 OUT=/tmp/bet-refit`
runs the original complete fit. See [native reruns](reproduce/README.md).

See [design, validation and reproduction details](docs/reproduction.md) and
[provenance](PROVENANCE.md). The former
[τ=1 configuration](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/tree/tau%3D1)
remains available; the sensitivity labelled τ=1 uses the finite value 1.006737947.
