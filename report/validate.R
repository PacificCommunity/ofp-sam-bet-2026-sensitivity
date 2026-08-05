options(stringsAsFactors = FALSE)

payload_file <- "data/sensitivity/sensitivity-timeseries.rds"
series_file <- "data/sensitivity/sensitivity-timeseries.csv"
design_file <- "data/sensitivity/sensitivity-design.csv"
audit_file <- "data/sensitivity/completed-output-audit.csv"
required_files <- c(payload_file, series_file, design_file, audit_file)
if (any(!file.exists(required_files))) {
  stop("The public sensitivity report payload is incomplete.", call. = FALSE)
}

payload <- readRDS(payload_file)
csv_series <- utils::read.csv(series_file, check.names = FALSE)
design <- utils::read.csv(design_file, check.names = FALSE)
audit <- utils::read.csv(audit_file, check.names = FALSE)

required_columns <- c(
  "year", "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality", "key", "axis", "label",
  "reference", "alternative", "is_diagnostic", "model_order"
)
if (!all(required_columns %in% names(payload))) stop("The time-series payload schema is incomplete.", call. = FALSE)
if (!isTRUE(all.equal(payload, csv_series, tolerance = 1e-12, check.attributes = FALSE))) {
  stop("The RDS and CSV time-series payloads differ.", call. = FALSE)
}
if (nrow(design) != 17L || length(unique(design$axis)) != 8L) {
  stop("Expected 17 one-at-a-time fits across eight sensitivity axes.", call. = FALSE)
}
expected_counts <- c(
  "Steepness" = 3L,
  "Tag overdispersion" = 5L,
  "Tag mixing periods (KS D-statistic cutoff)" = 2L,
  "Conditional age-at-length" = 2L,
  "Natural mortality" = 2L,
  "Effort creep" = 1L,
  "Regional scaling" = 1L,
  "Pre-mixing tag reporting" = 1L
)
observed_counts <- table(factor(design$axis, levels = names(expected_counts)))
if (!identical(as.integer(observed_counts), unname(expected_counts))) {
  stop("The sensitivity-axis membership is incorrect.", call. = FALSE)
}

keys <- unique(payload$key)
if (!identical(sort(setdiff(keys, "diagnostic")), sort(design$key))) {
  stop("The public payload does not match the sensitivity design.", call. = FALSE)
}
if (nrow(payload) != 18L * 73L) stop("Expected 73 annual values for 18 model configurations.", call. = FALSE)
if (sum(payload$is_diagnostic) != 73L) stop("Expected one 73-year Diagnostic-model series.", call. = FALSE)

numeric_columns <- c(
  "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality"
)
for (key in keys) {
  value <- payload[payload$key == key, , drop = FALSE]
  if (!identical(as.integer(value$year), 1952:2024)) {
    stop("Incomplete annual coverage for ", key, ".", call. = FALSE)
  }
  if (any(!is.finite(as.matrix(value[, numeric_columns, drop = FALSE])))) {
    stop("Non-finite derived quantities for ", key, ".", call. = FALSE)
  }
  if (any(as.matrix(value[, numeric_columns, drop = FALSE]) < 0)) {
    stop("Negative derived quantities for ", key, ".", call. = FALSE)
  }
  if (!isTRUE(all.equal(
    value$depletion,
    value$spawning_potential / value$spawning_potential_nofish,
    tolerance = 5e-7
  ))) {
    stop("Depletion reconstruction failed for ", key, ".", call. = FALSE)
  }
}

if (!identical(sort(audit$key), sort(design$key)) || any(audit$audit_status != "passed")) {
  stop("The completed-output audit does not cover all 17 sensitivities.", call. = FALSE)
}
if (any(audit$DM_Nmax != 25L) || any(audit$DM_concentration != 7L)) {
  stop("Diagnostic-model DM controls changed unexpectedly.", call. = FALSE)
}
if (any(audit$selectivity != "Diagnostic (F10 and F33 weak non-decreasing)")) {
  stop("Diagnostic-model selectivity changed unexpectedly.", call. = FALSE)
}
if (any(nchar(audit$final_par_sha256) != 64L) || any(nchar(audit$final_rep_sha256) != 64L)) {
  stop("The completed-output checksum audit is incomplete.", call. = FALSE)
}

collect_text <- function(value) {
  output <- character()
  visit <- function(item) {
    if (is.character(item)) output <<- c(output, item)
    if (is.factor(item)) output <<- c(output, levels(item))
    if (is.list(item)) {
      output <<- c(output, names(item))
      for (child in item) visit(child)
    }
  }
  visit(value)
  output
}
public_text <- c(
  collect_text(payload),
  unlist(design, use.names = FALSE),
  unlist(audit, use.names = FALSE)
)
forbidden <- c(
  "internal absolute path" = "/(home|var/lib/condor|kflow)/",
  "credential-like text" = "(ghp_|github_pat_|token[=:]|password[=:]|secret[=:])",
  "internal host" = "corp[.]spc[.]int"
)
for (label in names(forbidden)) {
  if (any(grepl(forbidden[[label]], public_text, ignore.case = TRUE, perl = TRUE))) {
    stop("Public payload contains ", label, ".", call. = FALSE)
  }
}

cat(
  "Validated public sensitivity payload: 17 one-at-a-time fits, eight axes, ",
  "73 annual values per configuration, and completed-output audits passed.\n",
  sep = ""
)
