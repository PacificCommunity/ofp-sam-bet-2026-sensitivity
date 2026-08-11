#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
registry <- read.csv(
  file.path(repo, "more_tau_sens.csv"),
  stringsAsFactors = FALSE,
  check.names = FALSE
)
original_registry <- read.csv(
  file.path(repo, "sensitivities.csv"),
  stringsAsFactors = FALSE,
  check.names = FALSE
)
base <- file.path(repo, "model")
test_root <- tempfile("bet-more-tau-validation-")
dir.create(test_root)
on.exit(unlink(test_root, recursive = TRUE), add = TRUE)

fail <- function(...) stop(..., call. = FALSE)
hash <- function(path) {
  result <- system2("sha256sum", path, stdout = TRUE, stderr = TRUE)
  if (length(result) != 1L) fail("Could not hash ", path)
  strsplit(result, "[[:space:]]+")[[1L]][[1L]]
}
relative_files <- function(root) {
  paths <- list.files(root, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
  paths <- paths[file.info(paths)$isdir %in% FALSE]
  sort(substring(paths, nchar(root) + 2L))
}
read_config <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines <- lines[grepl("^[A-Z][A-Z0-9_]*=", lines)]
  stats::setNames(sub("^[^=]*=", "", lines), sub("=.*$", "", lines))
}
verify_manifest <- function(root, name) {
  path <- file.path(root, name)
  manifest <- read.table(path, col.names = c("sha256", "file"), stringsAsFactors = FALSE)
  if (anyDuplicated(manifest$file)) fail(name, " has duplicate paths in ", root)
  missing <- manifest$file[!file.exists(file.path(root, manifest$file))]
  if (length(missing)) fail(name, " lists missing files in ", root, ": ", paste(missing, collapse = ", "))
  observed <- vapply(file.path(root, manifest$file), hash, character(1))
  bad <- manifest$file[observed != manifest$sha256]
  if (length(bad)) fail(name, " hash mismatch in ", root, ": ", paste(bad, collapse = ", "))
  manifest
}

kflow_lines <- readLines(file.path(repo, "kflow-more-tau.yaml"), warn = FALSE)
yaml_value <- function(pattern) {
  hit <- grep(pattern, kflow_lines, value = TRUE)
  if (length(hit) != 1L) fail("Expected one Kflow provenance field matching ", pattern)
  trimws(sub("^[^:]+:", "", hit))
}
expected_image <- paste0(
  "ghcr.io/pacificcommunity/tuna-flow:v2.5@sha256:",
  "c87f1f6d9d4f62dc447844b58afe35f96af175bf933cb6cffbbbe39a59172360"
)
expected_local_mfcl <- "8995f72019869863c1d1c0b4f44fc6a6268d1f79031f5bc79dc354ee10f0a63e"
expected_production_mfcl <- "f5bc1e232a86e51f920bce7271d8e0930d0b160e4d18dc46de44078f0fa24cd0"
if (yaml_value("^docker_image:") != expected_image ||
    yaml_value("^[[:space:]]+PROGRAM_PATH:") != "/home/mfcl/mfclo64" ||
    yaml_value("^[[:space:]]+production_program_path:") != "/home/mfcl/mfclo64" ||
    yaml_value("^[[:space:]]+production_mfcl_version:") != "2.2.7.9" ||
    yaml_value("^[[:space:]]+production_mfcl_sha256:") != expected_production_mfcl ||
    yaml_value("^[[:space:]]+local_phase0_mfcl_sha256:") != expected_local_mfcl ||
    hash(file.path(repo, "mfclo64")) != expected_local_mfcl) {
  fail("Pinned image, PROGRAM_PATH, or MFCL SHA256 provenance changed.")
}

expected_tau <- c(
  seq(4, 32, by = 4),
  4.2, 4.4, 4.6, 4.8, 5.0, 5.2, 5.4, 5.6, 5.8, 6.0
)
expected_keys <- c(
  paste0("tau-", seq(4L, 32L, by = 4L)),
  "tau-4.2", "tau-4.4", "tau-4.6", "tau-4.8", "tau-5",
  "tau-5.2", "tau-5.4", "tau-5.6", "tau-5.8", "tau-6"
)
if (!identical(registry$key, expected_keys) ||
    !isTRUE(all.equal(as.numeric(registry$alternative), expected_tau, tolerance = 1e-12)) ||
    nrow(registry) != 18L || anyDuplicated(registry$key)) {
  fail("more_tau_sens.csv must define the original 8 cases followed by the 10 fine values tau=4.2,...,6.0.")
}
if (nrow(original_registry) != 17L || length(intersect(original_registry$key, registry$key))) {
  fail("The original 17-case registry must remain separate from the more-tau campaign.")
}

base_manifest <- verify_manifest(base, "MANIFEST.sha256")
base_files <- relative_files(base)
required_base <- c(
  "bet.age_length", "bet.frq", "bet.ini", "bet.reg_scaling", "bet.tag",
  "cpue_mle_sigma_audit.csv", "doitall.sh", "fishery_map.R", "MANIFEST.sha256",
  "mfcl.cfg", "model-inputs/Diagnostic.conf", "README.md",
  "selectivity-models/Diagnostic.csv", "tag_rep_map.R"
)
if (!identical(base_files, sort(required_base))) fail("Unexpected Diagnostic base-model file set.")

doitall <- readLines(file.path(base, "doitall.sh"), warn = FALSE)
doitall_text <- paste(doitall, collapse = "\n")
required_recipe <- c(
  "$program_path bet.frq bet.ini 00.par -makepar",
  "$program_path bet.frq 00.fixed.par 01.par -file - <<PHASE1",
  "$program_path bet.frq 01.par 02.par -file - <<PHASE2",
  "$program_path bet.frq 09.par 10.par -file - <<PHASE10_TAU_FIXED",
  "$program_path bet.frq 10.par 11.par -file - <<PHASE11_TAU_FIXED",
  "phase10_11_convergence=${BET_PHASE10_11_CONVERGENCE:--4}",
  "1 111 4",
  "1 305 1",
  "1 306 0",
  "-999 43 0",
  "-999 44 0"
)
missing_recipe <- required_recipe[!vapply(required_recipe, grepl, logical(1), x = doitall_text, fixed = TRUE)]
if (length(missing_recipe)) fail("Diagnostic doitall recipe is missing: ", paste(missing_recipe, collapse = "; "))
if (sum(grepl("^[[:space:]]*1[[:space:]]+50[[:space:]]+[$]phase10_11_convergence", doitall)) != 2L) {
  fail("Phase 10 and Phase 11 must both use the shared -4 convergence control.")
}
if (grepl("(^|[[:space:]/])final[.]par([[:space:]]|$)", doitall_text) ||
    grepl("checkpoints/.*[.]par", doitall_text)) {
  fail("Diagnostic doitall must not initialize from final.par or a fitted checkpoint.")
}

base_config <- read_config(file.path(base, "model-inputs/Diagnostic.conf"))
if (base_config[["TAU"]] != "2.0" || base_config[["TAU_FISH_PARS4"]] != "0" ||
    base_config[["STEEPNESS"]] != "0.90" || base_config[["MODEL_ID"]] != "Diagnostic") {
  fail("Unexpected Diagnostic reference configuration.")
}

audit <- vector("list", nrow(registry))
for (i in seq_len(nrow(registry))) {
  case_key <- registry$key[[i]]
  target_tau <- expected_tau[[i]]
  expected_par <- log(target_tau - 1)
  if (expected_par < -5 || expected_par > 5) fail("Target outside fish_pars(4) bounds: ", case_key)

  staged <- file.path(test_root, case_key)
  status <- system2(
    "Rscript",
    c(file.path(repo, "scripts/prepare-sensitivity.R"), case_key, staged),
    stdout = FALSE,
    stderr = FALSE
  )
  if (!identical(status, 0L)) fail("Preparation failed for ", case_key)

  staged_manifest <- verify_manifest(staged, "MANIFEST.sha256")
  if (!identical(staged_manifest$file, base_manifest$file)) {
    fail("Scientific MANIFEST file set changed for ", case_key)
  }
  changed_science <- base_manifest$file[
    vapply(
      base_manifest$file,
      function(path) hash(file.path(base, path)) != hash(file.path(staged, path)),
      logical(1)
    )
  ]
  if (!identical(changed_science, "model-inputs/Diagnostic.conf")) {
    fail(
      case_key,
      " changed scientific inputs other than Diagnostic.conf: ",
      paste(changed_science, collapse = ", ")
    )
  }
  changed_common <- intersect(base_files, relative_files(staged))
  changed_common <- changed_common[
    vapply(
      changed_common,
      function(path) hash(file.path(base, path)) != hash(file.path(staged, path)),
      logical(1)
    )
  ]
  if (!identical(sort(changed_common), sort(c(
    "MANIFEST.sha256", "README.md", "model-inputs/Diagnostic.conf"
  )))) {
    fail(case_key, " changed an unexpected common file: ", paste(changed_common, collapse = ", "))
  }

  staged_config <- read_config(file.path(staged, "model-inputs/Diagnostic.conf"))
  config_changes <- names(base_config)[base_config != staged_config[names(base_config)]]
  if (!setequal(config_changes, c("TAU", "TAU_FISH_PARS4"))) {
    fail(case_key, " changed unexpected Diagnostic.conf fields: ", paste(config_changes, collapse = ", "))
  }
  observed_tau <- as.numeric(staged_config[["TAU"]])
  observed_par <- as.numeric(staged_config[["TAU_FISH_PARS4"]])
  reconstructed_tau <- 1 + exp(observed_par)
  if (abs(observed_tau - target_tau) > 1e-12 ||
      abs(observed_par - expected_par) > 5e-14 ||
      abs(reconstructed_tau - target_tau) > 5e-13 ||
      observed_par < -5 || observed_par > 5) {
    fail("Direct fixed-tau reconstruction or bounds failed for ", case_key)
  }

  metadata <- read.csv(file.path(staged, "sensitivity-metadata.csv"), stringsAsFactors = FALSE)
  if (nrow(metadata) != 1L || metadata$key != case_key ||
      abs(as.numeric(metadata$alternative) - target_tau) > 1e-12 ||
      metadata$diagnostic_source_job != 21641L) {
    fail("Sensitivity metadata is wrong for ", case_key)
  }
  readme <- paste(readLines(file.path(staged, "README.md"), warn = FALSE), collapse = "\n")
  if (!grepl(paste0("Sensitivity value: ", target_tau), readme, fixed = TRUE) ||
      !grepl("log(", readme, fixed = TRUE)) {
    fail("Per-model README does not describe its fixed tau for ", case_key)
  }

  published <- file.path(repo, "models", case_key)
  if (!dir.exists(published)) fail("Missing frozen model folder: models/", case_key)
  published_manifest <- verify_manifest(published, "MANIFEST.sha256")
  verify_manifest(published, "INPUTS.sha256")
  if (!identical(published_manifest, staged_manifest)) fail("Published MANIFEST differs for ", case_key)
  staged_files <- setdiff(relative_files(staged), "mfclo64")
  published_files <- relative_files(published)
  if (!identical(staged_files, published_files)) fail("Published file set differs for ", case_key)
  for (path in setdiff(staged_files, "INPUTS.sha256")) {
    if (hash(file.path(staged, path)) != hash(file.path(published, path))) {
      fail("Published frozen input differs for ", case_key, "/", path)
    }
  }

  audit[[i]] <- data.frame(
    key = case_key,
    tau = target_tau,
    fish_pars4 = observed_par,
    reconstructed_tau = reconstructed_tau,
    lower_bound = -5,
    upper_bound = 5,
    scientific_files_changed = "model-inputs/Diagnostic.conf",
    ordinary_makepar = TRUE,
    phase10_convergence = -4,
    phase11_convergence = -4,
    stringsAsFactors = FALSE
  )
}

audit <- do.call(rbind, audit)
print(audit, row.names = FALSE, digits = 15)
cat(
  "Validated 18 frozen more-tau models: only Diagnostic.conf changes scientific content; ",
  "MANIFEST/metadata/README/INPUTS bookkeeping is isolated; direct tau reconstruction, ",
  "bounds, fixed switches, ordinary makepar, and Phase 10/11 -4 controls passed.\n",
  sep = ""
)
