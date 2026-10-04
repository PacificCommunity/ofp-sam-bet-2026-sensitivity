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

The checks verify the saved files; `results` rebuilds the cached report.
On 64-bit x86 Linux, `rerun` regenerates detailed native outputs using the
original fitted PAR and a function-evaluation ceiling of 1. Use `CASE=all`
for all 17 fits. Choose a new output directory each time.
The saved PARs, original central REP sections and input checksums are retained
in `reproduce/`.

For a full fit, use `make refit CASE=steepness-0.65 OUT=/tmp/bet-refit`.
See [native reruns](reproduce/README.md) for model keys and verification.

See [design, validation and reproduction details](docs/reproduction.md) and
[provenance](PROVENANCE.md). The former
[τ=1 configuration](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/tree/tau%3D1)
remains available; the sensitivity labelled τ=1 uses the finite value 1.006737947.
