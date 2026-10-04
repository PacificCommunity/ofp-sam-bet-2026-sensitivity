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
./run-report
python3 reproduce/run-native.py steepness-0.80 /tmp/bet-steepness
```

The first command rebuilds the report from saved results. On 64-bit x86 Linux,
the second regenerates detailed native outputs using the original fitted PAR
and one function evaluation. Use `all` instead of the case key for all 17 fits.
The saved PARs, original central REP sections and input checksums are retained
in `reproduce/`.

For a full fit, use `./run.sh steepness-0.65` in a fresh clone or scratch folder.
See [native reruns](reproduce/README.md) for model keys and verification.

See [design, validation and reproduction details](docs/reproduction.md) and
[provenance](PROVENANCE.md). The former
[τ=1 configuration](https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/tree/tau%3D1)
remains available; the sensitivity labelled τ=1 uses the finite value 1.006737947.
