#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
repo <- normalizePath(file.path(dirname(script), ".."), mustWork = TRUE)
x <- read.csv(file.path(repo, "sensitivities.csv"), stringsAsFactors = FALSE)
for (i in seq_len(nrow(x))) cat(sprintf("  %-25s %s\n", x$key[[i]], x$label[[i]]))
