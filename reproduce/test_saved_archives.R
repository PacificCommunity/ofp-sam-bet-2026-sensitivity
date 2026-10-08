#!/usr/bin/env Rscript
# Small offline fixtures for the R readers. No MFCL, fitting or downloads.
script <- commandArgs()[grepl("^--file=", commandArgs())]
here <- dirname(normalizePath(sub("^--file=", "", script), mustWork = TRUE))
source(file.path(here, "hessian.R")); source(file.path(here, "native_logs.R"))
root <- tempfile("bet-r-archive-tests-"); stopifnot(dir.create(root))
root <- normalizePath(root)
json_t <- function(x) {
  if (is.null(x)) return("null")
  if (is.list(x)) {
    values <- vapply(x, json_t, character(1))
    if (is.null(names(x))) return(paste0("[", paste(values, collapse = ","), "]"))
    return(paste0("{", paste(paste0(vapply(names(x), function(s) encodeString(s, quote = '"'), character(1)), ":", values), collapse = ","), "}"))
  }
  if (is.character(x)) return(encodeString(x, quote = '"'))
  if (is.logical(x)) return(if (x) "true" else "false")
  format(x, scientific = FALSE, trim = TRUE)
}
save_t <- function(data, path) writeLines(json_t(data), path, useBytes = TRUE)
hash_raw_t <- function(raw) {
  p <- tempfile("bytes-", tmpdir = root); writeBin(raw, p)
  result <- sha_h(p); unlink(p); result
}
header_t <- function(n, start, end) writeBin(as.integer(c(n, start, end)), raw(), size = 4L, endian = "little")
hex_t <- function(raw) paste(sprintf("%02x", as.integer(raw)), collapse = "")
pin_t <- function(raw) list(bytes = length(raw), sha256 = hash_raw_t(raw))
pack_t <- function(path, entries, trailer = raw(1024L)) {
  stream <- gzfile(path, "wb"); on.exit(close(stream))
  for (entry in entries) {
    header <- raw(512L)
    put <- function(start, text) { bytes <- charToRaw(text); header[start:(start + length(bytes) - 1L)] <<- bytes }
    put(1L, entry$name); put(101L, sprintf("%07o", if (is.null(entry$mode)) 420L else entry$mode))
    put(109L, "0000000"); put(117L, "0000000"); put(125L, sprintf("%011o", length(entry$raw)))
    put(137L, "00000000000"); put(149L, "        ")
    put(157L, if (is.null(entry$type)) "0" else entry$type)
    if (!is.null(entry$link)) put(158L, entry$link)
    put(258L, "ustar"); put(264L, "00")
    checksum <- sum(as.integer(header)); put(149L, sprintf("%06o", checksum)); header[155L] <- as.raw(0L); header[156L] <- as.raw(32L)
    writeBin(header, stream); writeBin(entry$raw, stream)
    writeBin(if (is.null(entry$padding)) raw((512L - length(entry$raw) %% 512L) %% 512L) else entry$padding, stream)
  }
  writeBin(trailer, stream)
}
fixture_t <- function(label = "fixture") {
  folder <- file.path(root, label); repo <- file.path(folder, "repo"); reproduce <- file.path(repo, "reproduce")
  stopifnot(dir.create(reproduce, recursive = TRUE))
  f <- new.env(parent = emptyenv())
  f$repo <- repo; f$manifest <- file.path(reproduce, "hessians.json"); f$archive <- file.path(reproduce, "saved.tar.gz")
  f$out <- file.path(folder, "restored"); f$logs <- file.path(reproduce, "native-logs.json"); f$logarchive <- file.path(reproduce, "logs.tar.gz")
  f$bodies <- list(final.par = charToRaw("original final PAR\n"))
  parts <- list()
  for (i in 1:2) {
    name <- paste0("parts/part_", i, "/bet.hes"); header <- header_t(2L, i, i)
    raw <- c(header, writeBin(as.double(c(i, i + 1L)), raw(), size = 8L, endian = "little"))
    f$bodies[[name]] <- raw; parts[[i]] <- list(path = name, n_parameter = 2L, row_bounds = list(i, i), bytes_hex = hex_t(header), sha256 = hash_raw_t(raw))
  }
  f$entry <- list(kind = "native_parts", model_id = "Case-A", pdh_status = "UNKNOWN", final_par_sha256 = hash_raw_t(f$bodies$final.par), archive = list(), members = lapply(f$bodies, pin_t), hessian_parts = parts)
  f$data <- list(schema_version = 1L, classification = "PUBLIC", repository = "PacificCommunity/ofp-sam-bet-2026-stepwise", cases = list("case-a" = f$entry))
  f$repack <- function(entries = NULL) {
    if (is.null(entries)) entries <- lapply(names(f$bodies), function(name) list(name = name, raw = f$bodies[[name]]))
    pack_t(f$archive, entries)
    f$entry$archive <- list(relative_path = "saved.tar.gz", bytes = as.integer(file.info(f$archive)$size), sha256 = sha_h(f$archive))
    f$data$cases[[1L]] <- f$entry; save_t(f$data, f$manifest)
  }
  f$restore <- function(out = f$out, archive = NULL) restore_h(read_manifest_h(f$manifest)$cases[[1L]], f$manifest, out, archive, roots = f$repo)
  f$make_logs <- function() {
    f$logbodies <- list("Case-A/part_1/mfcl_hessian_log.txt" = charToRaw("row 1\nlikelihood -2.5\n"), "Case-A/part_2/mfcl_hessian_log.txt" = charToRaw("row 2\npenalty 0.25\n"))
    entries <- lapply(names(f$logbodies), function(name) list(name = name, raw = f$logbodies[[name]]))
    pack_t(f$logarchive, entries)
    members <- lapply(seq_along(f$logbodies), function(i) c(pin_t(f$logbodies[[i]]), list(mode = 420L, model_id = "Case-A", part = as.integer(i), row_bounds = list(as.integer(i), as.integer(i)), n_parameter = 2L)))
    names(members) <- names(f$logbodies)
    f$logdata <- list(schema_version = 1L, classification = "PUBLIC", kind = "native_logs", repository = f$data$repository, hessians_sha256 = sha_h(f$manifest), archive = list(relative_path = "logs.tar.gz", bytes = as.integer(file.info(f$logarchive)$size), sha256 = sha_h(f$logarchive)), members = members)
    save_t(f$logdata, f$logs)
  }
  f$restore_logs <- function(out = f$out) restore_h(read_logs_l(f$logs, f$manifest), f$logs, out, roots = f$repo)
  f$repack(); f
}
expect_error_t <- function(expression, output = NULL) {
  error <- tryCatch({ force(expression); NULL }, error = identity)
  stopifnot(inherits(error, "error"))
  if (!is.null(output)) stopifnot(!file.exists(output), !dir.exists(output))
}
count <- 0L
filter <- Sys.getenv("BET_ARCHIVE_TEST_FILTER", "")
test_t <- function(name, code) {
  if (nzchar(filter) && !grepl(filter, name)) return(invisible(NULL))
  force(code); count <<- count + 1L; cat("PASS ", count, " ", name, "\n", sep = "")
}
tryCatch({
  f <- fixture_t()
  test_t("restore native parts as exact original bytes", {
    f$restore(); for (name in names(f$bodies)) stopifnot(identical(readBin(file.path(f$out, name), "raw", n = length(f$bodies[[name]])), f$bodies[[name]]))
    stopifnot(!file.exists(file.path(f$out, "bet.hes")), as.integer(file.info(f$out)$mode) %% 512L == 448L)
    stopifnot(all(vapply(names(f$bodies), function(name) as.integer(file.info(file.path(f$out, name))$mode) %% 512L == 384L, logical(1))))
  })
  unlink(f$out, recursive = TRUE)
  test_t("verify offline archive creates no output", { f$restore(out = NULL); stopifnot(!file.exists(f$out)) })
  test_t("existing output is preserved", { dir.create(f$out); writeLines("keep", file.path(f$out, "keep")); expect_error_t(f$restore()); stopifnot(readLines(file.path(f$out, "keep")) == "keep"); unlink(f$out, recursive = TRUE) })
  test_t("repository and ancestor output are rejected", { expect_error_t(f$restore(file.path(f$repo, "new"))); expect_error_t(output_h(dirname(f$repo), f$repo)) })
  test_t("relative, traversal and symlink parent are rejected", {
    for (out in c("relative", paste0(dirname(f$out), "/./new"), paste0(dirname(f$out), "/../new"))) expect_error_t(f$restore(out))
    link <- file.path(dirname(f$out), "linked"); stopifnot(file.symlink(dirname(f$out), link)); expect_error_t(f$restore(file.path(link, "new"))); stopifnot(!file.exists(file.path(dirname(f$out), "new")))
  })
  test_t("manifest and archive symlinks are rejected", {
    link <- file.path(dirname(f$manifest), "linked.json"); stopifnot(file.symlink(f$manifest, link)); expect_error_t(read_manifest_h(link))
    link <- file.path(dirname(f$archive), "linked.tar.gz"); stopifnot(file.symlink(f$archive, link)); expect_error_t(f$restore(archive = link), f$out)
  })
  test_t("bad source archive hash is rejected before OUT", { changed <- f$data; changed$cases[[1L]]$archive$sha256 <- strrep("0", 64L); save_t(changed, f$manifest); expect_error_t(f$restore(), f$out); save_t(f$data, f$manifest) })
  test_t("unknown fields, kind, scalar types and duplicate keys fail", {
    for (mutate in list(function(d) { d$extra <- "unknown"; d }, function(d) { d$cases[[1L]]$kind <- "new"; d }, function(d) { d$schema_version <- TRUE; d }, function(d) { d$cases[[1L]]$members$final.par$bytes <- TRUE; d })) {
      save_t(mutate(f$data), f$manifest); expect_error_t(read_manifest_h(f$manifest))
    }
    writeLines(sub('"schema_version":1', '"schema_version":1,"schema_version":1', json_t(f$data), fixed = TRUE), f$manifest); expect_error_t(read_manifest_h(f$manifest))
    writeLines(sub('"schema_version":1', '"schema_version":1.0', json_t(f$data), fixed = TRUE), f$manifest); expect_error_t(read_manifest_h(f$manifest)); save_t(f$data, f$manifest)
  })
  test_t("unsafe, case-colliding and ancestor member paths fail", {
    for (path in c("../escape", "/absolute", "parts//x", "parts/./x", "parts/../x", "parts/x/", "parts/part_1", "FINAL.PAR")) {
      changed <- f$data; changed$cases[[1L]]$members[[path]] <- pin_t(charToRaw("x")); save_t(changed, f$manifest); expect_error_t(read_manifest_h(f$manifest))
    }; save_t(f$data, f$manifest)
  })
  test_t("part gaps, dimensions, source pins and header/layout are checked", {
    for (mutate in list(function(d) { d$cases[[1L]]$hessian_parts[[2L]]$row_bounds <- list(1L, 2L); d }, function(d) { d$cases[[1L]]$hessian_parts[[2L]]$n_parameter <- 3L; d }, function(d) { d$cases[[1L]]$hessian_parts[[1L]]$bytes_hex <- strrep("00", 12L); d }, function(d) { d$cases[[1L]]$hessian_parts[[1L]]$sha256 <- strrep("0", 64L); d }, function(d) { d$cases[[1L]]$members[[2L]]$bytes <- 29L; d }, function(d) { d$cases[[1L]]$final_par_sha256 <- strrep("0", 64L); d })) {
      save_t(mutate(f$data), f$manifest); expect_error_t(read_manifest_h(f$manifest))
    }; save_t(f$data, f$manifest)
  })
  original <- lapply(names(f$bodies), function(name) list(name = name, raw = f$bodies[[name]]))
  test_t("missing, extra and duplicate tar members fail", {
    for (entries in list(original[-1L], c(original, list(list(name = "extra", raw = charToRaw("extra")))), c(original, original[1L]))) {
      f$repack(entries); expect_error_t(f$restore(), f$out)
    }; f$repack()
  })
  test_t("tar links, directories, extensions and traversal fail", {
    for (type in c("1", "2", "5", "x", "L")) { entries <- original; entries[[1L]]$type <- type; entries[[1L]]$link <- "outside"; f$repack(entries); expect_error_t(f$restore(), f$out) }
    entries <- original; entries[[1L]]$name <- "../escape"; f$repack(entries); expect_error_t(f$restore(), f$out); f$repack()
  })
  test_t("repinned archive cannot conceal corrupt member or header", {
    entries <- original; entries[[1L]]$raw[1L] <- as.raw(88L); f$repack(entries); expect_error_t(f$restore(), f$out)
    body <- f$bodies[[2L]]; f$bodies[[2L]][1L] <- as.raw(3L); f$entry$members[[2L]] <- pin_t(f$bodies[[2L]]); f$entry$hessian_parts[[1L]]$sha256 <- f$entry$members[[2L]]$sha256
    f$repack(); expect_error_t(f$restore(), f$out)
    f$bodies[[2L]] <- body; f$entry$members[[2L]] <- pin_t(body); f$entry$hessian_parts[[1L]]$sha256 <- hash_raw_t(body); f$repack()
  })
  test_t("nonzero padding and tar trailer fail", {
    entries <- original; entries[[1L]]$padding <- rep(as.raw(1L), (512L - length(entries[[1L]]$raw) %% 512L) %% 512L); f$repack(entries); expect_error_t(f$restore(), f$out)
    pack_t(f$archive, original, c(raw(1024L), as.raw(1L))); f$entry$archive$bytes <- as.integer(file.info(f$archive)$size); f$entry$archive$sha256 <- sha_h(f$archive); f$data$cases[[1L]] <- f$entry; save_t(f$data, f$manifest); expect_error_t(f$restore(), f$out); f$repack()
  })
  test_t("plain TAR and invalid gzip headers fail before OUT", {
    compressed <- readBin(f$archive, "raw", n = file.info(f$archive)$size)
    stream <- gzfile(f$archive, "rb"); plain <- tryCatch(readBin(stream, "raw", n = 100000L), finally = close(stream))
    invalid_method <- compressed; invalid_method[3L] <- as.raw(0L)
    invalid_flags <- compressed; invalid_flags[4L] <- as.raw(224L)
    for (raw in list(plain, compressed[1:3], invalid_method, invalid_flags)) {
      writeBin(raw, f$archive); f$entry$archive$bytes <- as.integer(length(raw)); f$entry$archive$sha256 <- hash_raw_t(raw); f$data$cases[[1L]] <- f$entry; save_t(f$data, f$manifest)
      expect_error_t(f$restore(), f$out)
    }; f$repack()
  })
  test_t("root substitution at first copy writes no replacement files", {
    race <- fixture_t("root-swap"); moved <- file.path(dirname(race$out), "original-output"); copier <- stage_h; first <- TRUE
    stage_h <- function(from, to) {
      if (first) { first <<- FALSE; stopifnot(file.rename(race$out, moved), dir.create(race$out)); writeLines("foreign", file.path(race$out, "foreign.txt")) }
      copier(from, to)
    }
    tryCatch(expect_error_t(race$restore()), finally = { stage_h <- copier })
    stopifnot(identical(list.files(race$out, all.files = TRUE, no.. = TRUE), "foreign.txt"), readLines(file.path(race$out, "foreign.txt")) == "foreign", dir.exists(moved))
  })
  test_t("parent substitution at first copy writes no replacement files", {
    race <- fixture_t("parent-swap"); parent <- dirname(race$out); moved <- paste0(parent, "-original"); copier <- stage_h; first <- TRUE
    stage_h <- function(from, to) {
      if (first) { first <<- FALSE; stopifnot(file.rename(parent, moved), dir.create(parent), dir.create(race$out)); writeLines("foreign", file.path(race$out, "foreign.txt")) }
      copier(from, to)
    }
    tryCatch(expect_error_t(race$restore()), finally = { stage_h <- copier })
    stopifnot(identical(list.files(race$out, all.files = TRUE, no.. = TRUE), "foreign.txt"), readLines(file.path(race$out, "foreign.txt")) == "foreign", dir.exists(moved))
  })
  test_t("member-directory substitution writes no replacement files", {
    race <- fixture_t("member-swap"); child <- file.path(race$out, "parts/part_1"); moved <- file.path(dirname(race$out), "original-part"); copier <- stage_h; first <- TRUE
    stage_h <- function(from, to) {
      if (first && basename(from) == "bet.hes") { first <<- FALSE; stopifnot(file.rename(child, moved), dir.create(child)); writeLines("foreign", file.path(child, "foreign.txt")) }
      copier(from, to)
    }
    tryCatch(expect_error_t(race$restore()), finally = { stage_h <- copier })
    stopifnot(!first, identical(list.files(child, all.files = TRUE, no.. = TRUE), "foreign.txt"), readLines(file.path(child, "foreign.txt")) == "foreign", dir.exists(moved))
  })
  test_t("unexpected output entries fail and remain intact", {
    race <- fixture_t("extra-entry"); copier <- stage_h; first <- TRUE
    stage_h <- function(from, to) { if (first) { first <<- FALSE; writeLines("foreign", file.path(race$out, "foreign.txt")) }; copier(from, to) }
    tryCatch(expect_error_t(race$restore()), finally = { stage_h <- copier })
    stopifnot(readLines(file.path(race$out, "foreign.txt")) == "foreign", file.exists(file.path(race$out, "final.par")))
  })
  test_t("exclusive leaf publication preserves a concurrently added file", {
    race <- fixture_t("leaf-exists"); linker <- file.link; first <- TRUE
    file.link <- function(from, to) { if (first) { first <<- FALSE; writeLines("foreign", to) }; linker(from, to) }
    tryCatch(suppressWarnings(expect_error_t(race$restore())), finally = { file.link <- linker })
    stopifnot(readLines(file.path(race$out, "final.par")) == "foreign")
  })
  test_t("exclusive staging refuses planted symlinks before opening", {
    for (existing in c(FALSE, TRUE)) {
      race <- fixture_t(paste0("stage-link-", existing)); foreign <- file.path(dirname(race$out), "unrelated"); creator <- file; first <- TRUE
      if (existing) writeBin(charToRaw("foreign sentinel"), foreign)
      file <- function(description, open = "", ...) {
        if (first && identical(open, "wxb") && startsWith(description, ".bet-member-")) { first <<- FALSE; stopifnot(file.symlink(foreign, description)) }
        creator(description, open, ...)
      }
      tryCatch(suppressWarnings(expect_error_t(race$restore())), finally = { file <- creator })
      stopifnot(!first)
      if (existing) stopifnot(identical(readBin(foreign, "raw", n = 100L), charToRaw("foreign sentinel"))) else stopifnot(!file.exists(foreign))
    }
  })
  test_t("opened staging descriptor writes no replaced leaf target", {
    race <- fixture_t("stage-after-open"); foreign <- file.path(dirname(race$out), "unrelated"); creator <- file; first <- TRUE
    file <- function(description, open = "", ...) {
      connection <- creator(description, open, ...)
      if (first && identical(open, "wxb") && startsWith(description, ".bet-member-")) {
        first <<- FALSE; unlink(description); stopifnot(file.symlink(foreign, description))
      }
      connection
    }
    tryCatch(expect_error_t(race$restore()), finally = { file <- creator })
    stopifnot(!first, !file.exists(foreign))
  })
  test_t("exclusive staging refuses an existing regular staging leaf", {
    race <- fixture_t("stage-existing"); creator <- file; first <- TRUE; occupied <- NULL
    file <- function(description, open = "", ...) {
      if (first && identical(open, "wxb") && startsWith(description, ".bet-member-")) {
        first <<- FALSE; occupied <<- file.path(getwd(), description); writeLines("foreign sentinel", description)
      }
      creator(description, open, ...)
    }
    tryCatch(suppressWarnings(expect_error_t(race$restore())), finally = { file <- creator })
    stopifnot(!first, readLines(occupied) == "foreign sentinel")
  })
  test_t("exclusive archive extraction refuses a planted dangling symlink", {
    race <- fixture_t("archive-link"); foreign <- file.path(dirname(race$out), "unrelated"); creator <- file; first <- TRUE
    file <- function(description, open = "", ...) {
      if (first && identical(open, "wxb") && startsWith(description, "/") && grepl("/members/", description, fixed = TRUE)) {
        first <<- FALSE; stopifnot(file.symlink(foreign, description))
      }
      creator(description, open, ...)
    }
    tryCatch(suppressWarnings(expect_error_t(race$restore(), race$out)), finally = { file <- creator })
    stopifnot(!first, !file.exists(foreign))
  })
  test_t("exclusive download destination refuses a planted dangling symlink", {
    requester <- request_h; target <- file.path(root, "download-stage-link"); foreign <- paste0(target, "-unrelated")
    request_h <- function(url, headers, destination, maximum, timeout) {
      writeLines(c("HTTP/2 200", ""), headers); writeBin(charToRaw("data"), destination)
      stopifnot(file.symlink(foreign, target)); "200"
    }
    tryCatch(suppressWarnings(expect_error_t(download_h("https://github.com/release", target, 4L))), finally = { request_h <- requester })
    stopifnot(!file.exists(foreign), linked_h(target))
  })
  test_t("manual download validates each allowed redirect without network", {
    requester <- request_h; start <- "https://github.com/PacificCommunity/ofp-sam-bet-2026-stepwise/releases/download/test/saved.tar.gz"
    middle <- "https://objects.githubusercontent.com:443/pinned?token=a%2Fb"; final <- "https://release-assets.githubusercontent.com/pinned?token=x&more=y"
    visited <- character(); body <- readBin(f$archive, "raw", n = file.info(f$archive)$size)
    request_h <- function(url, headers, destination, maximum, timeout) {
      visited <<- c(visited, url); stopifnot(timeout > 0, timeout <= 600)
      if (url == start) { writeLines(c("HTTP/1.1 200 Connection established", "", "HTTP/2 302", paste0("Location: ", middle), ""), headers); writeBin(charToRaw("redirect"), destination); "302" }
      else if (url == middle) { writeLines(c("HTTP/2 307", paste0("Location: ", final), ""), headers); writeBin(charToRaw("redirect"), destination); "307" }
      else { stopifnot(url == final); writeLines(c("HTTP/2 200", ""), headers); writeBin(body, destination); "200" }
    }
    target <- file.path(root, "download.tar.gz")
    tryCatch(download_h(start, target, length(body)), finally = { request_h <- requester })
    stopifnot(identical(visited, c(start, middle, final)), identical(readBin(target, "raw", n = length(body)), body))
    stopifnot(redirect_url_h(start, "/relative.tar.gz") == "https://github.com/relative.tar.gz", redirect_url_h(start, "//objects.githubusercontent.com/path") == "https://objects.githubusercontent.com/path")
  })
  test_t("untrusted redirects, loops and excessive redirects are rejected before following", {
    requester <- request_h; start <- "https://github.com/release"; target <- file.path(root, "bad-download.tar.gz")
    for (location in c("https://external.test/file", "http://github.com/file", "https://user@github.com/file", "https://github.com:444/file", "https://github.com/file#fragment", "//external.test/file", "https://github.com/release")) {
      visited <- character()
      request_h <- function(url, headers, destination, maximum, timeout) { visited <<- c(visited, url); writeLines(c("HTTP/2 302", paste0("Location: ", location), ""), headers); writeBin(charToRaw("redirect"), destination); "302" }
      tryCatch(expect_error_t(download_h(start, target, 100L), target), finally = { request_h <- requester })
      stopifnot(identical(visited, start))
    }
    visited <- character()
    request_h <- function(url, headers, destination, maximum, timeout) { visited <<- c(visited, url); writeLines(c("HTTP/2 302", paste0("Location: https://github.com/redirect-", length(visited)), ""), headers); writeBin(charToRaw("redirect"), destination); "302" }
    tryCatch(expect_error_t(download_h(start, target, 100L), target), finally = { request_h <- requester })
    stopifnot(length(visited) == 11L)
  })
  test_t("original matrix remains a matrix", {
    m <- fixture_t("matrix"); raw <- c(header_t(2L, 1L, 2L), writeBin(as.double(1:4), raw(), size = 8L, endian = "little"))
    m$bodies <- list(final.par = m$bodies$final.par, bet.hes = raw); m$entry$kind <- "matrix"; m$entry$hessian_parts <- NULL; m$entry$hessian_sha256 <- hash_raw_t(raw); m$entry$hessian_header <- list(bytes_hex = hex_t(header_t(2L, 1L, 2L)), n_parameter = 2L, row_bounds = list(1L, 2L)); m$entry$members <- lapply(m$bodies, pin_t)
    m$repack(); m$restore(); stopifnot(identical(readBin(file.path(m$out, "bet.hes"), "raw", n = length(raw)), raw))
  })
  f$make_logs()
  test_t("restore exact logs and verify without model execution", {
    f$restore_logs(); for (name in names(f$logbodies)) stopifnot(identical(readBin(file.path(f$out, name), "raw", n = length(f$logbodies[[name]])), f$logbodies[[name]]))
    unlink(f$out, recursive = TRUE); f$restore_logs(NULL); stopifnot(!file.exists(f$out))
  })
  test_t("Hessian source hash and log roster/model/row bindings fail on drift", {
    for (mutate in list(function(d) { d$hessians_sha256 <- strrep("0", 64L); d }, function(d) { d$members[[1L]] <- NULL; d }, function(d) { d$members[[1L]]$row_bounds <- list(2L, 2L); d }, function(d) { d$members[[1L]]$row_bounds <- list(TRUE, TRUE); d }, function(d) { d$members[[1L]]$part <- TRUE; d }, function(d) { d$members[[1L]]$model_id <- "wrong"; d }, function(d) { d$members[[1L]]$mode <- 493L; d })) {
      save_t(mutate(f$logdata), f$logs); expect_error_t(f$restore_logs(), f$out)
    }; save_t(f$logdata, f$logs)
    writeLines(c(readLines(f$manifest), " "), f$manifest); expect_error_t(f$restore_logs(), f$out); save_t(f$data, f$manifest)
  })
  test_t("tar log mode is checked against original 0644", {
    entries <- lapply(names(f$logbodies), function(name) list(name = name, raw = f$logbodies[[name]], mode = 493L)); pack_t(f$logarchive, entries)
    f$logdata$archive$bytes <- as.integer(file.info(f$logarchive)$size); f$logdata$archive$sha256 <- sha_h(f$logarchive); save_t(f$logdata, f$logs); expect_error_t(f$restore_logs(), f$out); f$make_logs()
  })
  test_t("R CLI uses no Python and Make routes the R helpers", {
    tools <- file.path(root, "tools"); dir.create(tools)
    for (name in c("python", "python3")) { p <- file.path(tools, name); writeLines(c("#!/bin/sh", "echo Python-called >&2", "exit 97"), p); Sys.chmod(p, "0755") }
    old <- Sys.getenv("PATH"); Sys.setenv(PATH = paste(tools, old, sep = .Platform$path.sep))
    output <- system2(file.path(R.home("bin"), "Rscript"), shQuote(c(file.path(here, "hessian.R"), "--manifest", f$manifest, "--case", "Case-A", "--out", f$out)), stdout = TRUE, stderr = TRUE)
    stopifnot(is.null(attr(output, "status")), dir.exists(f$out)); unlink(f$out, recursive = TRUE)
    output <- system2(file.path(R.home("bin"), "Rscript"), shQuote(c(file.path(here, "native_logs.R"), "--manifest", f$logs, "--hessians", f$manifest, "--out", f$out)), stdout = TRUE, stderr = TRUE)
    stopifnot(is.null(attr(output, "status")), dir.exists(f$out)); Sys.setenv(PATH = old)
    text <- readLines(file.path(dirname(here), "Makefile")); stopifnot(any(grepl("$(RSCRIPT) reproduce/hessian.R", text, fixed = TRUE)), any(grepl("$(RSCRIPT) reproduce/native_logs.R", text, fixed = TRUE)))
  })
  cat("Passed ", count, " offline R archive checks; no MFCL or downloads.\n", sep = "")
}, finally = unlink(root, recursive = TRUE))
