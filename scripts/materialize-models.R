#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
replace_existing <- identical(args, "--replace")
if (length(args) > 1L || (length(args) == 1L && !replace_existing)) {
  stop("Usage: Rscript scripts/materialize-models.R [--replace]", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
registry <- read.csv(file.path(repo, "sensitivities.csv"), stringsAsFactors = FALSE)
models <- file.path(repo, "models")
staging <- file.path(repo, paste0(".models-staging-", Sys.getpid()))
backup <- file.path(repo, paste0(".models-backup-", Sys.getpid()))
on.exit({
  if (dir.exists(staging)) unlink(staging, recursive = TRUE)
  if (dir.exists(backup) && !dir.exists(models)) file.rename(backup, models)
}, add = TRUE)

if (dir.exists(models) && !replace_existing) {
  stop("models/ already exists; use --replace to regenerate it.", call. = FALSE)
}
dir.create(staging)

for (case_key in registry$key) {
  destination <- file.path(staging, case_key)
  status <- system2(
    "Rscript",
    c(file.path(repo, "scripts/prepare-sensitivity.R"), case_key, destination)
  )
  if (!identical(status, 0L)) stop("Failed to prepare ", case_key, call. = FALSE)

  executable <- file.path(destination, "mfclo64")
  if (!file.exists(executable)) stop("Prepared model is missing mfclo64.", call. = FALSE)
  unlink(executable)

  input_manifest <- file.path(destination, "INPUTS.sha256")
  manifest <- read.table(input_manifest, col.names = c("sha256", "file"), stringsAsFactors = FALSE)
  manifest <- manifest[manifest$file != "mfclo64", , drop = FALSE]
  write.table(manifest, input_manifest, row.names = FALSE, col.names = FALSE, quote = FALSE)
}

if (dir.exists(models)) {
  if (!file.rename(models, backup)) stop("Could not stage the existing models/ directory.", call. = FALSE)
}
if (!file.rename(staging, models)) stop("Could not install the regenerated models/ directory.", call. = FALSE)
if (dir.exists(backup)) unlink(backup, recursive = TRUE)
cat("Materialized ", nrow(registry), " sensitivity input folders in models/.\n", sep = "")
