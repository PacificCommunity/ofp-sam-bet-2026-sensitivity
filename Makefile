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
RSCRIPT ?= Rscript
export CASE OUT
.PHONY: verify rerun restore refit results prepare list rerun-help

help rerun-help:
	@printf '%s\n' 'make list' 'make verify' 'make prepare CASE=CASE OUT=/absolute/new-folder' 'make rerun CASE=CASE OUT=/absolute/new-folder' 'make refit CASE=CASE OUT=/absolute/new-folder' 'Use CASE=all for saved-model preparation or evaluation. Native runs require Linux x86-64.'

list verify:
	@"$(RSCRIPT)" reproduce/run-final.R "$@"

prepare restore rerun refit:
	@"$(RSCRIPT)" reproduce/run-final.R "$@" "$$CASE" "$$OUT"

results:
	@./run-report

export ARCHIVE
.PHONY: hessian hessian-verify

hessian:
	@if [ -n "$$ARCHIVE" ]; then \
		$(RSCRIPT) reproduce/hessian.R --case "$$CASE" --out "$$OUT" --archive "$$ARCHIVE"; \
	else \
		$(RSCRIPT) reproduce/hessian.R --case "$$CASE" --out "$$OUT"; \
	fi

hessian-verify:
	@if [ -n "$$ARCHIVE" ]; then \
		$(RSCRIPT) reproduce/hessian.R --verify --case "$$CASE" --archive "$$ARCHIVE"; \
	else \
		$(RSCRIPT) reproduce/hessian.R --verify; \
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

# Optional original native MFCL derivative traces; no model execution.
.PHONY: hessian-logs hessian-logs-verify

hessian-logs:
	@if [ -n "$$ARCHIVE" ]; then \
		$(RSCRIPT) reproduce/native_logs.R --out "$$OUT" --archive "$$ARCHIVE"; \
	else \
		$(RSCRIPT) reproduce/native_logs.R --out "$$OUT"; \
	fi

hessian-logs-verify:
	@if [ -n "$$ARCHIVE" ]; then \
		$(RSCRIPT) reproduce/native_logs.R --verify --archive "$$ARCHIVE"; \
	else \
		$(RSCRIPT) reproduce/native_logs.R --verify; \
	fi

.PHONY: verify-source
verify: verify-source
verify-source:
	@sha256sum --quiet -c ci/PRESERVED.sha256
