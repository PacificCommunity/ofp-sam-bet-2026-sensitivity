#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
registry <- read.csv(file.path(repo, "sensitivities.csv"), stringsAsFactors = FALSE, check.names = FALSE)
base <- file.path(repo, "model")
test_root <- tempfile("bet-sensitivity-validation-")
dir.create(test_root)
on.exit(unlink(test_root, recursive = TRUE), add = TRUE)

fail <- function(...) stop(..., call. = FALSE)
fields <- function(x) strsplit(trimws(x), "[[:space:]]+")[[1L]]
read_file <- function(path) readLines(path, warn = FALSE)
hash <- function(path) strsplit(system2("sha256sum", path, stdout = TRUE), "[[:space:]]+")[[1L]][1L]

rows_after <- function(lines, marker, n, occurrence = 1L) {
  hit <- grep(marker, lines)
  if (length(hit) < occurrence) fail("Missing marker: ", marker)
  i <- hit[[occurrence]] + 1L
  ans <- integer()
  while (i <= length(lines) && length(ans) < n) {
    if (nzchar(trimws(lines[[i]])) && !grepl("^[[:space:]]*#", lines[[i]])) ans <- c(ans, i)
    i <- i + 1L
  }
  if (length(ans) != n) fail("Incomplete block after ", marker)
  ans
}

value_after <- function(path, marker, row, column) {
  x <- read_file(path)
  fields(x[[rows_after(x, marker, row)[[row]]]])[[column]]
}

read_config <- function(path) {
  lines <- read_file(path)
  lines <- lines[grepl("^[A-Z][A-Z0-9_]*=", lines)]
  keys <- sub("=.*$", "", lines)
  values <- sub("^[^=]*=", "", lines)
  stats::setNames(values, keys)
}

tag_matrix <- function(path) {
  x <- read_file(path)
  rows <- rows_after(x, "^# tag flags[[:space:]]*$", 98L)
  m <- do.call(rbind, lapply(rows, function(i) fields(x[[i]])))
  storage.mode(m) <- "numeric"
  m
}

effort_records <- function(lines) {
  answer <- list()
  for (i in seq_along(lines)) {
    f <- fields(lines[[i]])
    if (length(f) < 7L || any(!grepl("^[0-9]+$", f[1:4]))) next
    fishery <- suppressWarnings(as.integer(f[[4L]]))
    if (!is.na(fishery) && fishery >= 29L && fishery <= 33L) {
      key <- paste(f[1:4], collapse = ":")
      if (!is.null(answer[[key]])) fail("Duplicate effort key: ", key)
      answer[[key]] <- list(line = i, fields = f)
    }
  }
  answer
}

assert_only_rows <- function(base_path, staged_path, allowed_rows, token_rule = NULL) {
  a <- read_file(base_path); b <- read_file(staged_path)
  if (length(a) != length(b)) fail("Line count changed in ", staged_path)
  changed <- which(a != b)
  if (length(setdiff(changed, allowed_rows))) fail("Unexpected line changed in ", staged_path)
  if (!is.null(token_rule)) for (i in changed) token_rule(fields(a[[i]]), fields(b[[i]]), i)
}

assert_marker_fields_only <- function(base_path, staged_path, marker, row_number, allowed_fields) {
  original <- read_file(base_path)
  actual <- read_file(staged_path)
  original_row <- rows_after(original, marker, row_number)[[row_number]]
  actual_row <- rows_after(actual, marker, row_number)[[row_number]]
  if (original_row != actual_row) fail("Marker row moved in ", staged_path)
  assert_only_rows(
    base_path, staged_path, original_row,
    function(before, after, line) {
      if (length(before) != length(after) || !identical(before[-allowed_fields], after[-allowed_fields])) {
        fail("Unexpected field changed at line ", line, " in ", staged_path)
      }
    }
  )
}

assert_tag_column_only <- function(base_path, staged_path, column) {
  original <- read_file(base_path)
  actual <- read_file(staged_path)
  original_rows <- rows_after(original, "^# tag flags[[:space:]]*$", 98L)
  actual_rows <- rows_after(actual, "^# tag flags[[:space:]]*$", 98L)
  if (!identical(original_rows, actual_rows)) fail("Tag flag block moved in ", staged_path)
  assert_only_rows(
    base_path, staged_path, original_rows,
    function(before, after, line) {
      if (length(before) != 10L || length(after) != 10L || !identical(before[-column], after[-column])) {
        fail("Unexpected tag flag field changed at line ", line, " in ", staged_path)
      }
    }
  )
}

assert_config_changes <- function(staged_path, allowed_keys) {
  original <- read_file(file.path(base, "model-inputs/Diagnostic.conf"))
  allowed <- unique(unlist(lapply(allowed_keys, function(key) grep(paste0("^", key, "="), original))))
  if (length(allowed) != length(allowed_keys)) fail("Could not identify every permitted config key.")
  assert_only_rows(file.path(base, "model-inputs/Diagnostic.conf"), staged_path, allowed)
}

assert_doitall_changes <- function(case_key, staged_path) {
  original_path <- file.path(base, "doitall.sh")
  original <- read_file(original_path)
  allowed <- integer()
  if (case_key == "regional-scaling-whole-period") {
    allowed <- c(
      grep("^[[:space:]]*1[[:space:]]+79[[:space:]]+240([[:space:]]|$)", original),
      grep("^[[:space:]]*1[[:space:]]+80[[:space:]]+220([[:space:]]|$)", original)
    )
  }
  assert_only_rows(original_path, staged_path, unique(allowed))
}

assert_published_folder <- function(case_key, staged) {
  published <- file.path(repo, "models", case_key)
  if (!dir.exists(published)) fail("Missing materialized model folder: models/", case_key)
  expected_files <- sort(setdiff(
    substring(list.files(staged, recursive = TRUE, full.names = TRUE), nchar(staged) + 2L),
    "mfclo64"
  ))
  actual_files <- sort(substring(
    list.files(published, recursive = TRUE, full.names = TRUE), nchar(published) + 2L
  ))
  if (!identical(expected_files, actual_files)) fail("Published file set differs for ", case_key)
  comparable <- setdiff(expected_files, "INPUTS.sha256")
  for (relative in comparable) {
    if (hash(file.path(staged, relative)) != hash(file.path(published, relative))) {
      fail("Published input differs from validated generator output: ", case_key, "/", relative)
    }
  }
  previous_directory <- getwd()
  setwd(published)
  status <- system2("sha256sum", c("-c", "INPUTS.sha256"), stdout = FALSE, stderr = FALSE)
  setwd(previous_directory)
  if (!identical(status, 0L)) fail("Published INPUTS.sha256 failed for ", case_key)
}

manifest_files <- c(read.table(file.path(base, "MANIFEST.sha256"), stringsAsFactors = FALSE)[[2L]],
                    "MANIFEST.sha256")
config_path <- file.path(base, "model-inputs/Diagnostic.conf")
base_config <- read_config(config_path)
required_config <- c("MODEL_ID", "STEEPNESS", "TAU", "TAU_FISH_PARS4", "M_LOG_INTERCEPT",
                     "SELECTIVITY_MODEL", "SELECTIVITY_INPUT")
if (!all(required_config %in% names(base_config))) fail("Diagnostic model config is incomplete.")
if (base_config[["MODEL_ID"]] != "Diagnostic" || base_config[["SELECTIVITY_MODEL"]] != "Diagnostic") {
  fail("Diagnostic model identity or selectivity changed.")
}
if (base_config[["STEEPNESS"]] != "0.90" || base_config[["TAU"]] != "2.0" ||
    base_config[["TAU_FISH_PARS4"]] != "0") fail("Diagnostic h/tau reference is not h=0.90 and tau=2.")

reference_sv <- as.numeric(value_after(file.path(base, "bet.ini"), "^# sv[(]29[)]", 1L, 1L))
if (!isTRUE(all.equal(reference_sv, 0.9))) fail("Diagnostic steepness is not 0.90.")
base_tags <- tag_matrix(file.path(base, "bet.ini"))
mix02_tags <- tag_matrix(file.path(repo, "sources/mixing/bet.2026.mix-0.2.ini"))
if (!identical(base_tags[, 1L], mix02_tags[, 1L])) fail("Diagnostic tag mixing flags do not equal K=0.2 source.")
if (any(base_tags[, 2L] != 1)) fail("Diagnostic reporting-exclusion flag is not 1.")

base_m <- as.numeric(value_after(file.path(base, "bet.ini"), "^# age_pars$", 5L, 1L))
if (abs(base_m - (-2.54930339768360)) > 1e-12 ||
    abs(as.numeric(base_config[["M_LOG_INTERCEPT"]]) - base_m) > 1e-12) {
  fail("Unexpected Diagnostic Lorenzen M scalar.")
}
if (hash(file.path(base, "bet.age_length")) != hash(file.path(repo, "sources/age-length/bet.2026.sub.basin.0.75.age_length"))) {
  fail("Diagnostic CAAL input is not the authoritative 0.75 sub-basin file.")
}

base_reg <- read_file(file.path(base, "bet.reg_scaling"))
full_reg <- read_file(file.path(repo, "sources/regional-scaling/bet.reg_scaling.full"))
if (length(base_reg) != 20L || any(vapply(strsplit(trimws(base_reg), "[[:space:]]+"), length, integer(1)) != 5L)) {
  fail("Diagnostic regional-scaling input is not a headerless 20 by 5 matrix.")
}
if (!identical(trimws(base_reg), trimws(full_reg[53:72]))) fail("Diagnostic five-year scaling window does not match periods 53-72.")

selectivity <- read.csv(file.path(base, "selectivity-models/Diagnostic.csv"), stringsAsFactors = FALSE)
if (nrow(selectivity) != 33L || length(unique(selectivity$flag24)) != 33L ||
    !identical(which(selectivity$flag16 == 1 & selectivity$flag56 == 10000), c(10L, 33L))) {
  fail("Diagnostic selectivity is not 33 independent groups with weak F10/F33 penalties.")
}
doitall_text <- paste(read_file(file.path(base, "doitall.sh")), collapse = "\n")
if (grepl("seed-23|seed23|checkpoints/", doitall_text, ignore.case = TRUE) ||
    !grepl("1 305 1", doitall_text, fixed = TRUE) || !grepl("-999 43 0", doitall_text, fixed = TRUE)) {
  fail("Diagnostic doitall is not the ordinary-makepar direct fixed-tau recipe.")
}

allowed_changes <- list(
  "steepness-0.65" = c("bet.ini", "model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "steepness-0.80" = c("bet.ini", "model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "steepness-0.95" = c("bet.ini", "model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-1.006738" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-1.2" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-1.4" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-1.6" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-1.8" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-3" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-5" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tau-7" = c("model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "tag-mixing-k-0.1" = c("bet.ini", "MANIFEST.sha256"),
  "tag-mixing-k-0.3" = c("bet.ini", "MANIFEST.sha256"),
  "caal-0.5-sub-basin" = c("bet.age_length", "MANIFEST.sha256"),
  "caal-1.0-sub-basin" = c("bet.age_length", "MANIFEST.sha256"),
  "lorenzen-m-scalar-0.062" = c("bet.ini", "model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "lorenzen-m-scalar-0.1" = c("bet.ini", "model-inputs/Diagnostic.conf", "MANIFEST.sha256"),
  "effort-creep-high" = c("bet.frq", "MANIFEST.sha256"),
  "regional-scaling-whole-period" = c("bet.reg_scaling", "doitall.sh", "MANIFEST.sha256"),
  "pre-mixing-tag-reporting-inclusion" = c("bet.ini", "MANIFEST.sha256")
)
if (!setequal(names(allowed_changes), registry$key)) fail("Sensitivity registry and validation contract differ.")

tau_values <- c(
  "tau-1.006738" = 1 + exp(-5), "tau-1.2" = 1.2, "tau-1.4" = 1.4,
  "tau-1.6" = 1.6, "tau-1.8" = 1.8, "tau-3" = 3, "tau-5" = 5,
  "tau-7" = 7
)
tau_pars <- c(
  "tau-1.006738" = -5, "tau-1.2" = log(0.2), "tau-1.4" = log(0.4),
  "tau-1.6" = log(0.6), "tau-1.8" = log(0.8), "tau-3" = log(2),
  "tau-5" = log(4), "tau-7" = log(6)
)

audit <- list()
for (case_key in registry$key) {
  staged <- file.path(test_root, case_key)
  status <- system2("Rscript", c(file.path(repo, "scripts/prepare-sensitivity.R"), case_key, staged),
                    stdout = FALSE, stderr = FALSE)
  if (!identical(status, 0L)) fail("Preparation failed for ", case_key)

  changed <- manifest_files[vapply(manifest_files, function(f) hash(file.path(base, f)) != hash(file.path(staged, f)), logical(1))]
  expected <- sort(unique(allowed_changes[[case_key]]))
  if (!identical(sort(changed), expected)) {
    fail(case_key, " changed wrong files. Observed: ", paste(sort(changed), collapse = ", "),
         "; expected: ", paste(expected, collapse = ", "))
  }

  staged_config <- read_config(file.path(staged, "model-inputs/Diagnostic.conf"))
  if (grepl("^steepness", case_key)) {
    expected_value <- c("steepness-0.65" = 0.65, "steepness-0.80" = 0.80,
                        "steepness-0.95" = 0.95)[[case_key]]
    observed <- as.numeric(value_after(file.path(staged, "bet.ini"), "^# sv[(]29[)]", 1L, 1L))
    if (observed != expected_value || as.numeric(staged_config[["STEEPNESS"]]) != expected_value) {
      fail("Steepness did not persist in the committed INI and model config for ", case_key)
    }
    assert_marker_fields_only(file.path(base, "bet.ini"), file.path(staged, "bet.ini"),
                              "^# sv[(]29[)]", 1L, 1L)
    assert_config_changes(file.path(staged, "model-inputs/Diagnostic.conf"), "STEEPNESS")
  } else if (grepl("^tau-", case_key)) {
    observed_tau <- as.numeric(staged_config[["TAU"]])
    observed_par <- as.numeric(staged_config[["TAU_FISH_PARS4"]])
    if (abs(observed_tau - tau_values[[case_key]]) > 5e-9 ||
        abs(observed_par - tau_pars[[case_key]]) > 5e-13 ||
        abs(1 + exp(observed_par) - observed_tau) > 5e-9 || observed_par < -5) {
      fail("Direct fixed-tau values are wrong for ", case_key)
    }
    assert_config_changes(file.path(staged, "model-inputs/Diagnostic.conf"),
                          c("TAU", "TAU_FISH_PARS4"))
  } else if (grepl("^tag-mixing-k", case_key)) {
    mix <- if (case_key == "tag-mixing-k-0.1") "0.1" else "0.3"
    source_tags <- tag_matrix(file.path(repo, "sources/mixing", paste0("bet.2026.mix-", mix, ".ini")))
    actual <- tag_matrix(file.path(staged, "bet.ini")); original <- tag_matrix(file.path(base, "bet.ini"))
    if (!identical(actual[, 1L], source_tags[, 1L]) || !identical(actual[, -1L], original[, -1L])) {
      fail("KS D-statistic cutoff case changed more than tag_flags column 1.")
    }
    assert_tag_column_only(file.path(base, "bet.ini"), file.path(staged, "bet.ini"), 1L)
  } else if (grepl("^caal", case_key)) {
    source <- read_file(file.path(repo, "sources/age-length/bet.2026.sub.basin.1.age_length"))
    source_reference <- read_file(file.path(repo, "sources/age-length/bet.2026.sub.basin.0.75.age_length"))
    actual <- read_file(file.path(staged, "bet.age_length"))
    source_row <- rows_after(source, "^# effective sample size$", 1L)[[1L]]
    reference_row <- rows_after(source_reference, "^# effective sample size$", 1L)[[1L]]
    if (source_row != reference_row || !identical(source[-source_row], source_reference[-reference_row])) {
      fail("Authoritative CAAL 0.75 and 1.0 files differ outside the ESS row.")
    }
    if (case_key == "caal-1.0-sub-basin") {
      if (!identical(source, actual)) fail("CAAL 1.0 is not an exact source copy.")
    } else {
      if (!identical(source[-source_row], actual[-source_row])) fail("CAAL 0.5 changed records outside the ESS row.")
      if (max(abs(as.numeric(fields(actual[[source_row]])) - 0.5 * as.numeric(fields(source[[source_row]])))) > 1e-12) {
        fail("CAAL 0.5 ESS values are not exactly half of sub-basin 1.0.")
      }
    }
  } else if (grepl("^lorenzen-m-scalar", case_key)) {
    expected_value <- log(if (case_key == "lorenzen-m-scalar-0.062") 0.062 else 0.1)
    observed <- as.numeric(value_after(file.path(staged, "bet.ini"), "^# age_pars[[:space:]]*$", 5L, 1L))
    second <- as.numeric(value_after(file.path(staged, "bet.ini"), "^# age_pars[[:space:]]*$", 5L, 2L))
    if (abs(observed - expected_value) > 1e-12 || second != -1 ||
        abs(as.numeric(staged_config[["M_LOG_INTERCEPT"]]) - expected_value) > 1e-12) {
      fail("Lorenzen M input/config is wrong for ", case_key)
    }
    assert_marker_fields_only(file.path(base, "bet.ini"), file.path(staged, "bet.ini"),
                              "^# age_pars[[:space:]]*$", 5L, 1L)
    assert_config_changes(file.path(staged, "model-inputs/Diagnostic.conf"), "M_LOG_INTERCEPT")
  } else if (case_key == "effort-creep-high") {
    original <- read_file(file.path(base, "bet.frq")); actual <- read_file(file.path(staged, "bet.frq"))
    source <- read_file(file.path(repo, "sources/effort-creep/bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq"))
    if (length(original) != length(actual)) fail("FRQ line count changed.")
    original_records <- effort_records(original); actual_records <- effort_records(actual); source_records <- effort_records(source)
    if (length(original_records) != 1458L || !setequal(names(original_records), names(source_records)) ||
        !setequal(names(original_records), names(actual_records))) fail("F29-F33 effort keys are incomplete.")
    for (key in names(original_records)) {
      before <- original_records[[key]]$fields; after <- actual_records[[key]]$fields; authoritative <- source_records[[key]]$fields
      if (!identical(after[[6L]], authoritative[[6L]]) || !identical(before[-6L], after[-6L])) {
        fail("High effort input is not an exact field-6-only replacement at ", key)
      }
    }
    changed_lines <- which(original != actual)
    if (length(changed_lines) != 1440L) fail("Expected 1440 high-creep effort values to differ; observed ", length(changed_lines))
  } else if (case_key == "regional-scaling-whole-period") {
    actual <- read_file(file.path(staged, "bet.reg_scaling"))
    if (length(actual) != 290L || !identical(trimws(actual), trimws(full_reg[3:292]))) {
      fail("Whole-period regional scaling is not the headerless source rows 3-292.")
    }
    d <- read_file(file.path(staged, "doitall.sh"))
    if (length(grep("^[[:space:]]*1[[:space:]]+79[[:space:]]+290([[:space:]]|$)", d)) != 1L ||
        length(grep("^[[:space:]]*1[[:space:]]+80[[:space:]]+0([[:space:]]|$)", d)) != 1L) {
      fail("Whole-period flags 79/80 were not applied to probe and fit.")
    }
  } else if (case_key == "pre-mixing-tag-reporting-inclusion") {
    actual <- tag_matrix(file.path(staged, "bet.ini")); original <- tag_matrix(file.path(base, "bet.ini"))
    if (any(actual[, 2L] != 0) || !identical(actual[, -2L], original[, -2L])) {
      fail("Reporting-rate case changed more than tag_flags column 2.")
    }
    assert_tag_column_only(file.path(base, "bet.ini"), file.path(staged, "bet.ini"), 2L)
  }

  if (!grepl("^steepness|^tau-|^lorenzen", case_key) && !identical(staged_config, base_config)) {
    fail("Unrelated model config changed for ", case_key)
  }
  assert_doitall_changes(case_key, file.path(staged, "doitall.sh"))

  previous_directory <- getwd()
  setwd(staged)
  manifest_status <- system2("sha256sum", c("-c", "MANIFEST.sha256"), stdout = FALSE, stderr = FALSE)
  setwd(previous_directory)
  if (!identical(manifest_status, 0L)) fail("Generated manifest failed for ", case_key)
  assert_published_folder(case_key, staged)
  audit[[length(audit) + 1L]] <- data.frame(key = case_key, label = registry$label[registry$key == case_key], status = "passed")
}

audit <- do.call(rbind, audit)
write.csv(audit, file.path(repo, "validation-summary.csv"), row.names = FALSE, quote = TRUE)
cat("Validated Job 21641 Diagnostic reference and ", nrow(audit), " one-at-a-time sensitivity cases.\n", sep = "")
