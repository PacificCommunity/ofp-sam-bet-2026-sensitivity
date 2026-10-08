#!/usr/bin/env Rscript
# Restore/check original saved Hessians with base R; never execute MFCL.
options(stringsAsFactors = FALSE)
require_h <- function(x, message) if (!isTRUE(x)) stop(message, call. = FALSE)
linked_h <- function(p) { x <- Sys.readlink(p); !is.na(x) && nzchar(x) }
path_h <- function(p) {
  require_h(is.character(p) && length(p) == 1L && startsWith(p, "/") &&
              !any(strsplit(substring(p, 2L), "/", fixed = TRUE)[[1L]] %in% c("", ".", "..")), paste("Use an absolute canonical path:", p))
  ancestor <- p
  repeat {
    # macOS exposes these system directories through fixed aliases.
    alias <- Sys.info()[["sysname"]] == "Darwin" && ancestor %in% c("/tmp", "/var") &&
      identical(Sys.readlink(ancestor), paste0("/private", ancestor))
    require_h(!linked_h(ancestor) || alias, paste("Symbolic path component:", ancestor))
    if (ancestor == "/") break
    ancestor <- dirname(ancestor)
  }
  p
}
regular_h <- function(p) {
  path_h(p); i <- file.info(p)
  require_h(nrow(i) == 1L && !is.na(i$isdir) && !i$isdir && file_test("-f", p) && !linked_h(p), paste("Expected a regular file:", p))
  i
}
identity_h <- function(info) info[, intersect(c("size", "isdir", "mode", "mtime", "ctime", "uid", "gid"), names(info)), drop = FALSE]
command_h <- function(program, args) {
  executable <- Sys.which(program)
  require_h(nzchar(executable), paste("Required command unavailable:", program))
  out <- suppressWarnings(system2(executable, shQuote(args), stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  require_h(is.null(status) || status == 0L, paste(program, "failed:", paste(out, collapse = "\n")))
  out
}
stat_h <- function(paths) {
  format <- if (Sys.info()[["sysname"]] == "Darwin") c("-f", "%d:%i") else c("-c", "%d:%i", "--")
  ids <- command_h("stat", c(format, paths))
  require_h(length(ids) == length(paths) && all(grepl("^[0-9]+:[0-9]+$", ids)), "Invalid stat device/inode output")
  setNames(ids, paths)
}
directory_ids_h <- function(paths) {
  require_h(all(vapply(paths, function(p) !linked_h(p) && dir.exists(p), logical(1))), "Expected original regular directories")
  stat_h(paths)
}
ancestors_h <- function(p) {
  paths <- p
  while (p != "/") { p <- dirname(p); paths <- c(paths, p) }
  rev(paths)
}
check_directories_h <- function(pins, current = NULL) {
  require_h(identical(directory_ids_h(names(pins)), pins), "Output or parent directory changed")
  if (!is.null(current)) require_h(unname(directory_ids_h(".")) == pins[[current]], "Current output directory changed")
}
enter_directory_h <- function(path, pins) {
  check_directories_h(pins)
  setwd(path)
  check_directories_h(pins, path)
}
stage_h <- function(from, to, relative = TRUE) {
  if (relative) require_h(safe_h(to) && !grepl("/", to, fixed = TRUE), "Stage destination must be a relative leaf") else path_h(to)
  input <- file(from, "rb"); on.exit(close(input), add = TRUE)
  mask <- Sys.umask("0077"); on.exit(Sys.umask(mask), add = TRUE)
  # libc exclusive creation refuses existing leaves, including dangling symlinks.
  # The trailing b keeps the R connection binary; retain this opened descriptor.
  output <- file(to, "wxb"); on.exit(close(output), add = TRUE)
  repeat {
    block <- readBin(input, "raw", n = 1024L * 1024L)
    if (!length(block)) break
    writeBin(block, output)
  }
  invisible(TRUE)
}
release_url_h <- function(url) {
  require_h(text_h(url, 8192L) && !grepl("[[:space:]#]", url) &&
              grepl("^https://(github\\.com|release-assets\\.githubusercontent\\.com|objects\\.githubusercontent\\.com)(:443)?([/?].*)?$", url, ignore.case = TRUE), "Unexpected archive redirect destination")
  url
}
redirect_url_h <- function(base, location) {
  require_h(text_h(location, 8192L) && !grepl("[[:space:]#]", location), "Invalid archive redirect location")
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*:", location)) return(release_url_h(location))
  if (startsWith(location, "//")) return(release_url_h(paste0("https:", location)))
  origin <- regmatches(base, regexpr("^https://[^/?#]+", base, ignore.case = TRUE))
  path <- substring(base, nchar(origin) + 1L); if (!nzchar(path) || startsWith(path, "?")) path <- paste0("/", path)
  if (startsWith(location, "/")) next_url <- paste0(origin, location)
  else if (startsWith(location, "?")) next_url <- paste0(origin, sub("\\?.*$", "", path), location)
  else next_url <- paste0(origin, dirname(sub("\\?.*$", "", path)), "/", location)
  release_url_h(next_url)
}
request_h <- function(url, headers, body, maximum, timeout) {
  # Never follow a Location automatically; the caller validates each destination.
  command_h("curl", c("--disable", "--fail", "--silent", "--show-error", "--globoff", "--proto", "=https", "--max-redirs", "0", "--max-time", as.character(timeout), "--max-filesize", as.character(maximum), "--dump-header", headers, "--output", body, "--write-out", "%{http_code}", "--", release_url_h(url)))
}
download_h <- function(url, destination, maximum) {
  path_h(destination)
  require_h(is.numeric(maximum) && length(maximum) == 1L && is.finite(maximum) && maximum > 0 && maximum <= 512 * 1024^2 && maximum == floor(maximum), "Invalid download byte bound")
  require_h(!file.exists(destination) && !linked_h(destination), "Download destination already exists")
  scratch <- tempfile("bet-download-", tmpdir = normalizePath(tempdir(), mustWork = TRUE))
  require_h(dir.create(scratch, mode = "0700"), "Cannot create private download directory")
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  headers <- file.path(scratch, "headers"); body <- file.path(scratch, "body"); visited <- character(); start <- proc.time()[["elapsed"]]
  for (attempt in 0:10) {
    release_url_h(url)
    require_h(!url %in% visited, "Archive redirect loop")
    visited <- c(visited, url); remaining <- 600 - (proc.time()[["elapsed"]] - start)
    require_h(remaining > 0, "Archive download deadline exceeded")
    status <- request_h(url, headers, body, maximum, remaining)
    require_h(length(status) == 1L && grepl("^[0-9]{3}$", status) && regular_h(headers)$size <= 65536L, "Invalid HTTP response status/headers")
    lines <- sub("\r$", "", readLines(headers, warn = FALSE)); responses <- which(grepl("^HTTP/[0-9.]+ [0-9]{3}([[:space:]]|$)", lines))
    require_h(length(responses) > 0L, "Missing HTTP response headers")
    last <- tail(responses, 1L); code <- as.integer(status)
    require_h(as.integer(sub("^HTTP/[0-9.]+ ([0-9]{3}).*$", "\\1", lines[last])) == code, "HTTP response status differs")
    if (code >= 200L && code < 300L) {
      require_h(regular_h(body)$size == maximum && stage_h(body, destination, relative = FALSE), "Downloaded archive bytes differ or destination exists")
      require_h(regular_h(destination)$size == maximum && sha_h(destination) == sha_h(body), "Copied download differs")
      return(invisible(destination))
    }
    require_h(code %in% c(301L, 302L, 303L, 307L, 308L) && attempt < 10L, "Unsupported or excessive archive redirects")
    block <- lines[seq.int(last + 1L, length(lines))]; locations <- block[grepl("^Location:", block, ignore.case = TRUE)]
    require_h(length(locations) == 1L, "Missing or duplicate archive redirect location")
    url <- redirect_url_h(url, trimws(sub("^[^:]+:", "", locations)))
  }
}
sha_h <- function(p) {
  regular_h(p)
  tool <- if (nzchar(Sys.which("sha256sum"))) "sha256sum" else "shasum"
  out <- command_h(tool, c(if (tool == "shasum") c("-a", "256"), "--", p))
  require_h(length(out) == 1L && grepl("^[0-9a-f]{64}[[:space:]]", out), "Invalid SHA256 output")
  substr(out, 1L, 64L)
}
# A bounded data parser, adapted from the diagnostic base-R reader. No code is evaluated.
json_h <- function(path) {
  before <- regular_h(path)
  require_h(before$size <= 2 * 1024^2, "Manifest exceeds 2 MiB")
  text <- paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  require_h(identical(identity_h(before), identity_h(regular_h(path))), "Manifest changed while reading")
  chars <- strsplit(text, "", fixed = TRUE)[[1L]]; at <- 1L; size <- length(chars)
  skip <- function() { while (at <= size && chars[at] %in% c(" ", "\n", "\r", "\t")) at <<- at + 1L }
  string <- function() {
    require_h(at <= size && chars[at] == '"', "Expected JSON string")
    at <<- at + 1L; result <- character()
    repeat {
      require_h(at <= size, "Truncated JSON string")
      ch <- chars[at]; at <<- at + 1L
      if (ch == '"') return(paste(result, collapse = ""))
      require_h(utf8ToInt(ch) >= 32L, "JSON string contains a control character")
      if (ch == "\\") {
        require_h(at <= size, "Truncated JSON escape")
        escape <- chars[at]; at <<- at + 1L
        if (escape == "u") {
          require_h(at + 3L <= size, "Truncated JSON Unicode escape")
          digits <- paste(chars[at:(at + 3L)], collapse = "")
          require_h(grepl("^[0-9A-Fa-f]{4}$", digits), "Invalid JSON Unicode escape")
          code <- strtoi(digits, 16L); at <<- at + 4L
          require_h(code > 0L && !(code >= 55296L && code <= 57343L), "Unsupported Unicode in metadata")
          ch <- intToUtf8(code)
        } else {
          translations <- c('"' = '"', "\\" = "\\", "/" = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t")
          require_h(escape %in% names(translations), "Invalid JSON escape")
          ch <- translations[[escape]]
        }
      }
      result <- c(result, ch)
    }
  }
  value <- function(depth = 0L) {
    require_h(depth <= 16L, "Excessive JSON nesting"); skip()
    require_h(at <= size, "Truncated JSON value")
    ch <- chars[at]
    if (ch == '"') return(string())
    if (ch %in% c("{", "[")) {
      object <- ch == "{"; closing <- if (object) "}" else "]"
      at <<- at + 1L; skip()
      out <- structure(list(), class = if (object) "json_object_h" else "json_array_h")
      if (at <= size && chars[at] == closing) { at <<- at + 1L; return(out) }
      repeat {
        skip()
        if (object) {
          key <- string(); require_h(!key %in% names(out), "Duplicate JSON key"); skip()
          require_h(at <= size && chars[at] == ":", "Missing JSON colon"); at <<- at + 1L
          out[key] <- list(value(depth + 1L))
        } else out[length(out) + 1L] <- list(value(depth + 1L))
        skip(); require_h(at <= size, "Truncated JSON container")
        ch <- chars[at]; at <<- at + 1L
        if (ch == closing) return(out)
        require_h(ch == ",", "Missing JSON comma")
      }
    }
    start <- at
    while (at <= size && !chars[at] %in% c(" ", "\n", "\r", "\t", ",", "}", "]")) at <<- at + 1L
    require_h(at > start, "Invalid JSON value")
    token <- paste(chars[start:(at - 1L)], collapse = "")
    if (token %in% c("true", "false", "null")) return(switch(token, true = TRUE, false = FALSE, null = NULL))
    require_h(grepl("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", token), "Invalid JSON number")
    number <- as.numeric(token); require_h(is.finite(number), "Nonfinite JSON number")
    if (grepl("^-?[0-9]+$", token) && abs(number) <= .Machine$integer.max) as.integer(number) else number
  }
  result <- value(); skip(); require_h(at > size, "Extra JSON data"); result
}
object_h <- function(x) inherits(x, "json_object_h")
array_h <- function(x) inherits(x, "json_array_h")
keys_h <- function(x, required, optional = character()) {
  require_h(object_h(x) && all(required %in% names(x)) && all(names(x) %in% c(required, optional)), "Missing or unknown manifest field")
}
text_h <- function(x, maximum = 128L) is.character(x) && length(x) == 1L && nchar(x) > 0L && nchar(x) <= maximum && !grepl("[[:cntrl:]]", x)
hash_h <- function(x) is.character(x) && length(x) == 1L && grepl("^[0-9a-f]{64}$", x)
integer_h <- function(x, maximum = 512 * 1024^2) is.integer(x) && length(x) == 1L && !is.na(x) && x >= 0L && x <= maximum
safe_h <- function(p) {
  if (!text_h(p, 240L) || startsWith(p, "/")) return(FALSE)
  parts <- strsplit(p, "/", fixed = TRUE)[[1L]]
  length(parts) <= 8L && !endsWith(p, "/") && all(!parts %in% c("", ".", "..")) &&
    all(nchar(parts) <= 128L) && all(grepl("^[A-Za-z0-9._-]+$", parts))
}
paths_h <- function(paths) {
  folded <- tolower(paths)
  require_h(!is.null(paths) && all(vapply(paths, safe_h, logical(1))) && !anyDuplicated(folded), "Invalid or colliding member paths")
  for (p in folded) require_h(!any(startsWith(setdiff(folded, p), paste0(p, "/"))), "Member path collision")
}
archive_pin_h <- function(archive, repository) {
  require_h(object_h(archive) && xor("url" %in% names(archive), "relative_path" %in% names(archive)), "Archive requires exactly one fixed source")
  source <- if ("url" %in% names(archive)) "url" else "relative_path"
  keys_h(archive, c(source, "bytes", "sha256"))
  require_h(integer_h(archive$bytes) && archive$bytes > 0L && hash_h(archive$sha256), "Invalid archive pin")
  if (source == "url") {
    prefix <- paste0("https://github.com/", repository, "/releases/download/")
    require_h(text_h(archive$url, 512L) && startsWith(archive$url, prefix) &&
                grepl("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.tar\\.gz$", substring(archive$url, nchar(prefix) + 1L)) &&
                safe_h(substring(archive$url, nchar(prefix) + 1L)), "Invalid fixed release URL")
  } else require_h(safe_h(archive$relative_path) && endsWith(archive$relative_path, ".tar.gz"), "Invalid relative archive path")
}
header_bytes_h <- function(hex) {
  require_h(is.character(hex) && length(hex) == 1L && grepl("^([0-9a-f]{2}){1,64}$", hex), "Invalid original header bytes")
  as.raw(strtoi(substring(hex, seq.int(1L, nchar(hex), 2L), seq.int(2L, nchar(hex), 2L)), 16L))
}
parts_h <- function(row) {
  parts <- row$hessian_parts
  require_h(array_h(parts) && length(parts) >= 1L && length(parts) <= 63L, "Invalid native Hessian parts")
  next_row <- 1L; dimension <- NULL; seen <- character()
  for (part in parts) {
    keys_h(part, c("path", "n_parameter", "row_bounds", "bytes_hex", "sha256"))
    require_h(safe_h(part$path) && grepl("/bet\\.hes$", part$path) && part$path %in% names(row$members) && !part$path %in% seen, "Missing, duplicate or invalid part path")
    seen <- c(seen, part$path); n <- part$n_parameter; bounds <- part$row_bounds
    require_h(integer_h(n, 100000L) && n > 0L, "Invalid Hessian part dimension")
    if (is.null(dimension)) dimension <- n
    require_h(identical(n, dimension) && array_h(bounds) && length(bounds) == 2L && all(vapply(bounds, integer_h, logical(1), maximum = n)), "Hessian part dimensions/rows differ")
    start <- bounds[[1L]]; end <- bounds[[2L]]
    require_h(start == next_row && start <= end, "Part rows must cover ordered 1..n")
    next_row <- end + 1L
    raw <- header_bytes_h(part$bytes_hex)
    require_h(length(raw) == 12L && identical(readBin(raw, "integer", n = 3L, size = 4L, endian = "little"), c(n, start, end)), "Native part header disagrees with row bounds")
    pin <- row$members[[part$path]]
    require_h(hash_h(part$sha256) && part$sha256 == pin$sha256 && pin$bytes == 12 + 8 * n * (end - start + 1), "Part source hash or byte layout differs")
  }
  require_h(next_row == dimension + 1L && setequal(seen, names(row$members)[basename(names(row$members)) == "bet.hes"]), "Incomplete or unlisted native Hessian parts")
}
read_manifest_h <- function(path) {
  data <- json_h(path); keys_h(data, c("cases", "classification", "repository", "schema_version"))
  require_h(identical(data$schema_version, 1L) && identical(data$classification, "PUBLIC") &&
              text_h(data$repository) && grepl("^PacificCommunity/ofp-sam-bet-2026-[a-z][a-z0-9-]*$", data$repository), "Invalid Hessian manifest schema")
  cases <- data$cases
  require_h(object_h(cases) && length(cases) >= 1L && length(cases) <= 512L && !is.null(names(cases)), "Invalid Hessian case index")
  for (case in names(cases)) {
    require_h(grepl("^[a-z0-9][a-z0-9._-]{0,63}$", case), "Invalid Hessian case name")
    row <- cases[[case]]; kind <- if ("kind" %in% names(row)) row$kind else "matrix"
    require_h(is.character(kind) && length(kind) == 1L && kind %in% c("matrix", "native_parts"), "Invalid Hessian kind")
    common <- c("model_id", "pdh_status", "final_par_sha256", "archive", "members")
    if (kind == "matrix") keys_h(row, c(common, "hessian_sha256"), c("kind", "report_id", "report_label", "hessian_header"))
    else keys_h(row, c(common, "kind", "hessian_parts"), c("report_id", "report_label"))
    require_h(text_h(row$model_id) && text_h(row$pdh_status, 32L), "Invalid model/status metadata")
    for (field in intersect(c("report_id", "report_label"), names(row))) require_h(text_h(row[[field]]), "Invalid report metadata")
    archive_pin_h(row$archive, data$repository)
    members <- row$members
    require_h(object_h(members) && length(members) >= 2L && length(members) <= 64L && "final.par" %in% names(members), "Invalid Hessian members")
    require_h((kind == "matrix") == ("bet.hes" %in% names(members)), "Matrix/part member layout differs")
    paths_h(names(members))
    for (pin in members) {
      keys_h(pin, c("bytes", "sha256"))
      require_h(integer_h(pin$bytes) && hash_h(pin$sha256), "Invalid Hessian member pin")
    }
    require_h(sum(vapply(members, function(x) x$bytes, numeric(1))) <= 1024^3 && hash_h(row$final_par_sha256) && row$final_par_sha256 == members$final.par$sha256, "Hessian total/final PAR pins differ")
    if (kind == "native_parts") parts_h(row) else require_h(hash_h(row$hessian_sha256) && row$hessian_sha256 == members$bet.hes$sha256, "Hessian scientific/member pins differ")
    if ("hessian_header" %in% names(row)) {
      header <- row$hessian_header; keys_h(header, c("bytes_hex", "n_parameter"), "row_bounds")
      header_bytes_h(header$bytes_hex)
      require_h(integer_h(header$n_parameter, 100000L) && header$n_parameter > 0L, "Invalid matrix dimensions")
      if ("row_bounds" %in% names(header)) require_h(array_h(header$row_bounds) && length(header$row_bounds) == 2L && all(vapply(header$row_bounds, integer_h, logical(1), maximum = 100000L)), "Invalid matrix rows")
    }
  }
  data
}
# Read regular USTAR records directly, with bounded streaming decompression.
# Extension records, links, directory entries, duplicate and unlisted paths fail.
validate_archive_h <- function(archive, entry, scratch) {
  mask <- Sys.umask("0077"); on.exit(Sys.umask(mask), add = TRUE)
  before <- regular_h(archive)
  require_h(before$size == entry$archive$bytes && sha_h(archive) == entry$archive$sha256, "Archive bytes/hash differ")
  compressed <- file(archive, "rb")
  magic <- tryCatch(readBin(compressed, "raw", n = 4L), finally = close(compressed))
  require_h(length(magic) == 4L && identical(magic[1:3], as.raw(c(31L, 139L, 8L))) && bitwAnd(as.integer(magic[4L]), 224L) == 0L, "Archive must be a gzip container")
  stream <- gzfile(archive, "rb"); on.exit(close(stream), add = TRUE)
  count <- 0; limit <- sum(vapply(entry$members, function(x) x$bytes, numeric(1))) + 1024^2
  read <- function(n) {
    raw <- withCallingHandlers(readBin(stream, "raw", n = n), warning = function(w) stop(conditionMessage(w), call. = FALSE))
    count <<- count + length(raw); require_h(count <= limit, "Excessive expanded tar bytes"); raw
  }
  field <- function(raw, start, width) {
    x <- raw[start:(start + width - 1L)]; null <- which(x == as.raw(0L))
    if (length(null)) { require_h(all(x[null[1L]:length(x)] == as.raw(0L)), "Malformed tar text field"); x <- x[seq_len(null[1L] - 1L)] }
    if (length(x)) rawToChar(x) else ""
  }
  octal <- function(raw, start, width) {
    x <- raw[start:(start + width - 1L)]; x <- x[x != as.raw(0L)]; text <- trimws(rawToChar(x))
    require_h(nzchar(text) && grepl("^[0-7]+$", text), "Invalid tar numeric field")
    digits <- utf8ToInt(text) - 48L; sum(digits * 8^rev(seq_along(digits) - 1L))
  }
  seen <- character()
  repeat {
    header <- read(512L); require_h(length(header) == 512L, "Truncated tar header")
    if (all(header == as.raw(0L))) {
      end <- read(512L); require_h(length(end) == 512L && all(end == as.raw(0L)), "Missing tar end blocks")
      repeat { trailer <- read(1024L * 1024L); if (!length(trailer)) break; require_h(all(trailer == as.raw(0L)), "Extra tar trailer data") }
      break
    }
    checksum <- octal(header, 149L, 8L); checked <- header; checked[149:156] <- charToRaw("        ")
    require_h(checksum == sum(as.integer(checked)), "Tar header checksum differs")
    name <- field(header, 1L, 100L); prefix <- field(header, 346L, 155L)
    if (nzchar(prefix)) name <- paste0(prefix, "/", name)
    require_h(safe_h(name) && name %in% names(entry$members) && !name %in% seen, "Tar member roster/path differs")
    require_h(header[157L] %in% as.raw(c(0L, 48L)) && !nzchar(field(header, 158L, 100L)), "Tar member must be a regular file without a link")
    pin <- entry$members[[name]]
    require_h(octal(header, 125L, 12L) == pin$bytes, "Tar member size differs")
    if (!is.null(pin$mode)) require_h(octal(header, 101L, 8L) == pin$mode, "Tar original mode differs")
    seen <- c(seen, name); target <- file.path(scratch, name)
    if (!dir.exists(dirname(target))) require_h(dir.create(dirname(target), recursive = TRUE, mode = "0700"), "Cannot create scratch member directory")
    require_h(!file.exists(target) && !linked_h(target), "Scratch target already exists")
    handle <- file(target, "wxb"); remaining <- pin$bytes
    tryCatch({
      while (remaining > 0) {
        block <- read(min(remaining, 1024L * 1024L)); require_h(length(block) > 0L, "Truncated tar member")
        writeBin(block, handle); remaining <- remaining - length(block)
      }
    }, finally = close(handle))
    Sys.chmod(target, "0600")
    padding <- (512L - pin$bytes %% 512L) %% 512L
    pad <- read(padding); require_h(length(pad) == padding && all(pad == as.raw(0L)), "Invalid tar padding")
    require_h(regular_h(target)$size == pin$bytes && sha_h(target) == pin$sha256, paste("Member bytes/hash differ:", name))
  }
  require_h(setequal(seen, names(entry$members)) && identical(identity_h(before), identity_h(regular_h(archive))) && sha_h(archive) == entry$archive$sha256, "Archive roster or source changed")
  headers <- if (!is.null(entry$hessian_parts)) setNames(lapply(entry$hessian_parts, function(p) p$bytes_hex), vapply(entry$hessian_parts, function(p) p$path, character(1))) else if (!is.null(entry$hessian_header)) list(bet.hes = entry$hessian_header$bytes_hex) else list()
  for (name in names(headers)) {
    expected <- header_bytes_h(headers[[name]]); handle <- file(file.path(scratch, name), "rb")
    actual <- tryCatch(readBin(handle, "raw", n = length(expected)), finally = close(handle))
    require_h(identical(actual, expected), "Original Hessian header bytes differ")
  }
}
output_h <- function(raw, roots) {
  path_h(raw); require_h(!file.exists(raw) && !dir.exists(raw) && !linked_h(raw), "OUT already exists; choose a new directory")
  parent <- normalizePath(dirname(raw), mustWork = TRUE)
  require_h(dir.exists(parent) && !basename(raw) %in% c("", ".", ".."), "Invalid OUT parent/name")
  output <- file.path(parent, basename(raw)); roots <- unique(normalizePath(roots, mustWork = TRUE))
  require_h(!any(vapply(roots, function(root) output == root || startsWith(output, paste0(root, "/")) || startsWith(root, paste0(output, "/")), logical(1))), "OUT must be outside the repository and its ancestors")
  output
}
restore_h <- function(entry, manifest, out = NULL, archive = NULL, roots = dirname(dirname(manifest))) {
  output <- if (is.null(out)) NULL else output_h(out, roots)
  pins <- if (is.null(output)) NULL else directory_ids_h(ancestors_h(dirname(output)))
  scratch <- tempfile("bet-saved-", tmpdir = normalizePath(tempdir(), mustWork = TRUE))
  require_h(dir.create(scratch, mode = "0700"), "Cannot create scratch directory")
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  if (!is.null(archive)) regular_h(archive)
  packed <- if (!is.null(archive)) normalizePath(archive, mustWork = TRUE) else if (!is.null(entry$archive$relative_path)) file.path(dirname(manifest), entry$archive$relative_path) else file.path(scratch, "archive.tar.gz")
  if (is.null(archive) && is.null(entry$archive$relative_path)) download_h(entry$archive$url, packed, entry$archive$bytes)
  extracted <- file.path(scratch, "members"); require_h(dir.create(extracted, mode = "0700"), "Cannot create extraction directory")
  validate_archive_h(packed, entry, extracted)
  if (!is.null(output)) {
    output_h(out, roots)
    previous <- getwd(); on.exit(try(setwd(previous), silent = TRUE), add = TRUE)
    # Relative mutations stay attached to the original cwd through directory renames.
    # Device/inode checks detect path replacement; these are not descriptor race guarantees.
    enter_directory_h(dirname(output), pins)
    require_h(dir.create(basename(output), mode = "0700"), "Cannot reserve fresh OUT")
    check_directories_h(pins)
    pins <- c(pins, directory_ids_h(output)); enter_directory_h(output, pins)
    for (name in names(entry$members)) {
      enter_directory_h(output, pins); parent <- output
      components <- strsplit(name, "/", fixed = TRUE)[[1L]]
      for (component in head(components, -1L)) {
        child <- file.path(parent, component)
        if (!child %in% names(pins)) {
          check_directories_h(pins, parent)
          require_h(!file.exists(component) && !linked_h(component) && dir.create(component, mode = "0700"), "Cannot reserve new member directory")
          check_directories_h(pins, parent); pins <- c(pins, directory_ids_h(child))
        }
        enter_directory_h(child, pins); parent <- child
      }
      leaf <- tail(components, 1L); target <- file.path(parent, leaf)
      check_directories_h(pins, parent)
      require_h(!file.exists(leaf) && !linked_h(leaf), "Output member already exists")
      temporary <- basename(tempfile(".bet-member-", tmpdir = parent))
      require_h(stage_h(file.path(extracted, name), temporary), "Cannot stage member")
      check_directories_h(pins, parent)
      staged <- file.path(parent, temporary); pin <- entry$members[[name]]
      require_h(regular_h(staged)$size == pin$bytes && sha_h(staged) == pin$sha256, "Staged member differs")
      staged_id <- unname(stat_h(staged)); check_directories_h(pins, parent)
      # A hard link publishes the leaf exclusively on the same filesystem.
      require_h(file.link(temporary, leaf), "Cannot publish exclusive member")
      check_directories_h(pins, parent)
      require_h(unname(stat_h(target)) == staged_id, "Published member identity differs")
      require_h(regular_h(target)$size == pin$bytes && sha_h(target) == pin$sha256, "Copied member differs")
      require_h(unname(stat_h(staged)) == staged_id, "Staged member changed")
      unlink(temporary); check_directories_h(pins, parent)
    }
    check_directories_h(pins)
    member_dirs <- names(pins)[names(pins) == output | startsWith(names(pins), paste0(output, "/"))]
    expected <- c(file.path(output, names(entry$members)), setdiff(member_dirs, output))
    for (parent in member_dirs) {
      enter_directory_h(parent, pins)
      roster <- list.files(".", all.files = TRUE, no.. = TRUE)
      require_h(setequal(roster, basename(expected[dirname(expected) == parent])), "Unexpected output entry")
    }
    for (name in names(entry$members)) {
      check_directories_h(pins); target <- file.path(output, name); pin <- entry$members[[name]]
      require_h(regular_h(target)$size == pin$bytes && sha_h(target) == pin$sha256, "Final member bytes/hash differ")
    }
    check_directories_h(pins)
  }
  invisible(output)
}
args_h <- function(args, allowed) {
  require_h(sum(args == "--verify") <= 1L, "Duplicate --verify")
  verify <- "--verify" %in% args; args <- args[args != "--verify"]
  require_h(length(args) %% 2L == 0L, "Arguments require option/value pairs")
  keys <- if (length(args)) args[seq.int(1L, length(args), 2L)] else character()
  require_h(!anyDuplicated(keys) && all(keys %in% allowed), "Invalid arguments")
  list(verify = verify, values = if (length(args)) setNames(args[seq.int(2L, length(args), 2L)], keys) else character())
}
script_h <- function() {
  script <- commandArgs()[grepl("^--file=", commandArgs())]
  require_h(length(script) == 1L, "Run with Rscript")
  dirname(normalizePath(sub("^--file=", "", script), mustWork = TRUE))
}
main_h <- function(args = commandArgs(trailingOnly = TRUE)) {
  here <- script_h(); parsed <- args_h(args, c("--manifest", "--case", "--out", "--archive")); opts <- parsed$values
  manifest <- if ("--manifest" %in% names(opts)) opts[["--manifest"]] else file.path(here, "hessians.json")
  regular_h(manifest); manifest <- normalizePath(manifest, mustWork = TRUE); data <- read_manifest_h(manifest)
  if (parsed$verify && !any(c("--case", "--out", "--archive") %in% names(opts))) { cat("Saved Hessian manifest verified: ", length(data$cases), " cases; no model run.\n", sep = ""); return(invisible(NULL)) }
  require_h("--case" %in% names(opts), "Choose CASE from hessian-index.csv")
  case <- opts[["--case"]]
  if (!case %in% names(data$cases)) { match <- names(data$cases)[vapply(data$cases, function(x) identical(x$model_id, case), logical(1))]; require_h(length(match) == 1L, "Unknown or ambiguous Hessian case"); case <- match }
  if (parsed$verify) require_h("--archive" %in% names(opts) && !"--out" %in% names(opts), "Archive verification requires CASE and local ARCHIVE without OUT")
  else require_h("--out" %in% names(opts), "Set OUT to a fresh absolute external directory")
  out <- if ("--out" %in% names(opts)) opts[["--out"]] else NULL
  archive <- if ("--archive" %in% names(opts)) opts[["--archive"]] else NULL
  output <- restore_h(data$cases[[case]], manifest, out, archive, roots = c(dirname(here), dirname(dirname(manifest))))
  cat(if (parsed$verify) "Saved Hessian archive verified; no model run.\n" else paste0("Restored exact original Hessian files to ", output, "; no model run.\n"))
}
if (sys.nframe() == 0L) tryCatch(main_h(), error = function(e) { cat(conditionMessage(e), "\n", file = stderr()); quit(status = 1L) })
