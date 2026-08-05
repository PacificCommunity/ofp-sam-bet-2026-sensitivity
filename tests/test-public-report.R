options(stringsAsFactors = FALSE)

output_dir <- Sys.getenv("REPORT_OUTPUT_DIR", "results")
html_file <- file.path(output_dir, "bet-2026-sensitivity-report.html")
figure_dir <- file.path(output_dir, "figures")
table_dir <- file.path(output_dir, "tables")

required <- c(
  html_file,
  file.path(output_dir, "bet-2026-sensitivity-interactive-viewer.html"),
  file.path(table_dir, "sensitivity-design-summary.csv"),
  file.path(table_dir, "sensitivity-design-summary.tex"),
  file.path(table_dir, "sensitivity-fit-diagnostics.csv"),
  file.path(table_dir, "sensitivity-fit-diagnostics.tex")
)
if (any(!file.exists(required))) stop("The rendered report is incomplete.", call. = FALSE)

pngs <- list.files(figure_dir, pattern = "[.]png$", full.names = TRUE)
pdfs <- list.files(figure_dir, pattern = "[.]pdf$", full.names = TRUE)
if (length(pngs) != 8L || length(pdfs) != 8L) {
  stop("Expected one PNG and vector PDF for each of eight sensitivity axes.", call. = FALSE)
}
if (any(file.info(c(pngs, pdfs))$size < 10000L)) stop("A report figure is unexpectedly small.", call. = FALSE)

html <- paste(readLines(html_file, warn = FALSE), collapse = "\n")
viewer <- paste(
  readLines(file.path(output_dir, "bet-2026-sensitivity-interactive-viewer.html"), warn = FALSE),
  collapse = "\n"
)
must_have <- c(
  "data:image/png;base64,",
  "Copy figure + caption for Word",
  "Copy figure + caption for LaTeX",
  "Save vector PDF",
  "Copy table for Word",
  "Copy LaTeX",
  "@page{size:A4 landscape",
  "17 one-at-a-time fits",
  "eight sensitivity axes",
  "Fit and Hessian diagnostics",
  "PDH",
  "Reporting rates applied during mixing",
  "τ = 2 (Diagnostic)",
  "Open the interactive viewer"
)
for (value in must_have) {
  if (!grepl(value, html, fixed = TRUE)) stop("Missing report element: ", value, call. = FALSE)
}
if (length(gregexpr("data:image/png;base64,", html, fixed = TRUE)[[1L]]) != 8L) {
  stop("The self-contained report does not embed all eight figures.", call. = FALSE)
}
forbidden <- c("/home/", "corp.spc.int", "ghp_", "github_pat_", "Job 21641")
for (value in forbidden) {
  if (grepl(value, html, fixed = TRUE)) stop("Public report contains forbidden text: ", value, call. = FALSE)
  if (grepl(value, viewer, fixed = TRUE)) stop("Public viewer contains forbidden text: ", value, call. = FALSE)
}
viewer_required <- c(
  "BET 2026 sensitivity model results",
  "viewer-data",
  "metricTabs",
  "modelList",
  "Key quantities",
  "Fit diagnostics",
  "Diagnostic (h = 0.90; τ = 2; K = 0.20",
  "CAAL ESS = 0.75 sub-basin",
  "reporting rates excluded during mixing",
  "τ = 1",
  "Reporting rates applied during mixing"
)
for (value in viewer_required) {
  if (!grepl(value, viewer, fixed = TRUE)) stop("Missing interactive-viewer element: ", value, call. = FALSE)
}
if (grepl("<script[^>]+src=|<link[^>]+href=", viewer, ignore.case = TRUE, perl = TRUE)) {
  stop("The interactive viewer depends on an external script or stylesheet.", call. = FALSE)
}

latex <- paste(readLines(file.path(table_dir, "sensitivity-design-summary.tex"), warn = FALSE), collapse = "\n")
diagnostic_latex <- paste(readLines(file.path(table_dir, "sensitivity-fit-diagnostics.tex"), warn = FALSE), collapse = "\n")
for (value in c("\\begin{table}", "\\begin{tabularx}", "\\toprule", "\\bottomrule")) {
  if (!grepl(value, latex, fixed = TRUE) || !grepl(value, diagnostic_latex, fixed = TRUE)) {
    stop("Malformed LaTeX table output.", call. = FALSE)
  }
}

diagnostics <- utils::read.csv(file.path(table_dir, "sensitivity-fit-diagnostics.csv"), check.names = FALSE)
if (nrow(diagnostics) != 17L || any(diagnostics$PDH != "Yes")) {
  stop("The rendered fit/Hessian diagnostics table is incomplete.", call. = FALSE)
}
tau_rows <- diagnostics[grepl("^τ = ", diagnostics$Fit), "Fit"]
if (!identical(tau_rows, c("τ = 1", "τ = 1.2", "τ = 1.4", "τ = 1.6", "τ = 1.8"))) {
  stop("The τ sensitivity rows are not in ascending order.", call. = FALSE)
}

cat("Validated self-contained A4 sensitivity report, interactive viewer, eight figure sets and two copy-ready table outputs.\n")
