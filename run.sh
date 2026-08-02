#!/bin/sh
set -eu

case_key=${SENSITIVITY_SELECT:-${1:-}}
if [ -z "$case_key" ]; then
  echo "Set SENSITIVITY_SELECT or run: ./run.sh CASE" >&2
  Rscript scripts/list-sensitivities.R >&2
  exit 2
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
./scripts/run-sensitivity "$case_key" "$repo_dir/outputs/models/$case_key"
