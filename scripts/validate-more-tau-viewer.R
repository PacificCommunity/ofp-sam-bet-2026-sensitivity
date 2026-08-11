#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE, warn = 1)

fail <- function(...) stop(..., call. = FALSE)
sha256 <- function(path) {
  value <- system2("sha256sum", path, stdout = TRUE, stderr = TRUE)
  status <- attr(value, "status")
  if (!is.null(status) && status != 0L) fail("sha256sum failed for ", path)
  sub("[[:space:]].*$", "", value[[1L]])
}
read_csv <- function(path) {
  utils::read.csv(path, check.names = FALSE, na.strings = c("", "NA"))
}

output_root <- Sys.getenv("MORE_TAU_VIEWER_OUTPUT_ROOT", "")
if (nzchar(output_root)) {
  data_dir <- file.path(output_root, "data")
  html_file <- file.path(output_root, "bet-2026-more-tau-interactive-viewer.html")
} else {
  data_dir <- file.path("data", "more-tau-viewer")
  html_file <- file.path("results", "bet-2026-more-tau-interactive-viewer.html")
}
files <- list(
  design = file.path(data_dir, "fixed-tau-design.csv"),
  series = file.path(data_dir, "fixed-tau-timeseries.csv"),
  fits = file.path(data_dir, "fixed-tau-fit-diagnostics.csv"),
  original = file.path(data_dir, "original-tau-output-provenance.csv"),
  provenance = file.path(data_dir, "more-tau-output-provenance.csv"),
  cohort = file.path(data_dir, "fit-cohort.csv"),
  input_jobs = file.path(data_dir, "kflow-input-provenance.csv"),
  sources = file.path(data_dir, "source-inputs-sha256.csv"),
  checksums = file.path(data_dir, "SHA256SUMS")
)
required_file_keys <- c("design", "series", "fits", "original", "provenance", "sources", "checksums")
required <- c(unname(unlist(files[required_file_keys])), html_file)
missing <- required[!file.exists(required)]
if (length(missing)) fail("Missing viewer artefact(s): ", paste(missing, collapse = ", "))

checksum_lines <- readLines(files$checksums, warn = FALSE)
checksum_parts <- strsplit(checksum_lines, "[[:space:]]+", perl = TRUE)
expected_names <- c(
  "fixed-tau-design.csv", "fixed-tau-timeseries.csv", "fixed-tau-fit-diagnostics.csv",
  "original-tau-output-provenance.csv", "more-tau-output-provenance.csv"
)
if (file.exists(files$cohort)) expected_names <- c(expected_names, "fit-cohort.csv")
if (file.exists(files$input_jobs)) expected_names <- c(expected_names, "kflow-input-provenance.csv")
expected_names <- c(expected_names, "source-inputs-sha256.csv")
if (length(checksum_parts) != length(expected_names) ||
    !identical(vapply(checksum_parts, `[[`, character(1), 2L), expected_names)) {
  fail("Viewer checksum manifest has the wrong files or order.")
}
for (parts in checksum_parts) {
  path <- file.path(data_dir, parts[[2L]])
  if (length(parts) != 2L || !grepl("^[0-9a-f]{64}$", parts[[1L]]) ||
      !file.exists(path) || !identical(sha256(path), parts[[1L]])) {
    fail("Viewer checksum mismatch for ", parts[[2L]], ".")
  }
}

design <- read_csv(files$design)
series <- read_csv(files$series)
fits <- read_csv(files$fits)
original <- read_csv(files$original)
provenance <- read_csv(files$provenance)
sources <- read_csv(files$sources)
completed_snapshot <- file.exists(files$cohort)
if (completed_snapshot != file.exists(files$input_jobs)) {
  fail("Completed-only cohort and Kflow input provenance must be present together.")
}
if (completed_snapshot) {
  cohort <- read_csv(files$cohort)
  input_jobs <- read_csv(files$input_jobs)
}
old_keys <- c("tau-1.006738", "tau-1.2", "tau-1.4", "tau-1.6", "tau-1.8")
old_tau <- c(1.006737947, 1.2, 1.4, 1.6, 1.8)
old_jobs <- c(22181L, 22184L, 22186L, 22188L, 22179L)
registry <- read_csv("more_tau_sens.csv")
registry_keys <- as.character(registry$key[order(as.numeric(registry$alternative))])
new_keys <- setdiff(as.character(design$key), c(old_keys, "diagnostic"))
all_keys <- c(old_keys, "diagnostic", new_keys)
legacy_new_keys <- c("tau-4", "tau-8", "tau-12", "tau-16", "tau-20", "tau-24", "tau-28", "tau-32")
legacy_snapshot <- identical(new_keys, legacy_new_keys)
registry_rows <- registry[match(new_keys, registry$key), , drop = FALSE]
if (!identical(as.character(design$key), all_keys) ||
    !identical(as.integer(design$model_order), seq_along(all_keys)) ||
    anyNA(registry_rows$key) || !identical(as.character(registry_rows$key), new_keys) ||
    !isTRUE(all.equal(as.numeric(design$fixed_tau),
      c(old_tau, 2, as.numeric(registry_rows$alternative)), tolerance = 1e-12))) {
  fail("Fixed-tau design keys, values, registry binding or ordering are incorrect.")
}
completed_new_keys <- c(
  "tau-4", "tau-4.2", "tau-4.4", "tau-5", "tau-5.2", "tau-5.4", "tau-5.6",
  "tau-5.8", "tau-6", "tau-8", "tau-12", "tau-16", "tau-20", "tau-24",
  "tau-28", "tau-32"
)
if (completed_snapshot &&
    (!identical(new_keys, completed_new_keys) || nrow(design) != 22L)) {
  fail("Completed-only viewer design must contain exactly 22 plotted models.")
}

numeric_series <- c(
  "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality"
)
if (nrow(series) != length(all_keys) * 73L || !identical(unique(series$key), all_keys)) {
  fail("Fixed-tau time series must contain 73 annual rows per model in design order.")
}
for (key in all_keys) {
  value <- series[series$key == key, , drop = FALSE]
  if (!identical(as.integer(value$year), 1952:2024) ||
      any(!is.finite(as.matrix(value[, numeric_series, drop = FALSE]))) ||
      any(as.matrix(value[, numeric_series, drop = FALSE]) < 0) ||
      !isTRUE(all.equal(value$depletion,
        value$spawning_potential / value$spawning_potential_nofish,
        tolerance = 5e-7))) {
    fail("Invalid audited 1952-2024 derived series for ", key, ".")
  }
}
main_series <- read_csv(file.path("data", "sensitivity", "sensitivity-timeseries.csv"))
main_columns <- c("year", numeric_series, "key")
for (key in c(old_keys, "diagnostic")) {
  expected <- main_series[main_series$key == key, main_columns, drop = FALSE]
  actual <- series[series$key == key, main_columns, drop = FALSE]
  if (!isTRUE(all.equal(actual, expected, tolerance = 0, check.attributes = FALSE))) {
    fail("Viewer differs from committed main public data for ", key, ".")
  }
}

fit_keys <- if (completed_snapshot) c(old_keys, "diagnostic", registry_keys) else all_keys
if (!identical(as.character(fits$key), fit_keys) ||
    !identical(as.character(provenance$key), new_keys) ||
    !identical(as.integer(provenance$kflow_job),
      as.integer(design$kflow_job[match(new_keys, design$key)]))) {
  fail("Fit Summary, design and dependency provenance disagree.")
}
new_fits <- fits[match(new_keys, fits$key), , drop = FALSE]
completed_fit_keys <- if (completed_snapshot) c(old_keys, "diagnostic", new_keys) else setdiff(all_keys, "diagnostic")
completed_fits <- fits[match(completed_fit_keys, fits$key), , drop = FALSE]
if (any(!is.finite(completed_fits$objective_function)) ||
    any(!is.finite(completed_fits$maximum_gradient_component)) ||
    any(completed_fits$maximum_gradient_component < 0) ||
    any(!is.finite(completed_fits$active_parameters))) {
  fail("A completed plotted fit has incomplete objective, MGC or parameter diagnostics.")
}
expected_status <- ifelse(
  new_fits$maximum_gradient_component <= 1e-4,
  "completed; MGC <= 1e-4", "completed; MGC above 1e-4"
)
if (any(new_fits$hessian_evaluated) || any(!is.na(new_fits$positive_definite_hessian)) ||
    any(new_fits$hessian_status != "not evaluated") ||
    !identical(as.character(new_fits$convergence_status), expected_status)) {
  fail("Additional fits claim unavailable Hessians or inconsistent MGC status.")
}
diagnostic_fit <- fits[fits$key == "diagnostic", , drop = FALSE]
if (completed_snapshot) {
  if (!all(c("execution_status", "included_in_plots") %in% names(fits)) ||
      !identical(as.character(diagnostic_fit$execution_status), "completed") ||
      !isTRUE(as.logical(diagnostic_fit$included_in_plots)) ||
      !isTRUE(all.equal(diagnostic_fit$objective_function, 90814.8573966593, tolerance = 1e-12)) ||
      !isTRUE(all.equal(diagnostic_fit$maximum_gradient_component,
        9.67941148140092e-05, tolerance = 1e-12)) ||
      diagnostic_fit$active_parameters != 1997L || diagnostic_fit$kflow_job != 21641L) {
    fail("Completed-only Diagnostic Fit Summary values are incorrect.")
  }
} else if (!all(is.na(diagnostic_fit[, c(
  "objective_function", "maximum_gradient_component", "active_parameters"
)]))) {
  fail("Legacy unavailable Diagnostic fit quantities must remain explicitly missing.")
}

if (!identical(as.character(original$key), old_keys) ||
    !identical(as.integer(original$kflow_job), old_jobs) ||
    any(original$source_commit != "63267b676538c601a19f60a38cf2a179a30e4f20") ||
    any(!grepl("^[0-9a-f]{64}$", original$final_par_sha256)) ||
    any(!grepl("^[0-9a-f]{64}$", original$plot_11_rep_sha256))) {
  fail("Original fixed-tau public output provenance is incomplete.")
}
if (completed_snapshot) {
  expected_registry_order <- as.character(registry$key)
  included <- as.logical(cohort$included_in_plots)
  expected_status_by_key <- stats::setNames(rep("completed", length(registry_keys)), registry_keys)
  expected_status_by_key[c("tau-4.6", "tau-4.8")] <- c("running", "failed")
  expected_commit_by_key <- stats::setNames(
    ifelse(
      registry_keys %in% legacy_new_keys,
      "dcd289eef9f5a63f75e11aabfb4c47af406c8abb",
      "0043eea6bf908608cd438c80b67858352abd6f89"
    ),
    registry_keys
  )
  required_cohort_columns <- c(
    "key", "kflow_job", "execution_status", "included_in_plots", "source_commit"
  )
  if (!all(required_cohort_columns %in% names(cohort)) || nrow(cohort) != 18L ||
      !identical(as.character(cohort$key), expected_registry_order) ||
      anyDuplicated(as.integer(cohort$kflow_job)) || any(!is.finite(cohort$kflow_job)) ||
      !identical(as.character(cohort$execution_status),
        unname(expected_status_by_key[cohort$key])) ||
      !identical(included, cohort$execution_status == "completed") ||
      !identical(as.character(cohort$source_commit),
        unname(expected_commit_by_key[cohort$key])) ||
      !setequal(as.character(cohort$key[included]), new_keys)) {
    fail("Completed-only all-requested fit cohort is incorrect.")
  }
  if (!identical(as.character(input_jobs$key), new_keys) || nrow(input_jobs) != 16L ||
      !identical(as.integer(input_jobs$kflow_job),
        as.integer(cohort$kflow_job[match(new_keys, cohort$key)])) ||
      !identical(as.character(input_jobs$source_commit),
        unname(expected_commit_by_key[new_keys]))) {
    fail("Completed-only Kflow input lineage is not the exact 16-fit dependency set.")
  }
  if (!identical(as.integer(design$kflow_job[match(new_keys, design$key)]),
        as.integer(cohort$kflow_job[match(new_keys, cohort$key)])) ||
      !identical(as.integer(fits$kflow_job[match(registry_keys, fits$key)]),
        as.integer(cohort$kflow_job[match(registry_keys, cohort$key)]))) {
    fail("Completed-only design/Fit Summary jobs disagree with the cohort.")
  }
  if (!identical(as.character(provenance$source_commit),
        unname(expected_commit_by_key[new_keys]))) {
    fail("Completed-only plotted provenance has an unexpected fit source commit.")
  }
  excluded_keys <- c("tau-4.6", "tau-4.8")
  excluded_fits <- fits[match(excluded_keys, fits$key), , drop = FALSE]
  if (!identical(as.character(excluded_fits$execution_status), c("running", "failed")) ||
      any(as.logical(excluded_fits$included_in_plots)) ||
      !all(is.na(excluded_fits[, c(
        "objective_function", "maximum_gradient_component", "active_parameters"
      )])) ||
      !grepl("native Choleski exception", excluded_fits$convergence_status[[2L]], fixed = TRUE) ||
      any(excluded_keys %in% design$key) || any(excluded_keys %in% unique(series$key)) ||
      any(excluded_keys %in% provenance$key)) {
    fail("Running/failed fits must remain status-only Fit Summary rows excluded from plots.")
  }
  included_fits <- fits[match(c(old_keys, "diagnostic", new_keys), fits$key), , drop = FALSE]
  if (any(included_fits$execution_status != "completed") ||
      any(!as.logical(included_fits$included_in_plots))) {
    fail("Every plotted model must be explicitly completed and included in plots.")
  }
}
if (legacy_snapshot) {
  legacy_jobs <- c(24040L, 24041L, 24042L, 24044L, 24047L, 24045L, 24043L, 24046L)
  legacy_archive_hashes <- c(
    "3d14e5d8a57e064e4b79d0661157bb87ee6ee501a8fbea28bd8ae343e5f2fa2b",
    "c61b4c43cc45a1274a1ff0462c1a999d0169bec87af8279d36fd9e093bd37fb2",
    "bc3cf6ec852d555b9dc7580848fe3e2e7295e5a09ac3d5c4d9e94f0703482480",
    NA_character_,
    "238d1a11a01b29253b3578b1d03cd7475f6ed74dcb60a12a49fa879d363ae2d4"
  )
  legacy_original_files <- file.path(sprintf("job-%06d", old_jobs), "output_archive.tar.gz")
  legacy_original_status <- rep(
    "verified local archive; required model members present", length(old_keys)
  )
  legacy_original_status[old_keys == "tau-1.6"] <-
    "archive not retained in local cache; raw-minimal output hashes verified"
  tau28 <- new_fits[new_fits$key == "tau-28", , drop = FALSE]
  if (!identical(as.integer(provenance$kflow_job), legacy_jobs) ||
      any(provenance$source_commit != "dcd289eef9f5a63f75e11aabfb4c47af406c8abb") ||
      !identical(as.character(original$archive_sha256), legacy_archive_hashes) ||
      !identical(as.character(original$archive_file), legacy_original_files) ||
      !identical(as.character(original$archive_status), legacy_original_status) ||
      nrow(tau28) != 1L ||
      !isTRUE(all.equal(tau28$maximum_gradient_component, 0.00580837932133212,
        tolerance = 1e-12)) || sum(new_fits$maximum_gradient_component <= 1e-4) != 7L) {
    fail("Legacy 14-model job mapping, original provenance or tau-28 MGC guarantee changed.")
  }
}
required_hashes <- c(
  "final_par_sha256", "plot_11_rep_sha256", "gradient_rpt_sha256",
  "model_payload_sha256", "mfcl_executable_sha256"
)
if (any(provenance$mfclkit_git_sha != "cf786007b5261f84faac8f3d24f7084bd323119d") ||
    any(provenance$mfclshiny_git_sha != "2a49729ae1203b4182c7b6d51d4ee11c52497228") ||
    any(provenance$diagnostic_source_job != 21641L) ||
    any(!grepl("^[0-9a-f]{40}$", provenance$source_commit)) ||
    any(vapply(provenance[, required_hashes, drop = FALSE], function(x) {
      any(!grepl("^[0-9a-f]{64}$", x))
    }, logical(1L))) ||
    !identical(as.character(new_fits$final_par_sha256), provenance$final_par_sha256) ||
    !identical(as.character(new_fits$plot_11_rep_sha256), provenance$plot_11_rep_sha256)) {
  fail("Additional fit checksum, commit or runtime provenance is incomplete.")
}
if ("flr4mfcl_git_sha" %in% names(provenance) &&
    any(provenance$flr4mfcl_git_sha != "3faaf84a4867175bfea50d89e4d518c085e84739")) {
  fail("FLR4MFCL extraction provenance differs from its private runtime pin.")
}

if (nrow(sources) < 7L || any(!grepl("^[0-9a-f]{64}$", sources$sha256)) ||
    any(grepl("/tmp/|/home/|suvofpsubmit|KflowOutput", sources$file, ignore.case = TRUE))) {
  fail("Source-input provenance is incomplete or exposes a private path.")
}
repository_sources <- sources[!grepl("^Staged ", sources$role), , drop = FALSE]
if (!completed_snapshot && legacy_snapshot) {
  repository_sources <- repository_sources[
    repository_sources$role != "Additional sensitivity design", , drop = FALSE
  ]
}
if (any(!file.exists(repository_sources$file)) ||
    any(vapply(seq_len(nrow(repository_sources)), function(index) {
      !identical(sha256(repository_sources$file[[index]]), repository_sources$sha256[[index]])
    }, logical(1L)))) {
  fail("A repository source no longer matches viewer provenance.")
}

html <- paste(readLines(html_file, warn = FALSE), collapse = "\n")
required_text <- c(
  "<title>BET 2026 exploratory fixed-tau sensitivity</title>",
  "Exploratory fixed-tau sensitivity results only; this is not a stock-assessment update.",
  "Fixed-tau output provenance"
)
if (completed_snapshot) {
  required_text <- c(
    required_text, "Fit Summary", "Plots include completed fits only",
    "native Choleski exception"
  )
}
if (any(!vapply(required_text, grepl, logical(1L), x = html, fixed = TRUE)) ||
    grepl("__VIEWER_DATA__", html, fixed = TRUE) ||
    grepl("<script[^>]+src[[:space:]]*=", html, ignore.case = TRUE, perl = TRUE) ||
    grepl("<link[^>]+rel[[:space:]]*=[[:space:]]*['\"]?stylesheet", html, ignore.case = TRUE, perl = TRUE) ||
    grepl("url\\([[:space:]]*['\"]?https?://", html, ignore.case = TRUE, perl = TRUE)) {
  fail("Viewer title, note, provenance or self-contained HTML contract failed.")
}
private_patterns <- c(
  "/tmp/", "/home/", "suvofpsubmit", "KflowOutput", "GITHUB_TOKEN",
  "KF_AUTH_TOKEN", "Authorization: Bearer"
)
if (any(vapply(private_patterns, grepl, logical(1L), x = html, fixed = TRUE))) {
  fail("Viewer contains a private path, host or credential marker.")
}
json_match <- regexec(
  "<script type=\"application/json\" id=\"viewer-data\">[[:space:]]*(.*)[[:space:]]*</script>[[:space:]]*<script>",
  html, perl = TRUE
)
capture <- regmatches(html, json_match)[[1L]]
if (length(capture) != 2L) fail("Could not extract embedded viewer payload.")
payload <- jsonlite::fromJSON(capture[[2L]], simplifyVector = FALSE)
if (!identical(as.character(unlist(payload$models$key)), all_keys) ||
    length(payload$metrics) != 3L ||
    length(payload$metrics[[1L]]$records$model) != length(all_keys) * 73L * 4L ||
    length(payload$metrics[[2L]]$records$Model) != length(fit_keys) ||
    length(payload$metrics[[3L]]$records$Model) != length(old_keys) + length(new_keys)) {
  fail("Embedded viewer payload has the wrong models, metrics or row counts.")
}

cat(
  "Validated standalone fixed-tau viewer: ", length(all_keys),
  " plotted models, ", length(fit_keys),
  " Fit Summary rows, 1952-2024, four key metrics and audited fit provenance.\n", sep = ""
)
