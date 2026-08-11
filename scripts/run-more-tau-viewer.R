#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE, warn = 1)

fail <- function(...) stop(..., call. = FALSE)
truthy <- function(name) tolower(trimws(Sys.getenv(name, ""))) %in% c("1", "true", "yes", "on")
sha256 <- function(path) {
  value <- system2("sha256sum", path, stdout = TRUE, stderr = TRUE)
  status <- attr(value, "status")
  if (!is.null(status) && status != 0L) fail("sha256sum failed for ", path)
  sub("[[:space:]].*$", "", value[[1L]])
}
read_final_value <- function(path, heading) {
  lines <- readLines(path, warn = FALSE)
  hit <- which(trimws(lines) == heading)
  if (length(hit) != 1L || hit[[1L]] == length(lines)) {
    fail("Could not identify '", heading, "' in ", path)
  }
  value <- suppressWarnings(as.numeric(trimws(lines[[hit[[1L]] + 1L]])))
  if (length(value) != 1L || !is.finite(value)) fail("Invalid ", heading, " in ", path)
  value
}

root <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
input_root <- normalizePath(
  Sys.getenv("KFLOW_INPUT_DIR", unset = ""), winslash = "/", mustWork = FALSE
)
if (!nzchar(input_root) || !dir.exists(input_root)) {
  fail("KFLOW_INPUT_DIR must identify the extracted Kflow dependency archives.")
}
expected_output_dir <- file.path(root, "outputs", "more-tau-viewer")
output_dir <- Sys.getenv("MORE_TAU_VIEWER_OUTPUT_ROOT", unset = expected_output_dir)
output_dir <- normalizePath(output_dir, winslash = "/", mustWork = FALSE)
if (!identical(output_dir, normalizePath(
  expected_output_dir, winslash = "/", mustWork = FALSE
))) {
  fail("The Kflow viewer output must be exactly outputs/more-tau-viewer.")
}
if (dir.exists(output_dir) && length(list.files(output_dir, all.files = TRUE, no.. = TRUE))) {
  fail("Refusing to overwrite a non-empty aggregate viewer output directory.")
}
tracked_before <- system2("git", c("diff", "--no-ext-diff", "--", "."), stdout = TRUE)

pins <- c(
  FLR4MFCL_GITHUB_REF = "3faaf84a4867175bfea50d89e4d518c085e84739",
  MFCLKIT_GITHUB_REF = "cf786007b5261f84faac8f3d24f7084bd323119d",
  MFCLSHINY_GITHUB_REF = "2a49729ae1203b4182c7b6d51d4ee11c52497228"
)
for (name in names(pins)) {
  observed <- trimws(Sys.getenv(name, pins[[name]]))
  if (!identical(observed, pins[[name]])) fail(name, " differs from the audited viewer pin.")
}
for (package in c("FLR4MFCL", "mfclkit", "mfclshiny", "jsonlite")) {
  if (!requireNamespace(package, quietly = TRUE)) fail("Missing pinned runtime package: ", package)
}

registry <- utils::read.csv(file.path(root, "more_tau_sens.csv"), check.names = FALSE)
required_registry <- c("key", "axis", "alternative")
if (!all(required_registry %in% names(registry)) || nrow(registry) != 18L ||
    any(registry$axis != "Tag overdispersion") || anyDuplicated(registry$key)) {
  fail("more_tau_sens.csv must define exactly the 18 aggregate fixed-tau fits.")
}
expected_keys <- as.character(registry$key[order(as.numeric(registry$alternative))])
original_campaign_keys <- sprintf("tau-%d", seq(4L, 32L, by = 4L))
original_source_commit <- "dcd289eef9f5a63f75e11aabfb4c47af406c8abb"
checkout_head <- system2("git", c("rev-parse", "HEAD"), stdout = TRUE)
if (length(checkout_head) != 1L || !grepl("^[0-9a-f]{40}$", checkout_head)) {
  fail("Could not identify the immutable aggregate-viewer checkout commit.")
}

final_files <- list.files(
  input_root, pattern = "^final[.]par$", recursive = TRUE, full.names = TRUE
)
model_dirs <- unique(dirname(final_files))
model_dirs <- model_dirs[basename(model_dirs) %in% expected_keys]
model_dirs <- model_dirs[vapply(model_dirs, function(path) {
  all(file.exists(file.path(path, c(
    "plot-11.par.rep", "gradient.rpt", "model-input-audit.csv",
    "tag-tau-audit.csv", "sensitivity-metadata.csv", "mfclo64"
  ))))
}, logical(1L))]
keys_found <- basename(model_dirs)
if (anyDuplicated(keys_found) || !setequal(keys_found, expected_keys)) {
  fail(
    "Expected one complete extracted model for every registry key; found ",
    length(keys_found), " of ", length(expected_keys), "."
  )
}
model_dirs <- model_dirs[match(expected_keys, keys_found)]

provenance_file <- Sys.getenv(
  "KFLOW_PROVENANCE_FILE", file.path(input_root, "kflow-provenance.json")
)
if (!file.exists(provenance_file)) fail("Missing Kflow dependency provenance: ", provenance_file)
ledger <- jsonlite::fromJSON(provenance_file, simplifyDataFrame = TRUE)
inputs <- ledger$inputs
if (!is.data.frame(inputs) || nrow(inputs) != length(expected_keys)) {
  fail("Kflow provenance must contain exactly 18 dependency input records.")
}
required_inputs <- c("job_id", "job_number", "job_key", "git_commit_sha")
if (!all(required_inputs %in% names(inputs)) || anyDuplicated(inputs$job_id)) {
  fail("Kflow provenance input records are incomplete or duplicated.")
}

staging_root <- tempfile("more-tau-viewer-models-")
dir.create(staging_root, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(staging_root, recursive = TRUE, force = TRUE), add = TRUE)
staged_dirs <- character(length(expected_keys))
lineage_rows <- vector("list", length(expected_keys))

for (index in seq_along(expected_keys)) {
  key <- expected_keys[[index]]
  source_dir <- normalizePath(model_dirs[[index]], winslash = "/", mustWork = TRUE)
  relative_source <- substring(source_dir, nchar(input_root) + 2L)
  input_job_id <- strsplit(relative_source, "/", fixed = TRUE)[[1L]][[1L]]
  input_row <- inputs[as.character(inputs$job_id) == input_job_id, , drop = FALSE]
  expected_source_commit <- if (key %in% original_campaign_keys) {
    original_source_commit
  } else {
    checkout_head
  }
  if (nrow(input_row) != 1L ||
      !identical(as.character(input_row$job_key), paste0("more-tau-", key)) ||
      !identical(as.character(input_row$git_commit_sha), expected_source_commit) ||
      ("task" %in% names(input_row) &&
        !identical(as.character(input_row$task), "BET-2026-sensitivity-more-tau")) ||
      ("repo" %in% names(input_row) &&
        !identical(as.character(input_row$repo),
          "PacificCommunity/ofp-sam-bet-2026-sensitivity")) ||
      ("branch" %in% names(input_row) &&
        !identical(as.character(input_row$branch), "more_tau_sens")) ||
      ("status" %in% names(input_row) &&
        !identical(tolower(as.character(input_row$status)), "completed"))) {
    fail("Could not bind ", key, " to one exact Kflow input provenance record.")
  }

  staged_dir <- file.path(staging_root, key)
  dir.create(staged_dir, recursive = TRUE, showWarnings = FALSE)
  copied <- system2("cp", c("-a", paste0(source_dir, "/."), staged_dir))
  if (!identical(copied, 0L)) fail("Could not stage extracted model output for ", key, ".")
  rep_object <- FLR4MFCL::read.MFCLRep(file.path(staged_dir, "plot-11.par.rep"))
  payload <- list(
    version = "v1",
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    folder = key,
    object_cache_mode = "core",
    artifact_mode = "none",
    files = list(par = "final.par", rep = "plot-11.par.rep"),
    obj_fun = read_final_value(file.path(staged_dir, "final.par"), "# Objective function value"),
    max_grad = read_final_value(
      file.path(staged_dir, "final.par"), "# Maximum magnitude gradient value"
    ),
    data = list(RepOut = rep_object, info = list(model = key))
  )
  payload_file <- file.path(staged_dir, "model_payload.rds")
  saveRDS(payload, payload_file)
  mfclshiny::write_model_payload_manifest(
    payload = payload, folder = staged_dir, payload_file = payload_file
  )
  if (!file.exists(file.path(staged_dir, "model_payload.rds")) ||
      !file.exists(file.path(staged_dir, "model_payload_manifest.csv"))) {
    fail("Pinned mfclshiny did not build a complete payload for ", key, ".")
  }
  staged_dirs[[index]] <- staged_dir
  lineage_rows[[index]] <- data.frame(
    key = key,
    kflow_job = as.integer(input_row$job_number),
    source_commit = as.character(input_row$git_commit_sha),
    input_job_id = input_job_id,
    model_relative_dir = key,
    final_par_sha256 = sha256(file.path(staged_dir, "final.par")),
    plot_11_rep_sha256 = sha256(file.path(staged_dir, "plot-11.par.rep")),
    stringsAsFactors = FALSE
  )
}

collect_data <- getFromNamespace("mfclshiny_report_collect_data", "mfclshiny")
collected <- collect_data(
  folders = staged_dirs,
  recursive = FALSE,
  build_payloads = FALSE,
  read_model_timeseries = TRUE
)
series <- collected$data
if (!is.data.frame(series) || nrow(series) != length(expected_keys) * 73L ||
    !setequal(unique(series$model_key), expected_keys)) {
  fail("Pinned MFCL packages did not derive 73 annual rows for every input model.")
}
series$model_key <- factor(series$model_key, levels = expected_keys)
series <- series[order(series$model_key, series$year), , drop = FALSE]
series$model_key <- as.character(series$model_key)
row.names(series) <- NULL
lineage <- do.call(rbind, lineage_rows)

audit_root <- tempfile("more-tau-viewer-audit-")
dir.create(audit_root, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(audit_root, recursive = TRUE, force = TRUE), add = TRUE)
series_file <- file.path(audit_root, "derived-timeseries-raw.csv")
lineage_file <- file.path(audit_root, "kflow-input-provenance.csv")
utils::write.csv(series, series_file, row.names = FALSE, na = "")
utils::write.csv(lineage, lineage_file, row.names = FALSE, na = "")

Sys.setenv(
  MORE_TAU_DERIVED_SERIES = series_file,
  MORE_TAU_RAW_ROOT = staging_root,
  MORE_TAU_JOB_PROVENANCE = lineage_file,
  MORE_TAU_VIEWER_OUTPUT_ROOT = output_dir,
  MORE_TAU_VIEWER_REQUIRE_COMPLETE = "true"
)
build_status <- system2(
  "Rscript", c(file.path(root, "scripts", "build-more-tau-viewer.R"), "--refresh-data")
)
if (!identical(build_status, 0L)) fail("Aggregate viewer build failed.")

validation_status <- system2(
  "Rscript", file.path(root, "scripts", "validate-more-tau-viewer.R")
)
if (!identical(validation_status, 0L)) fail("Aggregate viewer validation failed.")

if (!file.exists(file.path(output_dir, "bet-2026-more-tau-interactive-viewer.html"))) {
  fail("The aggregate fixed-tau viewer was not created.")
}
expected_outputs <- sort(c(
  "bet-2026-more-tau-interactive-viewer.html",
  file.path("data", c(
    "SHA256SUMS", "fixed-tau-design.csv", "fixed-tau-fit-diagnostics.csv",
    "fixed-tau-timeseries.csv", "kflow-input-provenance.csv",
    "more-tau-output-provenance.csv", "original-tau-output-provenance.csv",
    "source-inputs-sha256.csv"
  ))
))
actual_output_paths <- list.files(output_dir, recursive = TRUE, full.names = TRUE)
actual_outputs <- sort(substring(actual_output_paths, nchar(output_dir) + 2L))
if (!identical(actual_outputs, expected_outputs) ||
    any(grepl("[.](pdf|tex|docx)$", actual_outputs, ignore.case = TRUE))) {
  fail("The aggregate job wrote files outside the exact viewer/data output contract.")
}
tracked_after <- system2("git", c("diff", "--no-ext-diff", "--", "."), stdout = TRUE)
if (!identical(tracked_after, tracked_before)) {
  fail("The aggregate viewer runner modified tracked repository content.")
}
message("Built audited 24-model fixed-tau viewer from 18 Kflow dependency archives.")
