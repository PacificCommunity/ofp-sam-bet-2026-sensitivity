#!/usr/bin/env Rscript

status <- system2("Rscript", file.path("scripts", "validate-more-tau-viewer.R"))
if (!identical(status, 0L)) stop("More-tau viewer validation failed.", call. = FALSE)
