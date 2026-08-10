#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE, warn = 1)

data_dir <- file.path("data", "more-tau-viewer")
output_file <- file.path("results", "bet-2026-more-tau-interactive-viewer.html")
source_date <- "2026-08-11"

old_design_file <- "sensitivities.csv"
new_design_file <- "more_tau_sens.csv"
main_series_file <- file.path("data", "sensitivity", "sensitivity-timeseries.csv")
main_fits_file <- file.path("data", "sensitivity", "sensitivity-fit-diagnostics.csv")
main_audit_file <- file.path("data", "sensitivity", "completed-output-audit.csv")
template_file <- file.path("report", "interactive-viewer-template.html")

compact_design_file <- file.path(data_dir, "fixed-tau-design.csv")
compact_series_file <- file.path(data_dir, "fixed-tau-timeseries.csv")
compact_fits_file <- file.path(data_dir, "fixed-tau-fit-diagnostics.csv")
compact_original_provenance_file <- file.path(data_dir, "original-tau-output-provenance.csv")
compact_provenance_file <- file.path(data_dir, "more-tau-output-provenance.csv")
compact_sources_file <- file.path(data_dir, "source-inputs-sha256.csv")
compact_checksums_file <- file.path(data_dir, "SHA256SUMS")

old_keys <- c("tau-1.006738", "tau-1.2", "tau-1.4", "tau-1.6", "tau-1.8")
new_keys <- c("tau-4", "tau-8", "tau-12", "tau-16", "tau-20", "tau-24", "tau-28", "tau-32")
all_keys <- c(old_keys, "diagnostic", new_keys)
old_job_by_key <- c(
  "tau-1.006738" = 22181L,
  "tau-1.2" = 22184L,
  "tau-1.4" = 22186L,
  "tau-1.6" = 22188L,
  "tau-1.8" = 22179L
)
job_by_key <- c(
  "tau-4" = 24040L,
  "tau-8" = 24041L,
  "tau-12" = 24042L,
  "tau-16" = 24044L,
  "tau-20" = 24047L,
  "tau-24" = 24045L,
  "tau-28" = 24043L,
  "tau-32" = 24046L
)

original_tau_source_commit <- "63267b676538c601a19f60a38cf2a179a30e4f20"
more_tau_source_commit <- "dcd289eef9f5a63f75e11aabfb4c47af406c8abb"
diagnostic_source_commit <- "e93b9bc6284b17cc5ab2af4ccabb1cfe776e76a5"
mfclkit_git_sha <- "cf786007b5261f84faac8f3d24f7084bd323119d"
mfclshiny_git_sha <- "2a49729ae1203b4182c7b6d51d4ee11c52497228"

fail <- function(...) stop(..., call. = FALSE)

read_csv <- function(path) {
  if (!file.exists(path)) fail("Missing required file: ", path)
  utils::read.csv(path, check.names = FALSE, na.strings = c("NA", ""))
}

sha256 <- function(path) {
  if (!file.exists(path)) fail("Cannot checksum missing file: ", path)
  value <- system2("sha256sum", path, stdout = TRUE, stderr = TRUE)
  status <- attr(value, "status")
  if (!is.null(status) && status != 0L) fail("sha256sum failed for ", path)
  sub("[[:space:]].*$", "", value[[1L]])
}

read_one_row <- function(path) {
  value <- read_csv(path)
  if (nrow(value) != 1L) fail("Expected exactly one row in ", path)
  value
}

read_final_value <- function(path, heading) {
  lines <- readLines(path, warn = FALSE)
  hit <- which(trimws(lines) == heading)
  if (length(hit) != 1L || hit[[1L]] == length(lines)) {
    fail("Could not identify '", heading, "' in ", path)
  }
  value <- suppressWarnings(as.numeric(trimws(lines[[hit[[1L]] + 1L]])))
  if (length(value) != 1L || !is.finite(value)) {
    fail("Invalid value following '", heading, "' in ", path)
  }
  value
}

read_gradient_mgc <- function(path, expected_parameters) {
  lines <- readLines(path, warn = FALSE)
  if (length(lines) < 2L) fail("Gradient report is incomplete: ", path)
  count <- suppressWarnings(as.integer(trimws(lines[[1L]])))
  values <- scan(text = lines[[2L]], what = numeric(), quiet = TRUE)
  if (is.na(count) || count != expected_parameters || length(values) != count || any(!is.finite(values))) {
    fail("Gradient report parameter count is inconsistent: ", path)
  }
  max(abs(values))
}

check_series <- function(series, keys) {
  required <- c(
    "year", "depletion", "spawning_potential", "spawning_potential_nofish",
    "recruitment", "fishing_mortality", "key"
  )
  if (!all(required %in% names(series))) fail("Fixed-tau series schema is incomplete.")
  if (!identical(unique(series$key), keys)) fail("Fixed-tau series model order is incorrect.")
  numeric_columns <- setdiff(required, c("year", "key"))
  for (key in keys) {
    value <- series[series$key == key, , drop = FALSE]
    if (!identical(as.integer(value$year), 1952:2024)) {
      fail("Expected annual coverage 1952-2024 for ", key, ".")
    }
    if (any(!is.finite(as.matrix(value[, numeric_columns, drop = FALSE])))) {
      fail("Non-finite fixed-tau derived quantity for ", key, ".")
    }
    if (any(as.matrix(value[, numeric_columns, drop = FALSE]) < 0)) {
      fail("Negative fixed-tau derived quantity for ", key, ".")
    }
    reconstructed <- value$spawning_potential / value$spawning_potential_nofish
    if (!isTRUE(all.equal(value$depletion, reconstructed, tolerance = 5e-7))) {
      fail("Depletion does not reproduce SB/SB(F=0) for ", key, ".")
    }
  }
  invisible(TRUE)
}

refresh_compact_data <- function() {
  raw_series_file <- Sys.getenv("MORE_TAU_DERIVED_SERIES", unset = "")
  raw_root <- Sys.getenv("MORE_TAU_RAW_ROOT", unset = "")
  archive_root <- Sys.getenv("MORE_TAU_ARCHIVE_ROOT", unset = "")
  original_output_root <- Sys.getenv("ORIGINAL_TAU_OUTPUT_ROOT", unset = "")
  supplied <- nzchar(c(raw_series_file, raw_root, archive_root, original_output_root))
  if (!all(supplied)) {
    fail(
      "Refreshing requires MORE_TAU_DERIVED_SERIES, MORE_TAU_RAW_ROOT and ",
      "MORE_TAU_ARCHIVE_ROOT, plus ORIGINAL_TAU_OUTPUT_ROOT."
    )
  }
  if (!file.exists(raw_series_file) || !dir.exists(raw_root) || !dir.exists(archive_root) ||
      !dir.exists(original_output_root)) {
    fail("One or more fixed-tau refresh inputs do not exist.")
  }

  old_design_all <- read_csv(old_design_file)
  new_design <- read_csv(new_design_file)
  required_design <- c("key", "axis", "label", "reference", "alternative", "scientific_change")
  if (!all(required_design %in% names(old_design_all)) || !all(required_design %in% names(new_design))) {
    fail("A fixed-tau design file has an incomplete schema.")
  }
  old_design <- old_design_all[old_design_all$key %in% old_keys, required_design, drop = FALSE]
  old_design <- old_design[match(old_keys, old_design$key), , drop = FALSE]
  new_design <- new_design[match(new_keys, new_design$key), required_design, drop = FALSE]
  if (anyNA(old_design$key) || anyNA(new_design$key) ||
      !identical(old_design$key, old_keys) || !identical(new_design$key, new_keys)) {
    fail("Fixed-tau cases do not match the expected main and more_tau_sens designs.")
  }
  if (any(old_design$axis != "Tag overdispersion") || any(new_design$axis != "Tag overdispersion")) {
    fail("A selected case is not a tag-overdispersion sensitivity.")
  }

  old_tau <- as.numeric(old_design$alternative)
  new_tau <- as.numeric(new_design$alternative)
  design <- rbind(
    data.frame(
      key = old_design$key,
      fixed_tau = old_tau,
      label = paste0("tau = ", sub("^Tau ", "", old_design$label)),
      campaign = "Original fixed-tau sensitivity",
      kflow_job = unname(as.integer(old_job_by_key[old_design$key])),
      source = "Original fixed-tau Kflow output and committed public payload",
      stringsAsFactors = FALSE
    ),
    data.frame(
      key = "diagnostic",
      fixed_tau = 2,
      label = "tau = 2 (Diagnostic)",
      campaign = "Diagnostic reference",
      kflow_job = 21641L,
      source = "Diagnostic public time series from Kflow Job 21641",
      stringsAsFactors = FALSE
    ),
    data.frame(
      key = new_design$key,
      fixed_tau = new_tau,
      label = paste0("tau = ", sub("^Tau ", "", new_design$label)),
      campaign = "Additional fixed-tau sensitivity",
      kflow_job = unname(as.integer(job_by_key[new_design$key])),
      source = "more_tau_sens Kflow output archive",
      stringsAsFactors = FALSE
    )
  )
  design$model_order <- seq_len(nrow(design))
  design <- design[, c("key", "fixed_tau", "label", "campaign", "kflow_job", "source", "model_order")]
  if (!identical(design$key, all_keys) || any(!is.finite(design$fixed_tau))) {
    fail("Combined fixed-tau design is inconsistent.")
  }

  keep_series <- c(
    "year", "depletion", "spawning_potential", "spawning_potential_nofish",
    "recruitment", "fishing_mortality", "key"
  )
  main_series <- read_csv(main_series_file)
  main_selected <- main_series[main_series$key %in% c(old_keys, "diagnostic"), keep_series, drop = FALSE]
  main_selected$key <- as.character(main_selected$key)

  raw_series <- read_csv(raw_series_file)
  required_raw <- c(
    "year", "depletion", "spawning_potential", "spawning_potential_nofish",
    "recruitment", "fishing_mortality", "model_key", "region"
  )
  if (!all(required_raw %in% names(raw_series))) fail("Raw more-tau time-series schema is incomplete.")
  if (!identical(sort(unique(raw_series$model_key)), sort(new_keys)) || any(raw_series$region != "All")) {
    fail("Raw more-tau series contain an unexpected model or region.")
  }
  new_selected <- raw_series[, required_raw, drop = FALSE]
  names(new_selected)[names(new_selected) == "model_key"] <- "key"
  new_selected$region <- NULL
  new_selected <- new_selected[, keep_series, drop = FALSE]

  combined_series <- rbind(main_selected, new_selected)
  combined_series$key <- factor(combined_series$key, levels = all_keys)
  combined_series <- combined_series[order(combined_series$key, combined_series$year), , drop = FALSE]
  combined_series$key <- as.character(combined_series$key)
  row.names(combined_series) <- NULL
  check_series(combined_series, all_keys)

  main_fits <- read_csv(main_fits_file)
  main_audit <- read_csv(main_audit_file)
  main_fits <- main_fits[match(old_keys, main_fits$key), , drop = FALSE]
  main_audit <- main_audit[match(old_keys, main_audit$key), , drop = FALSE]
  if (anyNA(main_fits$key) || anyNA(main_audit$key)) fail("Main fixed-tau fit records are incomplete.")

  old_fit_jobs <- unname(as.integer(old_job_by_key[old_keys]))
  old_fits <- data.frame(
    key = old_keys,
    fixed_tau = old_tau,
    objective_function = as.numeric(main_fits$objective_function),
    maximum_gradient_component = as.numeric(main_fits$maximum_gradient_component),
    active_parameters = as.integer(main_fits$active_parameters),
    hessian_evaluated = as.logical(main_fits$hessian_evaluated),
    positive_definite_hessian = as.logical(main_fits$positive_definite_hessian),
    hessian_status = ifelse(
      as.logical(main_fits$hessian_evaluated),
      ifelse(as.logical(main_fits$positive_definite_hessian), "positive definite", "not positive definite"),
      "not evaluated"
    ),
    convergence_status = ifelse(
      as.numeric(main_fits$maximum_gradient_component) <= 1e-4,
      "completed; MGC <= 1e-4",
      "completed; MGC above 1e-4"
    ),
    kflow_job = old_fit_jobs,
    source = "Original fixed-tau Kflow output and committed public payload",
    final_par_sha256 = as.character(main_audit$final_par_sha256),
    plot_11_rep_sha256 = as.character(main_audit$final_rep_sha256),
    stringsAsFactors = FALSE
  )

  original_provenance_rows <- list()
  for (key in old_keys) {
    job <- unname(as.integer(old_job_by_key[[key]]))
    raw_dir <- file.path(original_output_root, "raw-minimal", key)
    final_file <- file.path(raw_dir, "final.par")
    rep_file <- file.path(raw_dir, "plot-11.par.rep")
    payload_file <- file.path(raw_dir, "model_payload.rds")
    metadata_file <- file.path(raw_dir, "sensitivity-metadata.csv")
    manifest_file <- file.path(raw_dir, "model_payload_manifest.csv")
    required <- c(final_file, rep_file, payload_file, metadata_file, manifest_file)
    if (any(!file.exists(required))) fail("Original raw-minimal evidence is incomplete for ", key, ".")

    metadata <- read_one_row(metadata_file)
    manifest <- read_one_row(manifest_file)
    audit_row <- main_audit[main_audit$key == key, , drop = FALSE]
    checks <- c(
      identical(as.character(metadata$key), key),
      identical(as.character(metadata$axis), "Tag overdispersion"),
      as.integer(metadata$diagnostic_source_job) == 21641L,
      identical(as.character(metadata$diagnostic_source_commit), diagnostic_source_commit),
      identical(as.character(manifest$schema), "mfclshiny.model_payload_manifest.v1"),
      identical(as.character(manifest$model_label), key),
      identical(sha256(final_file), as.character(audit_row$final_par_sha256)),
      identical(sha256(rep_file), as.character(audit_row$final_rep_sha256)),
      isTRUE(all.equal(as.numeric(manifest$obj_fun),
        main_fits$objective_function[main_fits$key == key], tolerance = 1e-12)),
      isTRUE(all.equal(as.numeric(manifest$max_grad),
        main_fits$maximum_gradient_component[main_fits$key == key], tolerance = 1e-12))
    )
    if (!all(checks)) fail("Original output provenance audit failed for ", key, ".")

    relative_archive <- file.path(sprintf("job-%06d", job), "output_archive.tar.gz")
    archive_file <- file.path(original_output_root, relative_archive)
    archive_available <- file.exists(archive_file)
    if (archive_available) {
      members <- system2("tar", c("-tzf", archive_file), stdout = TRUE, stderr = TRUE)
      tar_status <- attr(members, "status")
      expected_members <- paste0(
        "./outputs/models/", key, "/",
        c("final.par", "plot-11.par.rep", "sensitivity-metadata.csv")
      )
      if ((!is.null(tar_status) && tar_status != 0L) || !all(expected_members %in% members)) {
        fail("Original Kflow archive membership failed for ", key, ".")
      }
    }

    original_provenance_rows[[key]] <- data.frame(
      key = key,
      fixed_tau = as.numeric(old_design$alternative[old_design$key == key]),
      campaign = "Original fixed-tau sensitivity",
      kflow_job = job,
      source_commit = original_tau_source_commit,
      archive_file = relative_archive,
      archive_status = if (archive_available) {
        "verified local archive; required model members present"
      } else {
        "archive not retained in local cache; raw-minimal output hashes verified"
      },
      archive_sha256 = if (archive_available) sha256(archive_file) else NA_character_,
      final_par_sha256 = sha256(final_file),
      plot_11_rep_sha256 = sha256(rep_file),
      gradient_rpt_sha256 = NA_character_,
      model_payload_sha256 = sha256(payload_file),
      mfcl_executable_sha256 = NA_character_,
      mfclkit_git_sha = NA_character_,
      mfclshiny_git_sha = NA_character_,
      diagnostic_source_job = 21641L,
      diagnostic_source_commit = diagnostic_source_commit,
      payload_created_at = as.character(manifest$created_at),
      stringsAsFactors = FALSE
    )
  }
  original_provenance <- do.call(rbind, original_provenance_rows)
  row.names(original_provenance) <- NULL

  new_fit_rows <- list()
  provenance_rows <- list()
  for (key in new_keys) {
    job <- unname(as.integer(job_by_key[[key]]))
    tau <- as.numeric(new_design$alternative[new_design$key == key])
    model_dir <- file.path(raw_root, paste0("job-", job), "outputs", "models", key)
    archive_file <- file.path(archive_root, paste0("job-", job, ".tar.gz"))
    required <- file.path(
      model_dir,
      c(
        "final.par", "plot-11.par.rep", "gradient.rpt", "model_payload.rds",
        "model_payload_manifest.csv", "model-input-audit.csv", "tag-tau-audit.csv",
        "sensitivity-metadata.csv", "mfclo64"
      )
    )
    if (any(!file.exists(required)) || !file.exists(archive_file)) {
      fail("Raw output or archive is incomplete for ", key, ".")
    }

    model_audit <- read_one_row(file.path(model_dir, "model-input-audit.csv"))
    tau_audit <- read_one_row(file.path(model_dir, "tag-tau-audit.csv"))
    metadata <- read_one_row(file.path(model_dir, "sensitivity-metadata.csv"))
    manifest <- read_one_row(file.path(model_dir, "model_payload_manifest.csv"))
    checks <- c(
      identical(as.character(metadata$key), key),
      identical(as.character(metadata$axis), "Tag overdispersion"),
      as.integer(metadata$diagnostic_source_job) == 21641L,
      identical(as.character(metadata$diagnostic_source_commit), diagnostic_source_commit),
      identical(as.character(model_audit$status), "passed"),
      isTRUE(all.equal(as.numeric(model_audit$fixed_steepness), 0.90, tolerance = 5e-9)),
      isTRUE(all.equal(as.numeric(model_audit$tau), tau, tolerance = 5e-9)),
      identical(as.character(tau_audit$status), "passed"),
      identical(as.character(tau_audit$mode), "tau-fixed"),
      isTRUE(all.equal(as.numeric(tau_audit$tau), tau, tolerance = 5e-9)),
      as.integer(tau_audit$estimated_tau_count) == 0L,
      identical(as.character(manifest$schema), "mfclshiny.model_payload_manifest.v1"),
      identical(as.character(manifest$model_label), key),
      isFALSE(as.logical(manifest$hessian_attempted))
    )
    if (!all(checks)) fail("Raw output audit failed for ", key, ".")

    final_file <- file.path(model_dir, "final.par")
    objective <- read_final_value(final_file, "# Objective function value")
    parameters <- as.integer(read_final_value(final_file, "# The number of parameters"))
    mgc <- read_final_value(final_file, "# Maximum magnitude gradient value")
    gradient_mgc <- read_gradient_mgc(file.path(model_dir, "gradient.rpt"), parameters)
    if (!isTRUE(all.equal(objective, as.numeric(manifest$obj_fun), tolerance = 1e-12)) ||
        !isTRUE(all.equal(mgc, as.numeric(manifest$max_grad), tolerance = 1e-12)) ||
        !isTRUE(all.equal(mgc, gradient_mgc, tolerance = 2e-6))) {
      fail("Objective or gradient cross-check failed for ", key, ".")
    }

    new_fit_rows[[key]] <- data.frame(
      key = key,
      fixed_tau = tau,
      objective_function = objective,
      maximum_gradient_component = mgc,
      active_parameters = parameters,
      hessian_evaluated = FALSE,
      positive_definite_hessian = NA,
      hessian_status = "not evaluated",
      convergence_status = ifelse(
        mgc <= 1e-4,
        "completed; MGC <= 1e-4",
        "completed; MGC above 1e-4"
      ),
      kflow_job = job,
      source = "more_tau_sens Kflow output archive",
      final_par_sha256 = sha256(final_file),
      plot_11_rep_sha256 = sha256(file.path(model_dir, "plot-11.par.rep")),
      stringsAsFactors = FALSE
    )

    provenance_rows[[key]] <- data.frame(
      key = key,
      fixed_tau = tau,
      campaign = "Additional fixed-tau sensitivity",
      kflow_job = job,
      source_commit = more_tau_source_commit,
      archive_file = basename(archive_file),
      archive_status = "verified staged archive",
      archive_sha256 = sha256(archive_file),
      final_par_sha256 = sha256(final_file),
      plot_11_rep_sha256 = sha256(file.path(model_dir, "plot-11.par.rep")),
      gradient_rpt_sha256 = sha256(file.path(model_dir, "gradient.rpt")),
      model_payload_sha256 = sha256(file.path(model_dir, "model_payload.rds")),
      mfcl_executable_sha256 = sha256(file.path(model_dir, "mfclo64")),
      mfclkit_git_sha = mfclkit_git_sha,
      mfclshiny_git_sha = mfclshiny_git_sha,
      diagnostic_source_job = 21641L,
      diagnostic_source_commit = diagnostic_source_commit,
      payload_created_at = as.character(manifest$created_at),
      stringsAsFactors = FALSE
    )
  }

  diagnostic_fit <- data.frame(
    key = "diagnostic",
    fixed_tau = 2,
    objective_function = NA_real_,
    maximum_gradient_component = NA_real_,
    active_parameters = NA_integer_,
    hessian_evaluated = NA,
    positive_definite_hessian = NA,
    hessian_status = "not included in the committed public diagnostic payload",
    convergence_status = "not included in the committed public diagnostic payload",
    kflow_job = 21641L,
    source = "Diagnostic public time series; fit diagnostics unavailable in this payload",
    final_par_sha256 = NA_character_,
    plot_11_rep_sha256 = NA_character_,
    stringsAsFactors = FALSE
  )
  fits <- rbind(old_fits, diagnostic_fit, do.call(rbind, new_fit_rows))
  row.names(fits) <- NULL
  if (!identical(fits$key, all_keys)) fail("Combined fixed-tau diagnostics are out of order.")
  provenance <- do.call(rbind, provenance_rows)
  row.names(provenance) <- NULL

  source_rows <- data.frame(
    role = c(
      "Original sensitivity design", "Additional sensitivity design",
      "Original public time series", "Original public fit diagnostics",
      "Original completed-output audit", "Viewer HTML template",
      "Staged more-tau derived series"
    ),
    file = c(
      old_design_file, new_design_file, main_series_file, main_fits_file,
      main_audit_file, template_file, "derived-timeseries-raw.csv"
    ),
    sha256 = c(
      sha256(old_design_file), sha256(new_design_file), sha256(main_series_file),
      sha256(main_fits_file), sha256(main_audit_file), sha256(template_file),
      sha256(raw_series_file)
    ),
    stringsAsFactors = FALSE
  )

  dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(design, compact_design_file, row.names = FALSE, na = "")
  utils::write.csv(combined_series, compact_series_file, row.names = FALSE, na = "")
  utils::write.csv(fits, compact_fits_file, row.names = FALSE, na = "")
  utils::write.csv(original_provenance, compact_original_provenance_file, row.names = FALSE, na = "")
  utils::write.csv(provenance, compact_provenance_file, row.names = FALSE, na = "")
  utils::write.csv(source_rows, compact_sources_file, row.names = FALSE, na = "")

  checksum_files <- c(
    compact_design_file, compact_series_file, compact_fits_file,
    compact_original_provenance_file, compact_provenance_file, compact_sources_file
  )
  checksum_lines <- vapply(
    checksum_files,
    function(path) paste(sha256(path), basename(path)),
    character(1)
  )
  writeLines(checksum_lines, compact_checksums_file, useBytes = TRUE)
  message("Refreshed committed fixed-tau viewer data from audited raw outputs.")
}

args <- commandArgs(trailingOnly = TRUE)
unknown <- setdiff(args, "--refresh-data")
if (length(unknown)) fail("Unknown argument(s): ", paste(unknown, collapse = ", "))
if ("--refresh-data" %in% args) refresh_compact_data()

required_compact <- c(
  compact_design_file, compact_series_file, compact_fits_file,
  compact_original_provenance_file, compact_provenance_file, compact_sources_file,
  compact_checksums_file, template_file
)
missing_compact <- required_compact[!file.exists(required_compact)]
if (length(missing_compact)) {
  fail("Missing committed viewer input(s): ", paste(missing_compact, collapse = ", "))
}

checksum_lines <- readLines(compact_checksums_file, warn = FALSE)
checksum_parts <- strsplit(checksum_lines, "[[:space:]]+", perl = TRUE)
expected_checksum_files <- basename(c(
  compact_design_file, compact_series_file, compact_fits_file,
  compact_original_provenance_file, compact_provenance_file, compact_sources_file
))
if (length(checksum_parts) != length(expected_checksum_files) ||
    !identical(vapply(checksum_parts, `[[`, character(1), 2L), expected_checksum_files)) {
  fail("Committed fixed-tau checksum manifest has the wrong files or order.")
}
for (parts in checksum_parts) {
  if (length(parts) != 2L || !grepl("^[0-9a-f]{64}$", parts[[1L]]) ||
      !identical(sha256(file.path(data_dir, parts[[2L]])), parts[[1L]])) {
    fail("Committed fixed-tau data checksum mismatch for ", parts[[2L]], ".")
  }
}

design <- read_csv(compact_design_file)
series <- read_csv(compact_series_file)
fits <- read_csv(compact_fits_file)
original_provenance <- read_csv(compact_original_provenance_file)
provenance <- read_csv(compact_provenance_file)
sources <- read_csv(compact_sources_file)
if (!identical(as.character(design$key), all_keys)) fail("Committed viewer design is inconsistent.")
check_series(series, all_keys)
if (!identical(as.character(fits$key), all_keys)) fail("Committed viewer diagnostics are inconsistent.")
if (!identical(as.character(original_provenance$key), old_keys)) {
  fail("Committed original-tau provenance is inconsistent.")
}
if (!identical(as.character(provenance$key), new_keys)) fail("Committed more-tau provenance is inconsistent.")
repository_sources <- sources[sources$file != "derived-timeseries-raw.csv", , drop = FALSE]
if (any(!file.exists(repository_sources$file)) ||
    any(vapply(seq_len(nrow(repository_sources)), function(index) {
      !identical(sha256(repository_sources$file[[index]]), repository_sources$sha256[[index]])
    }, logical(1)))) {
  fail("A repository source no longer matches the recorded viewer provenance.")
}

labels <- stats::setNames(as.character(design$label), design$key)
series$model <- unname(labels[series$key])
if (anyNA(series$model)) fail("A fixed-tau model label is missing.")

metric_specs <- data.frame(
  column = c("depletion", "recruitment", "spawning_potential", "fishing_mortality"),
  metric_key = c("depletion", "recruitment", "spawning_potential", "fishing_mortality"),
  metric_label = c(
    "Dynamic spawning depletion", "Recruitment", "Spawning potential", "Fishing mortality"
  ),
  y_label = c(
    "SB/SB[F=0]", "Recruitment (millions)",
    "Spawning potential (10^3 MT)", "F (year^-1)"
  ),
  stringsAsFactors = FALSE
)
key_records <- do.call(
  rbind,
  lapply(seq_len(nrow(metric_specs)), function(index) {
    spec <- metric_specs[index, , drop = FALSE]
    data.frame(
      model = series$model,
      region = "All",
      year = as.integer(series$year),
      x = as.integer(series$year),
      source = "Value",
      value = round(series[[spec$column]], 9),
      metric_key = spec$metric_key,
      metric_label = spec$metric_label,
      y_label = spec$y_label,
      x_label = "Year",
      stringsAsFactors = FALSE
    )
  })
)

fit_table <- data.frame(
  Model = unname(labels[fits$key]),
  `Fixed tau` = fits$fixed_tau,
  `Objective value` = fits$objective_function,
  MGC = fits$maximum_gradient_component,
  `Active parameters` = fits$active_parameters,
  Status = fits$convergence_status,
  `Kflow job` = fits$kflow_job,
  Source = fits$source,
  check.names = FALSE,
  stringsAsFactors = FALSE
)

all_provenance <- rbind(original_provenance, provenance)
provenance_table <- data.frame(
  Model = unname(labels[all_provenance$key]),
  Campaign = all_provenance$campaign,
  `Fixed tau` = all_provenance$fixed_tau,
  `Kflow job` = all_provenance$kflow_job,
  `Source commit` = all_provenance$source_commit,
  `Archive file` = all_provenance$archive_file,
  `Archive status` = all_provenance$archive_status,
  `Archive SHA-256` = all_provenance$archive_sha256,
  `final.par SHA-256` = all_provenance$final_par_sha256,
  `plot-11.par.rep SHA-256` = all_provenance$plot_11_rep_sha256,
  `mfclkit commit` = all_provenance$mfclkit_git_sha,
  `mfclshiny commit` = all_provenance$mfclshiny_git_sha,
  check.names = FALSE,
  stringsAsFactors = FALSE
)

colours <- grDevices::hcl.colors(nrow(design), palette = "Dynamic")
colours[design$key == "diagnostic"] <- "#C62828"
payload <- list(
  title = "BET 2026 exploratory fixed-tau sensitivity",
  generated_at = paste0(source_date, " (deterministic source date)"),
  note = paste0(
    "Exploratory fixed-tau sensitivity results only; this is not a stock-assessment update. ",
    "The Diagnostic model fixes tau at 2."
  ),
  models = data.frame(
    key = design$key,
    label = design$label,
    color = colours,
    stringsAsFactors = FALSE
  ),
  metrics = list(
    list(
      key = "key_quantities",
      label = "Key quantities",
      kind = "key_quantities",
      records = key_records
    ),
    list(
      key = "model_summary",
      label = "Fit diagnostics",
      kind = "table",
      records = fit_table,
      columns = names(fit_table)
    ),
    list(
      key = "output_provenance",
      label = "Fixed-tau output provenance",
      kind = "table",
      records = provenance_table,
      columns = names(provenance_table)
    )
  ),
  regions = "All"
)

viewer_json <- jsonlite::toJSON(
  payload,
  auto_unbox = TRUE,
  dataframe = "columns",
  null = "null",
  digits = 15,
  na = "null",
  pretty = FALSE
)
viewer_json <- gsub("</", "<\\/", viewer_json, fixed = TRUE)

template <- paste(readLines(template_file, warn = FALSE), collapse = "\n")
markers <- gregexpr("__VIEWER_DATA__", template, fixed = TRUE)[[1L]]
if (sum(markers >= 0L) != 1L) fail("Viewer template must contain exactly one payload marker.")
html <- sub("__VIEWER_DATA__", viewer_json, template, fixed = TRUE)
html <- sub(
  "<title>BET 2026 sensitivity model results</title>",
  "<title>BET 2026 exploratory fixed-tau sensitivity</title>",
  html,
  fixed = TRUE
)
html <- sub(
  "<h1>BET 2026 sensitivity model results</h1>",
  paste0(
    "<h1>BET 2026 exploratory fixed-tau sensitivity</h1>",
    "<p style=\"color:#536b7b;font-size:12px;font-weight:750;margin:6px 0 0;max-width:760px\">",
    "Exploratory fixed-tau sensitivity results only; this is not a stock-assessment update.",
    "</p>"
  ),
  html,
  fixed = TRUE
)

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
writeLines(html, output_file, useBytes = TRUE)
message(
  "Built ", output_file, " with ", nrow(design), " fixed-tau models and ",
  nrow(key_records), " plotted values."
)
