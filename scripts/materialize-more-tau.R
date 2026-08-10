#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
replace_existing <- identical(args, "--replace")
if (length(args) > 1L || (length(args) == 1L && !replace_existing)) {
  stop("Usage: Rscript scripts/materialize-more-tau.R [--replace]", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
registry <- read.csv(file.path(repo, "more_tau_sens.csv"), stringsAsFactors = FALSE)
expected_keys <- paste0("tau-", seq(4L, 32L, by = 4L))
if (!identical(registry$key, expected_keys)) {
  stop("more_tau_sens.csv must contain exactly tau-4,8,...,32 in order.", call. = FALSE)
}

models <- file.path(repo, "models")
staging <- file.path(repo, paste0(".more-tau-models-staging-", Sys.getpid()))
backup <- file.path(repo, paste0(".more-tau-models-backup-", Sys.getpid()))
targets <- file.path(models, registry$key)
existing <- targets[dir.exists(targets)]
if (length(existing) && !replace_existing) {
  stop(
    "More-tau model folders already exist; use --replace to regenerate: ",
    paste(basename(existing), collapse = ", "),
    call. = FALSE
  )
}

dir.create(staging)
on.exit({
  if (dir.exists(staging)) unlink(staging, recursive = TRUE)
  if (dir.exists(backup)) {
    for (path in list.files(backup, full.names = TRUE)) {
      target <- file.path(models, basename(path))
      if (!dir.exists(target)) file.rename(path, target)
    }
    unlink(backup, recursive = TRUE)
  }
}, add = TRUE)

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

if (length(existing)) {
  dir.create(backup)
  for (target in existing) {
    if (!file.rename(target, file.path(backup, basename(target)))) {
      stop("Could not stage existing model folder: ", target, call. = FALSE)
    }
  }
}
for (case_key in registry$key) {
  source <- file.path(staging, case_key)
  target <- file.path(models, case_key)
  if (!file.rename(source, target)) stop("Could not install model folder: ", target, call. = FALSE)
}
if (dir.exists(backup)) unlink(backup, recursive = TRUE)
unlink(staging, recursive = TRUE)
cat("Materialized 8 fixed-tau input folders (tau=4,8,...,32) in models/.\n")
