#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE, warn = 1)

fail <- function(...) stop(..., call. = FALSE)

data_dir <- file.path("data", "more-tau-viewer")
design_file <- file.path(data_dir, "fixed-tau-design.csv")
series_file <- file.path(data_dir, "fixed-tau-timeseries.csv")
fits_file <- file.path(data_dir, "fixed-tau-fit-diagnostics.csv")
original_provenance_file <- file.path(data_dir, "original-tau-output-provenance.csv")
provenance_file <- file.path(data_dir, "more-tau-output-provenance.csv")
sources_file <- file.path(data_dir, "source-inputs-sha256.csv")
checksums_file <- file.path(data_dir, "SHA256SUMS")
html_file <- file.path("results", "bet-2026-more-tau-interactive-viewer.html")

old_keys <- c("tau-1.006738", "tau-1.2", "tau-1.4", "tau-1.6", "tau-1.8")
new_keys <- c("tau-4", "tau-8", "tau-12", "tau-16", "tau-20", "tau-24", "tau-28", "tau-32")
all_keys <- c(old_keys, "diagnostic", new_keys)
expected_tau <- c(1.006737947, 1.2, 1.4, 1.6, 1.8, 2, 4, 8, 12, 16, 20, 24, 28, 32)
expected_old_jobs <- c(22181L, 22184L, 22186L, 22188L, 22179L)
expected_jobs <- c(24040L, 24041L, 24042L, 24044L, 24047L, 24045L, 24043L, 24046L)

required <- c(
  design_file, series_file, fits_file, original_provenance_file,
  provenance_file, sources_file, checksums_file, html_file
)
missing <- required[!file.exists(required)]
if (length(missing)) fail("Missing viewer artefact(s): ", paste(missing, collapse = ", "))

sha256 <- function(path) {
  value <- system2("sha256sum", path, stdout = TRUE, stderr = TRUE)
  status <- attr(value, "status")
  if (!is.null(status) && status != 0L) fail("sha256sum failed for ", path)
  sub("[[:space:]].*$", "", value[[1L]])
}

checksum_lines <- readLines(checksums_file, warn = FALSE)
if (length(checksum_lines) != 6L) fail("Expected six committed-data checksums.")
checksum_parts <- strsplit(checksum_lines, "[[:space:]]+", perl = TRUE)
for (parts in checksum_parts) {
  if (length(parts) != 2L || !grepl("^[0-9a-f]{64}$", parts[[1L]])) {
    fail("Malformed committed-data checksum line.")
  }
  path <- file.path(data_dir, parts[[2L]])
  if (!file.exists(path) || !identical(sha256(path), parts[[1L]])) {
    fail("Committed-data checksum mismatch for ", parts[[2L]], ".")
  }
}

design <- utils::read.csv(design_file, check.names = FALSE, na.strings = c("", "NA"))
series <- utils::read.csv(series_file, check.names = FALSE, na.strings = c("", "NA"))
fits <- utils::read.csv(fits_file, check.names = FALSE, na.strings = c("", "NA"))
original_provenance <- utils::read.csv(
  original_provenance_file,
  check.names = FALSE,
  na.strings = c("", "NA")
)
provenance <- utils::read.csv(provenance_file, check.names = FALSE, na.strings = c("", "NA"))
sources <- utils::read.csv(sources_file, check.names = FALSE, na.strings = c("", "NA"))

if (!identical(as.character(design$key), all_keys) ||
    !isTRUE(all.equal(as.numeric(design$fixed_tau), expected_tau, tolerance = 1e-12)) ||
    !identical(as.integer(design$model_order), seq_along(all_keys)) ||
    !identical(
      as.integer(design$kflow_job),
      c(expected_old_jobs, 21641L, expected_jobs)
    )) {
  fail("Fixed-tau design keys, values or ordering are incorrect.")
}
if (nrow(series) != length(all_keys) * 73L || !identical(unique(series$key), all_keys)) {
  fail("Fixed-tau time series do not contain 73 rows for all 14 models.")
}
numeric_series <- c(
  "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality"
)
for (key in all_keys) {
  value <- series[series$key == key, , drop = FALSE]
  if (!identical(as.integer(value$year), 1952:2024) ||
      any(!is.finite(as.matrix(value[, numeric_series, drop = FALSE]))) ||
      any(as.matrix(value[, numeric_series, drop = FALSE]) < 0)) {
    fail("Invalid 1952-2024 series for ", key, ".")
  }
  reconstructed <- value$spawning_potential / value$spawning_potential_nofish
  if (!isTRUE(all.equal(value$depletion, reconstructed, tolerance = 5e-7))) {
    fail("Depletion identity failed for ", key, ".")
  }
}

main_design <- utils::read.csv("sensitivities.csv", check.names = FALSE)
main_tau <- main_design[main_design$key %in% old_keys, , drop = FALSE]
main_tau <- main_tau[match(old_keys, main_tau$key), , drop = FALSE]
if (!identical(main_tau$key, old_keys) ||
    !isTRUE(all.equal(as.numeric(main_tau$alternative), expected_tau[seq_along(old_keys)], tolerance = 1e-12))) {
  fail("Viewer old-tau values do not match sensitivities.csv.")
}
additional_design <- utils::read.csv("more_tau_sens.csv", check.names = FALSE)
additional_tau <- additional_design[match(new_keys, additional_design$key), , drop = FALSE]
if (!identical(additional_tau$key, new_keys) ||
    !isTRUE(all.equal(as.numeric(additional_tau$alternative), expected_tau[7:14], tolerance = 1e-12))) {
  fail("Viewer additional-tau values do not match more_tau_sens.csv.")
}
main_series <- utils::read.csv(
  file.path("data", "sensitivity", "sensitivity-timeseries.csv"),
  check.names = FALSE
)
main_columns <- c("year", numeric_series, "key")
for (key in c(old_keys, "diagnostic")) {
  expected <- main_series[main_series$key == key, main_columns, drop = FALSE]
  actual <- series[series$key == key, main_columns, drop = FALSE]
  if (!isTRUE(all.equal(actual, expected, tolerance = 0, check.attributes = FALSE))) {
    fail("Viewer series differs from the committed main public payload for ", key, ".")
  }
}

if (!identical(as.character(fits$key), all_keys) ||
    !identical(as.integer(fits$kflow_job), c(expected_old_jobs, 21641L, expected_jobs))) {
  fail("Fit diagnostics do not cover all models and exact Kflow jobs.")
}
non_diagnostic <- fits$key != "diagnostic"
if (any(!is.finite(fits$objective_function[non_diagnostic])) ||
    any(!is.finite(fits$maximum_gradient_component[non_diagnostic])) ||
    any(fits$maximum_gradient_component[non_diagnostic] < 0) ||
    any(!is.finite(fits$active_parameters[non_diagnostic]))) {
  fail("A non-Diagnostic fit has incomplete objective, MGC or parameter diagnostics.")
}
if (!all(is.na(fits[fits$key == "diagnostic", c(
  "objective_function", "maximum_gradient_component", "active_parameters"
)]))) {
  fail("Unavailable Diagnostic fit quantities must remain explicitly missing.")
}
new_fits <- fits[match(new_keys, fits$key), , drop = FALSE]
old_fits <- fits[match(old_keys, fits$key), , drop = FALSE]
if (any(new_fits$hessian_evaluated) || any(!is.na(new_fits$positive_definite_hessian)) ||
    any(new_fits$hessian_status != "not evaluated")) {
  fail("More-tau fits must not claim an unevaluated Hessian or PDH result.")
}
expected_status <- rep("completed; MGC <= 1e-4", length(new_keys))
expected_status[new_keys == "tau-28"] <- "completed; MGC above 1e-4"
if (!identical(as.character(new_fits$convergence_status), expected_status) ||
    !isTRUE(all.equal(
      new_fits$maximum_gradient_component[new_fits$key == "tau-28"],
      0.00580837932133212,
      tolerance = 1e-12
    )) ||
    sum(new_fits$maximum_gradient_component <= 1e-4) != 7L) {
  fail("More-tau MGC status must flag tau-28 and only tau-28 above 1e-4.")
}

expected_original_archives <- c(
  "3d14e5d8a57e064e4b79d0661157bb87ee6ee501a8fbea28bd8ae343e5f2fa2b",
  "c61b4c43cc45a1274a1ff0462c1a999d0169bec87af8279d36fd9e093bd37fb2",
  "bc3cf6ec852d555b9dc7580848fe3e2e7295e5a09ac3d5c4d9e94f0703482480",
  NA_character_,
  "238d1a11a01b29253b3578b1d03cd7475f6ed74dcb60a12a49fa879d363ae2d4"
)
expected_original_files <- file.path(
  sprintf("job-%06d", expected_old_jobs),
  "output_archive.tar.gz"
)
expected_original_status <- rep(
  "verified local archive; required model members present",
  length(old_keys)
)
expected_original_status[old_keys == "tau-1.6"] <- paste0(
  "archive not retained in local cache; raw-minimal output hashes verified"
)
if (!identical(as.character(original_provenance$key), old_keys) ||
    !identical(as.integer(original_provenance$kflow_job), expected_old_jobs) ||
    any(original_provenance$source_commit != "63267b676538c601a19f60a38cf2a179a30e4f20") ||
    !identical(as.character(original_provenance$archive_file), expected_original_files) ||
    !identical(as.character(original_provenance$archive_status), expected_original_status) ||
    !identical(as.character(original_provenance$archive_sha256), expected_original_archives) ||
    any(!grepl("^[0-9a-f]{64}$", original_provenance$final_par_sha256)) ||
    any(!grepl("^[0-9a-f]{64}$", original_provenance$plot_11_rep_sha256)) ||
    any(!grepl("^[0-9a-f]{64}$", original_provenance$model_payload_sha256)) ||
    any(original_provenance$diagnostic_source_job != 21641L) ||
    any(original_provenance$diagnostic_source_commit != "e93b9bc6284b17cc5ab2af4ccabb1cfe776e76a5") ||
    !identical(as.character(old_fits$final_par_sha256), as.character(original_provenance$final_par_sha256)) ||
    !identical(as.character(old_fits$plot_11_rep_sha256), as.character(original_provenance$plot_11_rep_sha256))) {
  fail("Original fixed-tau Kflow job, source-commit or output provenance is incomplete.")
}

hash_columns <- c(
  "archive_sha256", "final_par_sha256", "plot_11_rep_sha256",
  "gradient_rpt_sha256", "model_payload_sha256", "mfcl_executable_sha256",
  "mfclkit_git_sha", "mfclshiny_git_sha", "diagnostic_source_commit", "source_commit"
)
if (!identical(as.character(provenance$key), new_keys) ||
    !identical(as.integer(provenance$kflow_job), expected_jobs) ||
    any(provenance$source_commit != "dcd289eef9f5a63f75e11aabfb4c47af406c8abb") ||
    any(provenance$mfclkit_git_sha != "cf786007b5261f84faac8f3d24f7084bd323119d") ||
    any(provenance$mfclshiny_git_sha != "2a49729ae1203b4182c7b6d51d4ee11c52497228") ||
    any(provenance$diagnostic_source_job != 21641L) ||
    any(vapply(provenance[, hash_columns, drop = FALSE], function(x) {
      any(!grepl("^[0-9a-f]{40}$|^[0-9a-f]{64}$", x))
    }, logical(1)))) {
  fail("More-tau job, commit or checksum provenance is incomplete.")
}
if (!identical(as.character(new_fits$final_par_sha256), as.character(provenance$final_par_sha256)) ||
    !identical(as.character(new_fits$plot_11_rep_sha256), as.character(provenance$plot_11_rep_sha256))) {
  fail("More-tau fit diagnostics and output provenance hashes disagree.")
}
if (nrow(sources) != 7L || any(!grepl("^[0-9a-f]{64}$", sources$sha256)) ||
    any(grepl("/tmp/|/home/|suvofpsubmit|KflowOutput", sources$file, ignore.case = TRUE))) {
  fail("Source-input provenance is incomplete or exposes a private path.")
}
repository_sources <- sources[sources$file != "derived-timeseries-raw.csv", , drop = FALSE]
if (any(!file.exists(repository_sources$file)) ||
    any(vapply(seq_len(nrow(repository_sources)), function(index) {
      !identical(sha256(repository_sources$file[[index]]), repository_sources$sha256[[index]])
    }, logical(1)))) {
  fail("A repository source no longer matches the recorded viewer provenance.")
}

html <- paste(readLines(html_file, warn = FALSE), collapse = "\n")
required_text <- c(
  "<title>BET 2026 exploratory fixed-tau sensitivity</title>",
  "Exploratory fixed-tau sensitivity results only; this is not a stock-assessment update.",
  "Fixed-tau output provenance"
)
if (any(!vapply(required_text, grepl, logical(1), x = html, fixed = TRUE))) {
  fail("Viewer title, interpretation note or provenance tab is missing.")
}
if (grepl("__VIEWER_DATA__", html, fixed = TRUE) ||
    grepl("<script[^>]+src[[:space:]]*=", html, ignore.case = TRUE, perl = TRUE) ||
    grepl("<link[^>]+rel[[:space:]]*=[[:space:]]*['\"]?stylesheet", html, ignore.case = TRUE, perl = TRUE) ||
    grepl("url\\([[:space:]]*['\"]?https?://", html, ignore.case = TRUE, perl = TRUE)) {
  fail("Viewer is not fully self-contained.")
}
private_patterns <- c(
  "/tmp/", "/home/", "suvofpsubmit", "KflowOutput", "GITHUB_TOKEN",
  "KF_AUTH_TOKEN", "Authorization: Bearer"
)
if (any(vapply(private_patterns, grepl, logical(1), x = html, fixed = TRUE))) {
  fail("Viewer contains a private path, host or credential marker.")
}

json_match <- regexec(
  "<script type=\"application/json\" id=\"viewer-data\">[[:space:]]*(.*)[[:space:]]*</script>[[:space:]]*<script>",
  html,
  perl = TRUE
)
json_capture <- regmatches(html, json_match)[[1L]]
if (length(json_capture) != 2L) fail("Could not extract the embedded viewer payload.")
payload <- jsonlite::fromJSON(json_capture[[2L]], simplifyVector = FALSE)
if (!identical(payload$title, "BET 2026 exploratory fixed-tau sensitivity") ||
    !identical(as.character(unlist(payload$models$key)), all_keys) ||
    length(payload$metrics) != 3L ||
    length(payload$metrics[[1L]]$records$model) != length(all_keys) * 73L * 4L ||
    length(payload$metrics[[2L]]$records$Model) != length(all_keys) ||
    length(payload$metrics[[3L]]$records$Model) != length(old_keys) + length(new_keys)) {
  fail("Embedded viewer payload has the wrong models, metrics or row counts.")
}

cat(
  "Validated standalone fixed-tau viewer: 14 models, 1952-2024, four key metrics, ",
  "audited diagnostics and exact provenance for 13 sensitivity jobs.\n",
  sep = ""
)
