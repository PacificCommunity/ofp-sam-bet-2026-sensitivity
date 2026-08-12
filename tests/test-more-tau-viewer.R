#!/usr/bin/env Rscript

sha256 <- function(path) {
  value <- system2("sha256sum", path, stdout = TRUE)
  sub("[[:space:]].*$", "", value[[1L]])
}
legacy_html <- file.path("results", "bet-2026-more-tau-interactive-viewer.html")
legacy_sha256 <- "499d551741e55421e52f474e062275c5f57bb476fa7bde71b0895b95edb7a9f7"
if (file.exists(legacy_html) && !identical(sha256(legacy_html), legacy_sha256)) {
  stop("Legacy 14-model viewer does not match its preserved release bytes.", call. = FALSE)
}
build_status <- system2("Rscript", file.path("scripts", "build-more-tau-viewer.R"))
if (!identical(build_status, 0L) || !file.exists(legacy_html) ||
    !identical(sha256(legacy_html), legacy_sha256)) {
  stop("Legacy viewer rebuild changed its preserved release bytes.", call. = FALSE)
}

status <- system2("Rscript", file.path("scripts", "validate-more-tau-viewer.R"))
if (!identical(status, 0L)) stop("More-tau viewer validation failed.", call. = FALSE)

config <- yaml::read_yaml("kflow-more-tau-viewer.yaml")
if (!identical(config$name, "BET-2026-sensitivity-more-tau-viewer-completed-only-v2") ||
    !identical(config$command, "Rscript scripts/run-more-tau-viewer.R") ||
    !identical(config$output_patterns, "outputs/more-tau-viewer-completed-only-v2/**") ||
    config$metadata$plotted_models != 23L || config$metadata$dependency_fits != 17L ||
    config$metadata$excluded_fits != 1L ||
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

refs <- paste(30001:30017, collapse = ",")
excluded_refs <- "tau-4.8=30018"
preview_file <- tempfile("more-tau-viewer-submit-preview-", fileext = ".json")
preview_status <- system2(
  file.path("scripts", "submit-kflow-more-tau-viewer"),
  stdout = preview_file,
  env = c(
    paste0("MORE_TAU_FIT_JOB_REFS=", refs),
    paste0("MORE_TAU_EXCLUDED_JOB_REFS=", excluded_refs)
  )
)
if (!identical(preview_status, 0L)) stop("Viewer submit preview failed.", call. = FALSE)
preview <- jsonlite::fromJSON(preview_file, simplifyVector = FALSE)
for (kind in c("report", "job")) {
  payload <- preview[[kind]]
  cohort <- jsonlite::fromJSON(payload$env$MORE_TAU_FIT_COHORT_JSON)
  excluded <- cohort[!cohort$included_in_plots, , drop = FALSE]
  tau46 <- cohort[cohort$key == "tau-4.6", , drop = FALSE]
  if (length(payload$input_jobs) != 17L ||
      !identical(as.character(unlist(payload$input_jobs)), as.character(30001:30017)) ||
      length(payload$triggers) != 0L ||
      !isTRUE(payload$metadata$input_jobs_override) ||
      !identical(payload$metadata$allow_failed_input_jobs, FALSE) ||
      payload$metadata$fit_job_count != 17L ||
      payload$metadata$fit_summary_rows != 24L ||
      nrow(cohort) != 18L || sum(cohort$included_in_plots) != 17L ||
      !identical(as.character(tau46$execution_status), "completed") ||
      !isTRUE(tau46$included_in_plots) ||
      !identical(as.character(tau46$kflow_job), "30011") ||
      !identical(as.character(excluded$key), "tau-4.8") ||
      !identical(as.character(excluded$execution_status), "failed") ||
      !identical(as.character(excluded$kflow_job), "30018") ||
      any(forbidden %in% names(payload$metadata))) {
    stop("Viewer ", kind, " payload violates its exact fan-in contract.", call. = FALSE)
  }
}

runner <- paste(readLines("scripts/run-more-tau-viewer.R", warn = FALSE), collapse = "\n")
required_runner_text <- c(
  "KFLOW_INPUT_DIR", "kflow-provenance.json", "read.MFCLRep",
  "write_model_payload_manifest",
  "MORE_TAU_VIEWER_REQUIRE_COMPLETED_ONLY", "MORE_TAU_FIT_COHORT_JSON",
  "outputs", "more-tau-viewer-completed-only-v2"
)
if (any(!vapply(required_runner_text, grepl, logical(1L), x = runner, fixed = TRUE))) {
  stop("Aggregate runner is missing dependency, rebuild, validation or output guards.", call. = FALSE)
}

submitter <- paste(readLines("scripts/submit-kflow-more-tau-viewer", warn = FALSE), collapse = "\n")
required_submitter_text <- c(
  "--recover-job", "immutable_recovery_inputs", "list_all_jobs",
  "details.report_spec", "jobs_with_key"
)
if (any(!vapply(required_submitter_text, grepl, logical(1L), x = submitter, fixed = TRUE))) {
  stop("Viewer submitter lost its all-page idempotency or read-only recovery guards.", call. = FALSE)
}

cat("Validated legacy bytes and exact 17-fit completed-only Kflow fan-in payload.\n")
