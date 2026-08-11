#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args)) {
  stop("Usage: Rscript scripts/materialize-more-tau.R", call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
registry <- read.csv(file.path(repo, "more_tau_sens.csv"), stringsAsFactors = FALSE)
original_keys <- paste0("tau-", seq(4L, 32L, by = 4L))
fine_keys <- c(
  "tau-4.2", "tau-4.4", "tau-4.6", "tau-4.8", "tau-5",
  "tau-5.2", "tau-5.4", "tau-5.6", "tau-5.8", "tau-6"
)
expected_keys <- c(original_keys, fine_keys)
if (!identical(registry$key, expected_keys)) {
  stop(
    "more_tau_sens.csv must contain the original 8 cases followed by the 10 fine cases.",
    call. = FALSE
  )
}

models <- file.path(repo, "models")
staging <- file.path(repo, paste0(".more-tau-models-staging-", Sys.getpid()))
missing_original <- original_keys[!dir.exists(file.path(models, original_keys))]
if (length(missing_original)) {
  stop("Original frozen model folders are missing: ", paste(missing_original, collapse = ", "), call. = FALSE)
}
missing <- fine_keys[!dir.exists(file.path(models, fine_keys))]
if (!length(missing)) {
  cat("All 10 fine fixed-tau input folders already exist; nothing to materialize.\n")
  quit(status = 0L)
}

dir.create(staging)
on.exit({
  if (dir.exists(staging)) unlink(staging, recursive = TRUE)
}, add = TRUE)

for (case_key in missing) {
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

for (case_key in missing) {
  source <- file.path(staging, case_key)
  target <- file.path(models, case_key)
  if (!file.rename(source, target)) stop("Could not install model folder: ", target, call. = FALSE)
}
unlink(staging, recursive = TRUE)
cat(
  "Materialized ", length(missing), " missing fine fixed-tau input folder(s): ",
  paste(missing, collapse = ", "), ".\n",
  sep = ""
)
