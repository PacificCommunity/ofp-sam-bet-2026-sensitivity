#!/usr/bin/env Rscript

status <- system2("Rscript", file.path("scripts", "validate-more-tau-viewer.R"))
if (!identical(status, 0L)) stop("More-tau viewer validation failed.", call. = FALSE)

config <- yaml::read_yaml("kflow-more-tau-viewer.yaml")
if (!identical(config$name, "BET-2026-sensitivity-more-tau-viewer") ||
    !identical(config$command, "Rscript scripts/run-more-tau-viewer.R") ||
    !identical(config$output_patterns, "outputs/more-tau-viewer/**") ||
    length(config$triggers) != 0L || !is.null(config$local_apps) ||
    !is.null(config$local_apps_from)) {
  stop("Aggregate viewer Kflow configuration changed its branch-only contract.", call. = FALSE)
}
forbidden <- c(
  "attachment", "attachments", "base_job", "check_input_jobs", "check_type",
  "diagnostic-support", "latest_attached_output", "source_base_job"
)
if (any(forbidden %in% names(config$metadata))) {
  stop("Aggregate viewer config contains attachment/base/check metadata.", call. = FALSE)
}

refs <- paste(30001:30018, collapse = ",")
preview_file <- tempfile("more-tau-viewer-submit-preview-", fileext = ".json")
preview_status <- system2(
  file.path("scripts", "submit-kflow-more-tau-viewer"),
  stdout = preview_file,
  env = paste0("MORE_TAU_FIT_JOB_REFS=", refs)
)
if (!identical(preview_status, 0L)) stop("Viewer submit preview failed.", call. = FALSE)
preview <- jsonlite::fromJSON(preview_file, simplifyVector = FALSE)
for (kind in c("report", "job")) {
  payload <- preview[[kind]]
  if (length(payload$input_jobs) != 18L ||
      !identical(as.character(unlist(payload$input_jobs)), as.character(30001:30018)) ||
      length(payload$triggers) != 0L ||
      !isTRUE(payload$metadata$input_jobs_override) ||
      !identical(payload$metadata$allow_failed_input_jobs, FALSE) ||
      any(forbidden %in% names(payload$metadata))) {
    stop("Viewer ", kind, " payload violates its exact fan-in contract.", call. = FALSE)
  }
}

runner <- paste(readLines("scripts/run-more-tau-viewer.R", warn = FALSE), collapse = "\n")
required_runner_text <- c(
  "KFLOW_INPUT_DIR", "kflow-provenance.json", "read.MFCLRep",
  "write_model_payload_manifest",
  "MORE_TAU_VIEWER_REQUIRE_COMPLETE", "outputs", "more-tau-viewer"
)
if (any(!vapply(required_runner_text, grepl, logical(1L), x = runner, fixed = TRUE))) {
  stop("Aggregate runner is missing dependency, rebuild, validation or output guards.", call. = FALSE)
}

cat("Validated legacy viewer and exact 18-fit branch-only Kflow fan-in payload.\n")
