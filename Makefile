.PHONY: all report validate

all: report

report:
	./run-report

validate:
	sha256sum -c data/SHA256SUMS
	Rscript scripts/validate-sensitivities.R
	Rscript report/validate.R

