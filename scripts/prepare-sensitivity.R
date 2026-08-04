#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
usage <- function(status = 1L) {
  cat("Usage: Rscript scripts/prepare-sensitivity.R CASE OUTPUT_DIR\n", file = stderr())
  quit(status = status)
}
if (length(args) != 2L) usage()

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
if (length(script_arg) != 1L) stop("Cannot locate repository root.", call. = FALSE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
case_key <- args[[1L]]
output <- normalizePath(args[[2L]], mustWork = FALSE)

registry <- read.csv(file.path(repo, "sensitivities.csv"), check.names = FALSE, stringsAsFactors = FALSE)
row <- registry[registry$key == case_key, , drop = FALSE]
if (nrow(row) != 1L) {
  cat("Unknown sensitivity: ", case_key, "\nAvailable: ",
      paste(registry$key, collapse = ", "), "\n", sep = "", file = stderr())
  quit(status = 2L)
}

sha256 <- function(path) {
  out <- system2("sha256sum", path, stdout = TRUE)
  if (length(out) != 1L) stop("sha256sum failed for ", path, call. = FALSE)
  strsplit(out, "[[:space:]]+")[[1L]][1L]
}

verify_manifest <- function(root, manifest_path) {
  manifest <- read.table(manifest_path, col.names = c("sha256", "file"), stringsAsFactors = FALSE)
  observed <- vapply(file.path(root, manifest$file), sha256, character(1))
  bad <- observed != manifest$sha256
  if (any(bad)) {
    stop("Frozen Diagnostic input hash mismatch: ", paste(manifest$file[bad], collapse = ", "), call. = FALSE)
  }
}

verify_sources <- function() {
  expected <- c(
    "sources/age-length/bet.2026.sub.basin.0.75.age_length" = "426859b825bd815aa69c8d97c9dd93097027ed1eb6b9e444d88b69562097a00c",
    "sources/age-length/bet.2026.sub.basin.1.age_length" = "7e6c0513e2f36ca2044c1d5a2de37c589c75fafabc3fd96b45683cbb1236b083",
    "sources/effort-creep/bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq" = "3e7b9c9173584f147eaf42cc6e3e51e3c89d47602830c021975f123c19712663",
    "sources/mixing/bet.2026.mix-0.1.ini" = "e0b6313a8bd0239dd0ba0305ecad0b58f286ef4a2c6e75a7da5fd5dae957ca03",
    "sources/mixing/bet.2026.mix-0.2.ini" = "1e8c589854274248efcb8b08cc85b476e718d2f5d985e03873e973181ae11e94",
    "sources/mixing/bet.2026.mix-0.3.ini" = "0d0b797d8439de174585de479e2f0211031f1a31af88d315cc3ce2821e4ab0fc",
    "sources/regional-scaling/bet.reg_scaling.full" = "dea4c281f7dc46a7412b7ad2e78906ee57b51b62cf1a18c4609381132bf752ed"
  )
  observed <- vapply(file.path(repo, names(expected)), sha256, character(1))
  bad <- observed != unname(expected)
  if (any(bad)) stop("Authoritative source hash mismatch: ", paste(names(expected)[bad], collapse = ", "), call. = FALSE)
}

write_lines <- function(lines, path) writeLines(lines, path, useBytes = TRUE)
split_fields <- function(x) strsplit(trimws(x), "[[:space:]]+")[[1L]]

data_rows_after <- function(lines, marker, n, occurrence = 1L) {
  hit <- grep(marker, lines)
  if (length(hit) < occurrence) stop("Could not find marker matching ", marker, call. = FALSE)
  hit <- hit[[occurrence]]
  found <- integer()
  i <- hit + 1L
  while (i <= length(lines) && length(found) < n) {
    if (nzchar(trimws(lines[[i]])) && !grepl("^[[:space:]]*#", lines[[i]])) found <- c(found, i)
    i <- i + 1L
  }
  if (length(found) != n) stop("Could not read ", n, " rows after ", marker, call. = FALSE)
  found
}

replace_row_field <- function(path, marker, row_number, field, value) {
  lines <- readLines(path, warn = FALSE)
  index <- data_rows_after(lines, marker, row_number)[[row_number]]
  fields <- split_fields(lines[[index]])
  if (length(fields) < field) stop("Field does not exist in ", path, call. = FALSE)
  fields[[field]] <- as.character(value)
  lines[[index]] <- paste(fields, collapse = " ")
  write_lines(lines, path)
}

replace_tag_column <- function(path, source_path = NULL, column, constant = NULL) {
  lines <- readLines(path, warn = FALSE)
  rows <- data_rows_after(lines, "^# tag flags[[:space:]]*$", 98L)
  source_values <- NULL
  if (!is.null(source_path)) {
    source_lines <- readLines(source_path, warn = FALSE)
    source_rows <- data_rows_after(source_lines, "^# tag flags[[:space:]]*$", 98L)
    source_values <- vapply(source_rows, function(i) split_fields(source_lines[[i]])[[column]], character(1))
  }
  for (j in seq_along(rows)) {
    fields <- split_fields(lines[[rows[[j]]]])
    if (length(fields) != 10L) stop("Tag flag row does not have 10 fields in ", path, call. = FALSE)
    fields[[column]] <- if (!is.null(source_values)) source_values[[j]] else as.character(constant)
    lines[[rows[[j]]]] <- paste(fields, collapse = " ")
  }
  write_lines(lines, path)
}

replace_shell_assignment <- function(path, name, value) {
  lines <- readLines(path, warn = FALSE)
  hit <- grep(paste0("^", name, "="), lines)
  if (length(hit) != 1L) stop("Expected one assignment for ", name, call. = FALSE)
  lines[[hit]] <- paste0(name, "=", value)
  write_lines(lines, path)
}

replace_flag_lines <- function(path, flag, old, new) {
  lines <- readLines(path, warn = FALSE)
  pattern <- paste0("^([[:space:]]*1[[:space:]]+", flag, "[[:space:]]+)", old, "([[:space:]]|$)")
  hit <- grep(pattern, lines)
  if (!length(hit)) stop("No flag ", flag, "=", old, " line in ", path, call. = FALSE)
  lines[hit] <- sub(pattern, paste0("\\1", new, "\\2"), lines[hit])
  write_lines(lines, path)
}

replace_sixth_token <- function(line, value) {
  locations <- gregexpr("[^[:space:]]+", line)[[1L]]
  lengths <- attr(locations, "match.length")
  if (length(locations) < 6L) stop("FRQ row has fewer than six fields.", call. = FALSE)
  start <- locations[[6L]]
  finish <- start + lengths[[6L]] - 1L
  paste0(substr(line, 1L, start - 1L), value, substr(line, finish + 1L, nchar(line)))
}

replace_high_effort <- function(base_path, source_path) {
  base <- readLines(base_path, warn = FALSE)
  source <- readLines(source_path, warn = FALSE)
  collect <- function(lines) {
    ans <- list()
    for (i in seq_along(lines)) {
      f <- split_fields(lines[[i]])
      if (length(f) < 7L || any(!grepl("^[0-9]+$", f[1:4]))) next
      fish <- suppressWarnings(as.integer(f[[4L]]))
      if (!is.na(fish) && fish >= 29L && fish <= 33L) {
        key <- paste(f[1:4], collapse = ":")
        if (!is.null(ans[[key]])) stop("Duplicate FRQ key: ", key, call. = FALSE)
        ans[[key]] <- list(line = i, fields = f)
      }
    }
    ans
  }
  b <- collect(base); s <- collect(source)
  if (length(b) != 1458L || !setequal(names(b), names(s))) {
    stop("High-creep and Diagnostic F29-F33 records do not match (expected 1458).", call. = FALSE)
  }
  for (key in names(b)) {
    i <- b[[key]]$line
    base[[i]] <- replace_sixth_token(base[[i]], s[[key]]$fields[[6L]])
  }
  write_lines(base, base_path)
}

make_caal_half <- function(source_path, output_path) {
  lines <- readLines(source_path, warn = FALSE)
  row <- data_rows_after(lines, "^# effective sample size[[:space:]]*$", 1L)[[1L]]
  values <- suppressWarnings(as.numeric(split_fields(lines[[row]])))
  if (length(values) != 181L || any(!is.finite(values))) stop("Expected 181 CAAL ESS values.", call. = FALSE)
  lines[[row]] <- paste(format(values * 0.5, digits = 15L, scientific = FALSE, trim = TRUE), collapse = " ")
  write_lines(lines, output_path)
}

refresh_model_manifest <- function(run_dir) {
  manifest_path <- file.path(run_dir, "MANIFEST.sha256")
  manifest <- read.table(manifest_path, col.names = c("sha256", "file"), stringsAsFactors = FALSE)
  manifest$sha256 <- vapply(file.path(run_dir, manifest$file), sha256, character(1))
  write.table(manifest, manifest_path, row.names = FALSE, col.names = FALSE, quote = FALSE)
}

verify_manifest(file.path(repo, "model"), file.path(repo, "model", "MANIFEST.sha256"))
verify_sources()

if (dir.exists(output) && length(list.files(output, all.files = TRUE, no.. = TRUE))) {
  stop("Output directory is not empty: ", output, call. = FALSE)
}
dir.create(output, recursive = TRUE, showWarnings = FALSE)
status <- system2("cp", c("-a", paste0(file.path(repo, "model"), "/."), output))
if (!identical(status, 0L)) stop("Failed to copy frozen Diagnostic model.", call. = FALSE)
invisible(file.copy(file.path(repo, "mfclo64"), file.path(output, "mfclo64"), overwrite = TRUE))
Sys.chmod(file.path(output, c("mfclo64", "doitall.sh")), mode = "0755")

ini <- file.path(output, "bet.ini")
doitall <- file.path(output, "doitall.sh")
model_config <- file.path(output, "model-inputs", "Diagnostic.conf")

if (grepl("^steepness-", case_key)) {
  value <- sprintf("%.2f", as.numeric(row$alternative))
  replace_row_field(ini, "^# sv[(]29[)][[:space:]]*$", 1L, 1L, value)
  replace_shell_assignment(model_config, "STEEPNESS", value)
} else if (grepl("^tau-", case_key)) {
  tau_values <- c(
    "tau-1.006738" = "1.006737947",
    "tau-1.2" = "1.2",
    "tau-1.4" = "1.4",
    "tau-1.6" = "1.6",
    "tau-1.8" = "1.8",
    "tau-3" = "3.0",
    "tau-5" = "5.0",
    "tau-7" = "7.0"
  )
  tau_pars <- c(
    "tau-1.006738" = "-5",
    "tau-1.2" = "-1.60943791243410",
    "tau-1.4" = "-0.916290731874155",
    "tau-1.6" = "-0.510825623765991",
    "tau-1.8" = "-0.223143551314210",
    "tau-3" = "0.693147180559945",
    "tau-5" = "1.38629436111989",
    "tau-7" = "1.79175946922805"
  )
  replace_shell_assignment(model_config, "TAU", unname(tau_values[[case_key]]))
  replace_shell_assignment(model_config, "TAU_FISH_PARS4", unname(tau_pars[[case_key]]))
} else if (case_key %in% c("tag-mixing-k-0.1", "tag-mixing-k-0.3")) {
  value <- if (case_key == "tag-mixing-k-0.1") "0.1" else "0.3"
  source <- file.path(repo, "sources", "mixing", paste0("bet.2026.mix-", value, ".ini"))
  replace_tag_column(ini, source, 1L)
} else if (case_key == "caal-0.5-sub-basin") {
  make_caal_half(file.path(repo, "sources", "age-length", "bet.2026.sub.basin.1.age_length"),
                 file.path(output, "bet.age_length"))
} else if (case_key == "caal-1.0-sub-basin") {
  invisible(file.copy(file.path(repo, "sources", "age-length", "bet.2026.sub.basin.1.age_length"),
                      file.path(output, "bet.age_length"), overwrite = TRUE))
} else if (case_key %in% c("lorenzen-m-scalar-0.062", "lorenzen-m-scalar-0.1")) {
  value <- if (case_key == "lorenzen-m-scalar-0.062") 0.062 else 0.1
  log_value <- sprintf("%.14e", log(value))
  replace_row_field(ini, "^# age_pars[[:space:]]*$", 5L, 1L, log_value)
  replace_shell_assignment(model_config, "M_LOG_INTERCEPT", log_value)
} else if (case_key == "effort-creep-high") {
  replace_high_effort(file.path(output, "bet.frq"),
                      file.path(repo, "sources", "effort-creep",
                                "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq"))
} else if (case_key == "regional-scaling-whole-period") {
  full <- readLines(file.path(repo, "sources", "regional-scaling", "bet.reg_scaling.full"), warn = FALSE)
  if (length(full) != 292L || any(vapply(strsplit(trimws(full), "[[:space:]]+"), length, integer(1)) != 5L)) {
    stop("Full regional-scaling source must be a 292 by 5 matrix.", call. = FALSE)
  }
  write_lines(full[3:292], file.path(output, "bet.reg_scaling"))
  replace_flag_lines(doitall, 79L, 240L, 290L)
  replace_flag_lines(doitall, 80L, 220L, 0L)
} else if (case_key == "pre-mixing-tag-reporting-inclusion") {
  replace_tag_column(ini, column = 2L, constant = "0")
} else {
  stop("Unimplemented sensitivity: ", case_key, call. = FALSE)
}

refresh_model_manifest(output)

metadata <- data.frame(
  key = row$key, axis = row$axis, label = row$label,
  reference = row$reference, alternative = row$alternative,
  scientific_change = row$scientific_change,
  diagnostic_source_job = 21641L,
  diagnostic_source_commit = "e93b9bc6284b17cc5ab2af4ccabb1cfe776e76a5",
  stringsAsFactors = FALSE
)
write.csv(metadata, file.path(output, "sensitivity-metadata.csv"), row.names = FALSE, quote = TRUE)

write_lines(c(
  paste0("# ", row$label),
  "",
  paste0("- Diagnostic reference: ", row$reference),
  paste0("- Sensitivity value: ", row$alternative),
  paste0("- Input change: ", row$scientific_change),
  "",
  "This folder is a complete, frozen model input set. The shared `mfclo64`",
  "executable is copied here automatically when the model is run from the",
  "repository root with `./run.sh <case-key>`."
), file.path(output, "README.md"))

files <- list.files(output, recursive = TRUE, full.names = TRUE)
files <- files[file.info(files)$isdir %in% FALSE]
manifest <- data.frame(
  sha256 = vapply(files, sha256, character(1)),
  file = substring(files, nchar(output) + 2L), stringsAsFactors = FALSE
)
manifest <- manifest[order(manifest$file), ]
write.table(manifest, file.path(output, "INPUTS.sha256"), row.names = FALSE, col.names = FALSE, quote = FALSE)
cat("Prepared ", case_key, " in ", output, "\n", sep = "")
