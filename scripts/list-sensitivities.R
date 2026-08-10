#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
repo <- normalizePath(file.path(dirname(script), ".."), mustWork = TRUE)
x <- do.call(rbind, lapply(
  file.path(repo, c("sensitivities.csv", "more_tau_sens.csv")),
  function(path) if (file.exists(path)) read.csv(path, stringsAsFactors = FALSE) else NULL
))
for (i in seq_len(nrow(x))) cat(sprintf("  %-25s %s\n", x$key[[i]], x$label[[i]]))
