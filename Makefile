.PHONY: all report validate

all: report

report:
	./run-report

validate:
	sha256sum -c data/SHA256SUMS
	Rscript scripts/validate-sensitivities.R
	Rscript report/validate.R

CASE ?= all
OUT ?=
export CASE OUT
.PHONY: help verify rerun restore refit results _check-output

help:
	@printf '%s\n' 'make verify                                      Check saved files' 'make results                                     Rebuild the cached report' 'make rerun CASE=all OUT=/tmp/bet-sensitivity       Regenerate saved native outputs' 'make refit CASE=steepness-0.80 OUT=/tmp/bet-refit   Fit one model from the start' 'Native runs require Linux x86-64; use a new OUT.'

verify:
	@python3 reproduce/hessian.py --verify
	@python3 ci/verify-preserved-files.py
	@python3 reproduce/restore.py --verify

rerun: verify _check-output
	@python3 reproduce/run-native.py "$$CASE" "$$OUT"

restore: verify _check-output
	@python3 reproduce/restore.py "$$CASE" "$$OUT"

refit: verify _check-output
	@test -f "models/$$CASE/doitall.sh" || { echo 'Choose one model, e.g. CASE=steepness-0.80.' >&2; exit 2; }
	@./scripts/run-sensitivity "$$CASE" "$$OUT"

results: report

_check-output:
	@python3 -c 'import os; from pathlib import Path; raw=os.environ.get("OUT",""); p=Path(raw); root=Path.cwd().resolve(); assert raw and p.is_absolute(), "Set OUT to an absolute, new directory"; assert not os.path.lexists(p), "OUT already exists"; q=p.resolve(); assert q != root and root not in q.parents, "OUT must be outside this repository"'

export ARCHIVE
.PHONY: hessian hessian-verify

hessian:
	@if [ -n "$$ARCHIVE" ]; then \
		python3 reproduce/hessian.py --case "$$CASE" --out "$$OUT" --archive "$$ARCHIVE"; \
	else \
		python3 reproduce/hessian.py --case "$$CASE" --out "$$OUT"; \
	fi

hessian-verify:
	@if [ -n "$$ARCHIVE" ]; then \
		python3 reproduce/hessian.py --verify --case "$$CASE" --archive "$$ARCHIVE"; \
	else \
		python3 reproduce/hessian.py --verify; \
	fi

# Keep the existing hessian and hessian-verify targets; add these optional targets.
export CASE OUT ARCHIVE
.PHONY: hessian-stitch-plan hessian-stitch

hessian-stitch-plan:
	@python3 reproduce/hessian_stitch.py --plan --case "$$CASE"

hessian-stitch:
	@if [ -n "$$ARCHIVE" ]; then \
		python3 reproduce/hessian_stitch.py --case "$$CASE" --out "$$OUT" --archive "$$ARCHIVE"; \
	else \
		python3 reproduce/hessian_stitch.py --case "$$CASE" --out "$$OUT"; \
	fi
