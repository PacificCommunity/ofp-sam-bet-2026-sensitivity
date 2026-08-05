options(stringsAsFactors = FALSE)

derived_file <- Sys.getenv("SENSITIVITY_DERIVED_SERIES", "")
diagnostic_file <- Sys.getenv("DIAGNOSTIC_DERIVED_SERIES", "")
raw_root <- Sys.getenv("SENSITIVITY_RAW_CACHE", "")

required_inputs <- c(
  SENSITIVITY_DERIVED_SERIES = derived_file,
  DIAGNOSTIC_DERIVED_SERIES = diagnostic_file,
  SENSITIVITY_RAW_CACHE = raw_root
)
missing_inputs <- names(required_inputs)[!nzchar(required_inputs) | !file.exists(required_inputs)]
if (length(missing_inputs)) {
  stop(
    "Set the completed-output inputs before rebuilding public report data: ",
    paste(missing_inputs, collapse = ", "),
    call. = FALSE
  )
}

design <- utils::read.csv("sensitivities.csv", check.names = FALSE)
series <- utils::read.csv(derived_file, check.names = FALSE)
diagnostic_source <- utils::read.csv(diagnostic_file, check.names = FALSE)

required_design <- c("key", "axis", "label", "reference", "alternative", "scientific_change")
required_series <- c(
  "year", "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality", "model_token"
)
if (!all(required_design %in% names(design))) stop("The sensitivity design is incomplete.", call. = FALSE)
if (!all(required_series %in% names(series))) stop("The sensitivity time series are incomplete.", call. = FALSE)
if (!all(required_series %in% names(diagnostic_source))) stop("The Diagnostic-model time series are incomplete.", call. = FALSE)
if (!identical(sort(unique(series$model_token)), sort(design$key))) {
  stop("Completed sensitivity outputs do not match sensitivities.csv.", call. = FALSE)
}

sha256 <- function(path) {
  value <- system2("sha256sum", path, stdout = TRUE)
  sub("[[:space:]].*$", "", value[[1L]])
}

read_one_row <- function(path) {
  value <- utils::read.csv(path, check.names = FALSE)
  if (nrow(value) != 1L) stop("Expected one audit row in ", path, call. = FALSE)
  value
}

audit_rows <- lapply(seq_len(nrow(design)), function(index) {
  row <- design[index, , drop = FALSE]
  folder <- file.path(raw_root, row$key)
  required <- file.path(
    folder,
    c(
      "final.par", "plot-11.par.rep", "model-input-audit.csv",
      "tag-tau-audit.csv", "selectivity-audit.csv", "sensitivity-metadata.csv"
    )
  )
  if (any(!file.exists(required))) {
    stop("The completed-output audit is incomplete for ", row$key, ".", call. = FALSE)
  }
  model_audit <- read_one_row(file.path(folder, "model-input-audit.csv"))
  tau_audit <- read_one_row(file.path(folder, "tag-tau-audit.csv"))
  selectivity_audit <- read_one_row(file.path(folder, "selectivity-audit.csv"))
  metadata <- read_one_row(file.path(folder, "sensitivity-metadata.csv"))

  expected_h <- if (identical(row$axis, "Steepness")) as.numeric(row$alternative) else 0.90
  expected_tau <- if (identical(row$axis, "Tag overdispersion")) as.numeric(row$alternative) else 2.0
  checks <- c(
    identical(as.character(metadata$key), row$key),
    identical(as.character(metadata$axis), row$axis),
    identical(as.character(metadata$scientific_change), row$scientific_change),
    identical(as.character(model_audit$status), "passed"),
    identical(as.character(model_audit$model_id), "Diagnostic"),
    identical(as.character(model_audit$initialization), "ordinary-makepar-no-seed"),
    isTRUE(all.equal(as.numeric(model_audit$fixed_steepness), expected_h, tolerance = 5e-9)),
    isTRUE(all.equal(as.numeric(model_audit$tau), expected_tau, tolerance = 5e-9)),
    identical(as.character(tau_audit$status), "passed"),
    identical(as.character(tau_audit$tag_likelihood), "direct-negative-binomial"),
    as.integer(tau_audit$parest305) == 1L,
    as.integer(tau_audit$estimated_tau_count) == 0L,
    as.integer(tau_audit$active_tau_fisheries) == 0L,
    as.integer(tau_audit$grouped_tau_fisheries) == 0L,
    as.integer(tau_audit$dm_nmax) == 25L,
    as.integer(tau_audit$dm_concentration) == 7L,
    isTRUE(all.equal(as.numeric(tau_audit$tau), expected_tau, tolerance = 5e-9)),
    identical(as.character(selectivity_audit$status), "passed"),
    identical(as.character(selectivity_audit$selectivity_model), "Diagnostic"),
    as.integer(selectivity_audit$selectivity_groups) == 33L,
    as.integer(selectivity_audit$weak_penalty_flags) == 2L
  )
  if (!all(checks)) stop("Completed-output audit failed for ", row$key, ".", call. = FALSE)

  data.frame(
    key = row$key,
    axis = row$axis,
    fixed_steepness = expected_h,
    fixed_tau = expected_tau,
    selectivity = "Diagnostic (F10 and F33 weak non-decreasing)",
    DM_Nmax = 25L,
    DM_concentration = 7L,
    initialization = "ordinary makepar; no seed or checkpoint",
    audit_status = "passed",
    final_par_sha256 = sha256(file.path(folder, "final.par")),
    final_rep_sha256 = sha256(file.path(folder, "plot-11.par.rep")),
    stringsAsFactors = FALSE
  )
})
audit <- do.call(rbind, audit_rows)

display_label <- function(key, label) {
  if (startsWith(key, "steepness-")) return(sub("Steepness ", "h = ", label, fixed = TRUE))
  if (startsWith(key, "tau-")) return(sub("Tau ", "τ = ", label, fixed = TRUE))
  if (startsWith(key, "tag-mixing-k-")) return(sub("Tag mixing periods - ", "", label, fixed = TRUE))
  if (startsWith(key, "lorenzen-m-scalar-")) return(sub("Lorenzen M scalar ", "M scalar = ", label, fixed = TRUE))
  if (identical(key, "effort-creep-high")) return("2.5% / 1.25%")
  if (identical(key, "regional-scaling-whole-period")) return("Whole-period scaling")
  if (identical(key, "pre-mixing-tag-reporting-inclusion")) return("Reporting rates applied during mixing")
  sub("CAAL ", "", label, fixed = TRUE)
}

keep_columns <- c(
  "year", "depletion", "spawning_potential", "spawning_potential_nofish",
  "recruitment", "fishing_mortality"
)
series_rows <- lapply(seq_len(nrow(design)), function(index) {
  row <- design[index, , drop = FALSE]
  value <- series[series$model_token == row$key, keep_columns, drop = FALSE]
  value$key <- row$key
  value$axis <- row$axis
  value$label <- display_label(row$key, row$label)
  value$reference <- row$reference
  value$alternative <- row$alternative
  value$is_diagnostic <- FALSE
  value$model_order <- index
  value
})

diagnostic <- diagnostic_source[
  diagnostic_source$model_token == "22-Diagnostic",
  keep_columns,
  drop = FALSE
]
if (nrow(diagnostic) != 73L) stop("Expected 73 annual Diagnostic-model rows.", call. = FALSE)
diagnostic$key <- "diagnostic"
diagnostic$axis <- "Diagnostic reference"
diagnostic$label <- "Diagnostic model"
diagnostic$reference <- ""
diagnostic$alternative <- ""
diagnostic$is_diagnostic <- TRUE
diagnostic$model_order <- 0L

public_series <- rbind(diagnostic, do.call(rbind, series_rows))
public_series <- public_series[order(public_series$model_order, public_series$year), , drop = FALSE]
row.names(public_series) <- NULL

for (key in unique(public_series$key)) {
  value <- public_series[public_series$key == key, , drop = FALSE]
  if (!identical(as.integer(value$year), 1952:2024)) {
    stop("Annual coverage is incomplete for ", key, ".", call. = FALSE)
  }
  numeric_columns <- c(
    "depletion", "spawning_potential", "spawning_potential_nofish",
    "recruitment", "fishing_mortality"
  )
  if (any(!is.finite(as.matrix(value[, numeric_columns, drop = FALSE])))) {
    stop("Non-finite derived quantities were found for ", key, ".", call. = FALSE)
  }
  reconstructed <- value$spawning_potential / value$spawning_potential_nofish
  if (!isTRUE(all.equal(value$depletion, reconstructed, tolerance = 5e-7))) {
    stop("Depletion does not match SB/SB(F=0) for ", key, ".", call. = FALSE)
  }
}

dir.create("data/sensitivity", recursive = TRUE, showWarnings = FALSE)
saveRDS(public_series, "data/sensitivity/sensitivity-timeseries.rds", compress = "xz")
utils::write.csv(public_series, "data/sensitivity/sensitivity-timeseries.csv", row.names = FALSE)
utils::write.csv(design, "data/sensitivity/sensitivity-design.csv", row.names = FALSE)
utils::write.csv(audit, "data/sensitivity/completed-output-audit.csv", row.names = FALSE)

cat(
  "Built public sensitivity payload: ", nrow(public_series), " annual rows, ",
  nrow(design), " alternatives, ", length(unique(design$axis)), " axes.\n",
  sep = ""
)
