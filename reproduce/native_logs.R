#!/usr/bin/env Rscript
# Restore exact original derivative logs, bound to the saved Hessian parts.
script_l <- commandArgs()[grepl("^--file=", commandArgs())]
if (sys.nframe() == 0L) {
  if (length(script_l) != 1L) stop("Run native_logs.R with Rscript", call. = FALSE)
  source(file.path(dirname(normalizePath(sub("^--file=", "", script_l), mustWork = TRUE)), "hessian.R"))
}
read_logs_l <- function(path, hessians) {
  data <- json_h(path)
  keys_h(data, c("schema_version", "classification", "kind", "repository", "hessians_sha256", "archive", "members"))
  require_h(identical(data$schema_version, 1L) && identical(data$classification, "PUBLIC") && identical(data$kind, "native_logs") &&
              is.character(data$repository) && length(data$repository) == 1L && data$repository %in% c("PacificCommunity/ofp-sam-bet-2026-stepwise", "PacificCommunity/ofp-sam-bet-2026-sensitivity"), "Invalid native log manifest schema")
  require_h(hash_h(data$hessians_sha256) && sha_h(hessians) == data$hessians_sha256, "Saved Hessian manifest hash differs")
  saved <- read_manifest_h(hessians)
  require_h(saved$repository == data$repository && sha_h(hessians) == data$hessians_sha256, "Saved Hessian repository/source changed")
  archive_pin_h(data$archive, data$repository)
  expected <- list()
  for (case in saved$cases) {
    if (is.null(case$kind) || case$kind != "native_parts") next
    model <- case$model_id
    require_h(safe_h(model) && length(strsplit(model, "/", fixed = TRUE)[[1L]]) == 1L, "Invalid saved native model")
    for (part in case$hessian_parts) {
      require_h(grepl("^parts/part_[1-9][0-9]*/bet\\.hes$", part$path), "Invalid saved native part path")
      number <- as.integer(sub("^parts/part_([1-9][0-9]*)/bet\\.hes$", "\\1", part$path))
      require_h(integer_h(number, .Machine$integer.max) && number > 0L, "Invalid saved native part number")
      name <- paste0(model, "/part_", number, "/mfcl_hessian_log.txt")
      require_h(!name %in% names(expected), "Duplicate saved native log binding")
      expected[[name]] <- list(model_id = model, part = number, row_bounds = part$row_bounds, n_parameter = part$n_parameter)
    }
  }
  members <- data$members
  require_h(object_h(members) && length(members) >= 1L && length(members) <= 256L && setequal(names(members), names(expected)), "Native logs must cover every saved native part exactly")
  paths_h(names(members))
  for (name in names(members)) {
    pin <- members[[name]]
    keys_h(pin, c("bytes", "sha256", "mode", "model_id", "part", "row_bounds", "n_parameter"))
    require_h(integer_h(pin$bytes) && pin$bytes > 0L && hash_h(pin$sha256) && identical(pin$mode, 420L), "Invalid native log member bytes/hash/mode")
    binding <- expected[[name]]
    require_h(all(vapply(names(binding), function(field) identical(pin[[field]], binding[[field]]), logical(1))), "Native log case/part/row binding differs")
  }
  require_h(sum(vapply(members, function(x) x$bytes, numeric(1))) <= 1024^3, "Excessive native log bytes")
  data
}
main_l <- function(args = commandArgs(trailingOnly = TRUE)) {
  here <- script_h(); parsed <- args_h(args, c("--manifest", "--hessians", "--out", "--archive")); opts <- parsed$values
  manifest <- if ("--manifest" %in% names(opts)) opts[["--manifest"]] else file.path(here, "native-logs.json")
  hessians <- if ("--hessians" %in% names(opts)) opts[["--hessians"]] else file.path(here, "hessians.json")
  regular_h(manifest); regular_h(hessians)
  manifest <- normalizePath(manifest, mustWork = TRUE); hessians <- normalizePath(hessians, mustWork = TRUE)
  data <- read_logs_l(manifest, hessians)
  if (parsed$verify) {
    require_h(!"--out" %in% names(opts), "Verification does not create OUT")
    if (!"--archive" %in% names(opts)) { cat("Original native log manifest verified: ", length(data$members), " logs; no model run.\n", sep = ""); return(invisible(NULL)) }
  } else require_h("--out" %in% names(opts), "Set OUT to a fresh absolute external directory")
  out <- if ("--out" %in% names(opts)) opts[["--out"]] else NULL
  archive <- if ("--archive" %in% names(opts)) opts[["--archive"]] else NULL
  output <- restore_h(data, manifest, out, archive, roots = c(dirname(here), dirname(dirname(manifest)), dirname(dirname(hessians))))
  cat(if (parsed$verify) "Original native log archive verified; no model run.\n" else paste0("Restored exact original native logs to ", output, "; no model run.\n"))
}
if (sys.nframe() == 0L) tryCatch(main_l(), error = function(e) { cat(conditionMessage(e), "\n", file = stderr()); quit(status = 1L) })
