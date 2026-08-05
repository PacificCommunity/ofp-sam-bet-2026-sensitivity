viewer_model_keys <- c(design$key, "diagnostic")
viewer_model_labels <- c(
  mapply(public_label, design$key, design$label, USE.NAMES = FALSE),
  "Diagnostic"
)
viewer_model_colours <- c(
  grDevices::hcl.colors(nrow(design), palette = "Dynamic"),
  diagnostic_colour
)

viewer_label_by_key <- stats::setNames(viewer_model_labels, viewer_model_keys)
viewer_series <- series[series$key %in% viewer_model_keys, , drop = FALSE]
viewer_series$model <- unname(viewer_label_by_key[viewer_series$key])
if (anyNA(viewer_series$model)) {
  stop("The sensitivity viewer contains an unmapped model key.", call. = FALSE)
}

viewer_metric_specs <- data.frame(
  column = c(
    "depletion", "recruitment", "spawning_potential", "fishing_mortality"
  ),
  metric_key = c(
    "depletion", "recruitment", "spawning_potential", "fishing_mortality"
  ),
  metric_label = c(
    "Dynamic spawning depletion", "Recruitment", "Spawning potential",
    "Fishing mortality"
  ),
  y_label = c(
    "SB/SB[F=0]", "Recruitment (millions)",
    "Spawning potential (10^3 MT)", "F (year^-1)"
  ),
  stringsAsFactors = FALSE
)

viewer_key_records <- do.call(
  rbind,
  lapply(seq_len(nrow(viewer_metric_specs)), function(index) {
    spec <- viewer_metric_specs[index, , drop = FALSE]
    data.frame(
      model = viewer_series$model,
      region = "All",
      year = as.integer(viewer_series$year),
      x = as.integer(viewer_series$year),
      source = "Value",
      value = round(viewer_series[[spec$column]], 9),
      metric_key = spec$metric_key,
      metric_label = spec$metric_label,
      y_label = spec$y_label,
      x_label = "Year",
      stringsAsFactors = FALSE
    )
  })
)

viewer_axis_by_key <- stats::setNames(
  unname(axis_display_label[design$axis]),
  design$key
)
viewer_fit_labels <- unname(viewer_label_by_key[fit_diagnostics$key])
viewer_fit_table <- data.frame(
  Model = viewer_fit_labels,
  Axis = unname(viewer_axis_by_key[fit_diagnostics$key]),
  MGC = fit_diagnostics$maximum_gradient_component,
  `Objective value` = fit_diagnostics$objective_function,
  PDH = ifelse(fit_diagnostics$positive_definite_hessian, "Yes", "No"),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

viewer_payload <- list(
  title = "BET 2026 sensitivity model results",
  generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  models = data.frame(
    key = viewer_model_keys,
    label = viewer_model_labels,
    color = viewer_model_colours,
    stringsAsFactors = FALSE
  ),
  metrics = list(
    list(
      key = "key_quantities",
      label = "Key quantities",
      kind = "key_quantities",
      records = viewer_key_records
    ),
    list(
      key = "model_summary",
      label = "Fit diagnostics",
      kind = "table",
      records = viewer_fit_table,
      columns = names(viewer_fit_table)
    )
  ),
  regions = "All"
)

viewer_json <- jsonlite::toJSON(
  viewer_payload,
  auto_unbox = TRUE,
  dataframe = "columns",
  null = "null",
  digits = 9,
  na = "null",
  pretty = FALSE
)
viewer_json <- gsub("</", "<\\/", viewer_json, fixed = TRUE)

viewer_template_file <- file.path("report", "interactive-viewer-template.html")
if (!file.exists(viewer_template_file)) {
  stop("Missing the checksum-independent interactive-viewer template.", call. = FALSE)
}
viewer_template <- paste(readLines(viewer_template_file, warn = FALSE), collapse = "\n")
viewer_markers <- gregexpr("__VIEWER_DATA__", viewer_template, fixed = TRUE)[[1L]]
if (sum(viewer_markers >= 0L) != 1L) {
  stop("The interactive-viewer template must contain one payload marker.", call. = FALSE)
}
viewer_html <- sub("__VIEWER_DATA__", viewer_json, viewer_template, fixed = TRUE)

viewer_file <- file.path(output_dir, "bet-2026-sensitivity-interactive-viewer.html")
writeLines(viewer_html, viewer_file, useBytes = TRUE)
