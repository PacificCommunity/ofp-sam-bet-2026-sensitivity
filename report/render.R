options(stringsAsFactors = FALSE)

required_packages <- c("ggplot2", "patchwork", "jsonlite", "ragg", "scales")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages)) {
  stop("Install public report dependencies: ", paste(missing_packages, collapse = ", "), call. = FALSE)
}

series <- readRDS("data/sensitivity/sensitivity-timeseries.rds")
design <- utils::read.csv("data/sensitivity/sensitivity-design.csv", check.names = FALSE)
fit_diagnostics <- utils::read.csv(
  "data/sensitivity/sensitivity-fit-diagnostics.csv",
  check.names = FALSE
)
output_dir <- Sys.getenv("REPORT_OUTPUT_DIR", "results")
figure_dir <- file.path(output_dir, "figures")
table_dir <- file.path(output_dir, "tables")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)

theme_report <- function(base_size = 11.2) {
  ggplot2::theme_bw(base_size = base_size, base_family = "serif") +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(colour = "#E2E8EC", linewidth = 0.28),
      panel.border = ggplot2::element_rect(colour = "#263238", fill = NA, linewidth = 0.45),
      axis.title = ggplot2::element_text(face = "bold", colour = "#172B3A"),
      axis.text = ggplot2::element_text(colour = "#334E5C"),
      legend.position = "bottom",
      legend.title = ggplot2::element_blank(),
      legend.key.width = grid::unit(1.20, "cm"),
      plot.tag = ggplot2::element_text(face = "bold", colour = "#172B3A"),
      plot.margin = ggplot2::margin(7, 10, 7, 8)
    )
}

metric_specs <- list(
  list(column = "depletion", label = bquote(italic(SB) / italic(SB)[italic(F) == 0]), lrp = TRUE),
  list(column = "recruitment", label = "Recruitment (millions)", lrp = FALSE),
  list(column = "spawning_potential", label = bquote(Spawning~potential~(10^3~plain(MT))), lrp = FALSE),
  list(column = "fishing_mortality", label = bquote(italic(F)~(year^{-1})), lrp = FALSE)
)

axis_palette <- c("#0072B2", "#009E73", "#E69F00", "#6F42C1", "#CC79A7")
diagnostic_colour <- "#C62828"

slugify <- function(value) {
  value <- tolower(gsub("[^A-Za-z0-9]+", "-", value))
  gsub("(^-|-$)", "", value)
}

latex_escape <- function(value) {
  value <- gsub("–", "--", value, fixed = TRUE)
  value <- gsub("—", "---", value, fixed = TRUE)
  value <- gsub("−", "-", value, fixed = TRUE)
  value <- gsub("\\\\", "\\\\textbackslash{}", value)
  value <- gsub("([#$%&_{}])", "\\\\\\1", value)
  value <- gsub("~", "\\\\textasciitilde{}", value, fixed = TRUE)
  value
}

html_escape <- function(value) {
  value <- gsub("&", "&amp;", value, fixed = TRUE)
  value <- gsub("<", "&lt;", value, fixed = TRUE)
  gsub(">", "&gt;", value, fixed = TRUE)
}

image_uri <- function(path) {
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  raw <- readBin(con, what = "raw", n = file.info(path)$size)
  paste0("data:image/png;base64,", jsonlite::base64_enc(raw))
}

save_plot <- function(plot, stem) {
  png <- file.path(figure_dir, paste0(stem, ".png"))
  pdf <- file.path(figure_dir, paste0(stem, ".pdf"))
  ggplot2::ggsave(
    png, plot, width = 11.0, height = 6.35, units = "in", dpi = 300,
    device = ragg::agg_png, bg = "white"
  )
  ggplot2::ggsave(
    pdf, plot, width = 11.0, height = 6.35, units = "in",
    device = grDevices::cairo_pdf, bg = "white"
  )
  c(png = png, pdf = pdf)
}

axis_short_change <- c(
  "Steepness" = "Fixed Beverton–Holt steepness",
  "Tag overdispersion" = "Fixed direct negative-binomial tag overdispersion",
  "Tag mixing periods (KS D-statistic cutoff)" = "Release-group mixing periods derived from the KS D-statistic cutoff",
  "Conditional age-at-length" = "Conditional age-at-length effective sample sizes",
  "Natural mortality" = "The first fixed Lorenzen natural-mortality coefficient",
  "Effort creep" = "Effort for fisheries F29–F33",
  "Regional scaling" = "The regional-scaling time window",
  "Pre-mixing tag reporting" = "Application of the fitted reporting rates during each release group's specified mixing period"
)

axis_reference_label <- c(
  "Steepness" = "h = 0.90",
  "Tag overdispersion" = "τ = 2",
  "Tag mixing periods (KS D-statistic cutoff)" = "K = 0.20",
  "Conditional age-at-length" = "0.75 sub-basin",
  "Natural mortality" = "M scalar = 0.078",
  "Effort creep" = "1% / 0.5%",
  "Regional scaling" = "Current five-year window",
  "Pre-mixing tag reporting" = "Reporting rates excluded during mixing"
)

axis_display_label <- c(
  "Steepness" = "Steepness",
  "Tag overdispersion" = "Tag overdispersion (τ)",
  "Tag mixing periods (KS D-statistic cutoff)" = "Tag mixing periods (KS D-statistic cutoff)",
  "Conditional age-at-length" = "Conditional age-at-length",
  "Natural mortality" = "Natural mortality",
  "Effort creep" = "Effort creep",
  "Regional scaling" = "Regional scaling",
  "Pre-mixing tag reporting" = "Reporting rates during tag-mixing periods"
)

public_label <- function(key, label) {
  if (startsWith(key, "steepness-")) {
    value <- sub("^Steepness[[:space:]]+", "", label)
    value <- sub("^h[[:space:]]*=[[:space:]]*", "", value)
    return(paste0("h = ", value))
  }
  if (startsWith(key, "tau-")) {
    if (identical(key, "tau-1.006738")) {
      return("τ = 1")
    }
    value <- sub("^Tau[[:space:]]+", "", label)
    value <- sub("^tau[[:space:]]*=[[:space:]]*", "", value)
    return(paste0("τ = ", value))
  }
  if (startsWith(key, "tag-mixing-k-")) {
    value <- sub("^Tag mixing periods -[[:space:]]*", "", label)
    return(sub("^K=", "K = ", value))
  }
  if (startsWith(key, "lorenzen-m-scalar-")) {
    return(sub("^Lorenzen M scalar[[:space:]]+", "M scalar = ", label))
  }
  if (identical(key, "effort-creep-high")) return("2.5% / 1.25%")
  if (identical(key, "regional-scaling-whole-period")) return("Whole-period scaling")
  if (identical(key, "pre-mixing-tag-reporting-inclusion")) {
    return("Reporting rates applied during mixing")
  }
  sub("^CAAL[[:space:]]+", "", label)
}

latex_public_text <- function(value) {
  output <- latex_escape(value)
  gsub("τ", "$\\tau$", output, fixed = TRUE)
}

format_scientific <- function(value) {
  if (!is.finite(value)) return("—")
  if (value == 0) return("0")
  exponent <- floor(log10(abs(value)))
  coefficient <- value / 10^exponent
  superscript <- chartr("-0123456789", "⁻⁰¹²³⁴⁵⁶⁷⁸⁹", as.character(exponent))
  paste0(sprintf("%.2f", coefficient), " × 10", superscript)
}

format_scientific_latex <- function(value) {
  if (!is.finite(value)) return("--")
  if (value == 0) return("$0$")
  exponent <- floor(log10(abs(value)))
  coefficient <- value / 10^exponent
  paste0("$", sprintf("%.2f", coefficient), " \\times 10^{", exponent, "}$")
}

figure_specs <- vector("list", length(unique(design$axis)))
axis_order <- unique(design$axis)
diagnostic <- series[series$is_diagnostic %in% TRUE, , drop = FALSE]

for (axis_index in seq_along(axis_order)) {
  axis <- axis_order[[axis_index]]
  axis_design <- design[design$axis == axis, , drop = FALSE]
  alternatives <- series[series$key %in% axis_design$key, , drop = FALSE]
  alternatives$label <- mapply(public_label, alternatives$key, alternatives$label, USE.NAMES = FALSE)
  diagnostic_label <- paste0(unname(axis_reference_label[[axis]]), " (Diagnostic)")
  axis_diagnostic <- diagnostic
  axis_diagnostic$label <- diagnostic_label
  plot_data <- rbind(axis_diagnostic, alternatives)
  alternative_labels <- unique(alternatives$label)
  if (identical(axis, "Tag overdispersion")) {
    labels <- c(alternative_labels, diagnostic_label)
    colours <- c(
      stats::setNames(axis_palette[seq_along(alternative_labels)], alternative_labels),
      stats::setNames(diagnostic_colour, diagnostic_label)
    )
  } else {
    labels <- c(diagnostic_label, alternative_labels)
    colours <- c(
      stats::setNames(diagnostic_colour, diagnostic_label),
      stats::setNames(axis_palette[seq_along(alternative_labels)], alternative_labels)
    )
  }
  plot_data$label <- factor(plot_data$label, levels = labels)

  panels <- lapply(metric_specs, function(spec) {
    panel <- ggplot2::ggplot(
      plot_data,
      ggplot2::aes(x = .data$year, y = .data[[spec$column]], colour = .data$label)
    ) +
      ggplot2::geom_line(
        data = plot_data[!plot_data$is_diagnostic, , drop = FALSE],
        linewidth = 0.58, alpha = 0.88
      ) +
      ggplot2::geom_line(
        data = plot_data[plot_data$is_diagnostic, , drop = FALSE],
        linewidth = 0.92
      ) +
      ggplot2::scale_colour_manual(
        values = colours, breaks = labels, drop = FALSE,
        guide = ggplot2::guide_legend(
          nrow = if (length(labels) > 4L) 2L else 1L,
          byrow = TRUE
        )
      ) +
      ggplot2::scale_x_continuous(
        breaks = seq(1960, 2020, 20),
        expand = ggplot2::expansion(mult = c(0.012, 0.012))
      ) +
      ggplot2::scale_y_continuous(
        limits = function(value) c(0, max(value, na.rm = TRUE) * 1.035),
        expand = ggplot2::expansion(mult = c(0, 0.02)),
        labels = scales::label_number(big.mark = ",")
      ) +
      ggplot2::labs(x = "Year", y = spec$label) +
      theme_report()
    if (isTRUE(spec$lrp)) {
      panel <- panel +
        ggplot2::geom_hline(
          yintercept = 0.2, colour = "#B64040", linetype = "dashed", linewidth = 0.58
        ) +
        ggplot2::annotate(
          "text", x = 1954, y = 0.2, label = "LRP", colour = "#B64040",
          fontface = "bold", hjust = 0, vjust = -0.35, size = 3.2
        )
    }
    panel
  })

  combined <- patchwork::wrap_plots(panels, ncol = 2, guides = "collect") +
    patchwork::plot_annotation(tag_levels = "a") &
    ggplot2::theme(legend.position = "bottom")
  stem <- paste0("sensitivity-", slugify(axis))
  files <- save_plot(combined, stem)

  alternative_text <- paste(unique(alternatives$label), collapse = ", ")
  axis_text <- unname(axis_display_label[[axis]])
  pre_mixing_note <- if (identical(axis, "Pre-mixing tag reporting")) {
    paste0(
      " The alternative applies the fitted reporting rates during each release group's specified mixing period; ",
      "the Diagnostic fit excludes their application during that period. Reporting-rate values and post-mixing ",
      "treatment are unchanged."
    )
  } else {
    ""
  }
  lower_tau_note <- if (identical(axis, "Tag overdispersion")) {
    paste0(
      " The τ = 1 label denotes the closest finite lower-bound case, ",
      "τ = 1 + exp(−5) ≈ 1.00674; exactly τ = 1 would require an infinite transformed parameter."
    )
  } else {
    ""
  }
  lower_tau_note_latex <- if (identical(axis, "Tag overdispersion")) {
    paste0(
      " The $\\tau=1$ label denotes the closest finite lower-bound case, ",
      "$\\tau=1+\\exp(-5)\\approx1.00674$; exactly $\\tau=1$ would require an infinite transformed parameter."
    )
  } else {
    ""
  }
  caption <- paste0(
    "Annual estimates of dynamic spawning depletion, recruitment, spawning potential and fishing mortality for the ",
    axis_text, " sensitivity analysis. The red line is ", diagnostic_label, "; the coloured lines show ",
    alternative_text, ". Each alternative changes only ", tolower(axis_short_change[[axis]]),
    "; all other Diagnostic settings are retained.", pre_mixing_note, lower_tau_note,
    " The dashed line in panel (a) marks the limit reference point (LRP = 0.2)."
  )
  latex_caption <- paste0(
    "Annual estimates of dynamic spawning depletion ($SB/SB_{F=0}$), recruitment, spawning potential, and fishing ",
    "mortality for the ", latex_public_text(axis_text), " sensitivity analysis. The red line is ",
    latex_public_text(diagnostic_label), "; the coloured lines show ", latex_public_text(alternative_text),
    ". Each alternative changes only ", latex_escape(tolower(axis_short_change[[axis]])),
    "; all other Diagnostic settings are retained.", latex_escape(pre_mixing_note), lower_tau_note_latex,
    " The dashed line in panel (a) marks the limit reference point ($\\mathrm{LRP}=0.2$)."
  )
  figure_specs[[axis_index]] <- list(
    axis = axis_text,
    stem = stem,
    png = unname(files[["png"]]),
    pdf = unname(files[["pdf"]]),
    caption = caption,
    latex_caption = latex_caption
  )
}

axis_table <- do.call(rbind, lapply(axis_order, function(axis) {
  axis_design <- design[design$axis == axis, , drop = FALSE]
  labels <- vapply(seq_len(nrow(axis_design)), function(index) {
    public_label(axis_design$key[[index]], axis_design$label[[index]])
  }, character(1))
  data.frame(
    Axis = unname(axis_display_label[[axis]]),
    `Diagnostic setting` = unname(axis_reference_label[[axis]]),
    Alternatives = paste(labels, collapse = "; "),
    `Changed component` = unname(axis_short_change[[axis]]),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
}))
utils::write.csv(axis_table, file.path(table_dir, "sensitivity-design-summary.csv"), row.names = FALSE)

design_caption <- paste0(
  "One-at-a-time sensitivity design for the Diagnostic model. Each fit changes only the named component. ",
  "The τ = 1 label denotes the finite lower-bound value τ = 1 + exp(−5) ≈ 1.00674."
)
design_latex_caption <- paste0(
  "One-at-a-time sensitivity design for the Diagnostic model. Each fit changes only the named component. ",
  "The $\\tau=1$ label denotes the finite lower-bound value $\\tau=1+\\exp(-5)\\approx1.00674$."
)

table_rows_html <- paste0(
  "<tr><td>", html_escape(axis_table$Axis), "</td><td>",
  html_escape(axis_table[["Diagnostic setting"]]), "</td><td>",
  html_escape(axis_table$Alternatives), "</td><td>",
  html_escape(axis_table[["Changed component"]]), "</td></tr>",
  collapse = "\n"
)
word_table <- paste(
  c(
    paste0("Table XX. ", design_caption),
    "",
    paste(names(axis_table), collapse = "\t"),
    apply(axis_table, 1L, function(row) paste(row, collapse = "\t"))
  ),
  collapse = "\n"
)
latex_rows <- paste0(
  latex_public_text(axis_table$Axis), " & ",
  latex_public_text(axis_table[["Diagnostic setting"]]), " & ",
  latex_public_text(axis_table$Alternatives), " & ",
  latex_escape(axis_table[["Changed component"]]), " \\\\",
  collapse = "\n"
)
latex_table <- paste0(
  "% Requires \\usepackage{booktabs,tabularx,array}\n",
  "\\begin{table}[htbp]\n\\centering\n\\caption{", design_latex_caption, "}\n",
  "\\label{tab:bet-sensitivity-design}\n\\scriptsize\n\\setlength{\\tabcolsep}{3pt}\n\\renewcommand{\\arraystretch}{1.08}\n",
  "\\begin{tabularx}{\\textwidth}{@{}>{\\raggedright\\arraybackslash}p{0.19\\textwidth}>{\\raggedright\\arraybackslash}p{0.18\\textwidth}>{\\raggedright\\arraybackslash}p{0.27\\textwidth}X@{}}\n",
  "\\toprule\nAxis & Diagnostic setting & Alternatives & Changed component \\\\\n\\midrule\n",
  latex_rows,
  "\n\\bottomrule\n\\end{tabularx}\n\\end{table}\n"
)
writeLines(latex_table, file.path(table_dir, "sensitivity-design-summary.tex"), useBytes = TRUE)

fit_diagnostics <- fit_diagnostics[match(design$key, fit_diagnostics$key), , drop = FALSE]
diagnostic_table <- data.frame(
  Fit = vapply(seq_len(nrow(design)), function(index) {
    public_label(design$key[[index]], design$label[[index]])
  }, character(1)),
  Axis = unname(axis_display_label[design$axis]),
  MGC = vapply(fit_diagnostics$maximum_gradient_component, format_scientific, character(1)),
  `Objective function value` = formatC(
    fit_diagnostics$objective_function, format = "f", digits = 1, big.mark = ","
  ),
  PDH = ifelse(fit_diagnostics$positive_definite_hessian, "Yes", "No"),
  check.names = FALSE,
  stringsAsFactors = FALSE
)
utils::write.csv(
  diagnostic_table,
  file.path(table_dir, "sensitivity-fit-diagnostics.csv"),
  row.names = FALSE
)

diagnostic_caption <- paste0(
  "Fit and Hessian diagnostics for the 17 one-at-a-time sensitivity fits. MGC is the maximum absolute gradient ",
  "component at the final estimate; PDH indicates a positive-definite Hessian. The τ = 1 label denotes the fitted finite lower-bound value ",
  "τ = 1 + exp(−5) ≈ 1.00674."
)
diagnostic_latex_caption <- paste0(
  "Fit and Hessian diagnostics for the 17 one-at-a-time sensitivity fits. MGC is the maximum absolute gradient ",
  "component at the final estimate; PDH indicates a positive-definite Hessian. The $\\tau=1$ label denotes the fitted finite lower-bound value ",
  "$\\tau=1+\\exp(-5)\\approx1.00674$."
)
diagnostic_rows_html <- paste0(
  "<tr><td>", html_escape(diagnostic_table$Fit), "</td><td>",
  html_escape(diagnostic_table$Axis), "</td><td class='num'>", html_escape(diagnostic_table$MGC),
  "</td><td class='num'>", html_escape(diagnostic_table[["Objective function value"]]),
  "</td><td class='center'>", diagnostic_table$PDH, "</td></tr>",
  collapse = "\n"
)
diagnostic_word_table <- paste(
  c(
    paste0("Table XX. ", diagnostic_caption),
    "",
    paste(names(diagnostic_table), collapse = "\t"),
    apply(diagnostic_table, 1L, function(row) paste(row, collapse = "\t"))
  ),
  collapse = "\n"
)
diagnostic_latex_rows <- vapply(seq_len(nrow(diagnostic_table)), function(index) {
  paste0(
    latex_public_text(diagnostic_table$Fit[[index]]), " & ",
    latex_public_text(diagnostic_table$Axis[[index]]), " & ",
    format_scientific_latex(fit_diagnostics$maximum_gradient_component[[index]]), " & ",
    formatC(fit_diagnostics$objective_function[[index]], format = "f", digits = 1, big.mark = ","), " & ",
    diagnostic_table$PDH[[index]], " \\\\"
  )
}, character(1))
diagnostic_latex_table <- paste0(
  "% Requires \\usepackage{booktabs,tabularx,array}\n",
  "\\begin{table}[htbp]\n\\centering\n\\caption{", diagnostic_latex_caption, "}\n",
  "\\label{tab:bet-sensitivity-fit-diagnostics}\n\\scriptsize\n\\setlength{\\tabcolsep}{2.2pt}\n",
  "\\renewcommand{\\arraystretch}{1.04}\n",
  "\\begin{tabularx}{\\textwidth}{@{}>{\\raggedright\\arraybackslash}X",
  ">{\\raggedright\\arraybackslash}Xrrc@{}}\n",
  "\\toprule\nFit & Axis & MGC & Objective function value & PDH \\\\\n",
  "\\midrule\n", paste(diagnostic_latex_rows, collapse = "\n"),
  "\n\\bottomrule\n\\end{tabularx}\n\\end{table}\n"
)
writeLines(
  diagnostic_latex_table,
  file.path(table_dir, "sensitivity-fit-diagnostics.tex"),
  useBytes = TRUE
)

figure_html <- paste(vapply(figure_specs, function(spec) {
  latex_figure <- paste0(
    "% Requires \\usepackage{graphicx}\n",
    "\\begin{figure}[htbp]\n\\centering\n",
    "\\includegraphics[width=\\textwidth]{figures/", spec$stem, ".pdf}\n",
    "\\caption{", spec$latex_caption, "}\n",
    "\\label{fig:", spec$stem, "}\n\\end{figure}\n"
  )
  paste0(
    "<article class='paper-page'><h2>", html_escape(spec$axis), "</h2>",
    "<img id='fig-", spec$stem, "' src='", image_uri(spec$png), "' alt='", html_escape(spec$axis), " sensitivity figure'>",
    "<figcaption id='cap-", spec$stem, "'><b>Figure <span contenteditable='true'>XX</span>.</b> ", spec$caption, "</figcaption>",
    "<div class='buttons'>",
    "<button onclick=\"copyFigure('fig-", spec$stem, "','cap-", spec$stem, "')\">Copy figure + caption for Word</button>",
    "<button onclick=\"saveImage('fig-", spec$stem, "','", spec$stem, ".png')\">Save PNG</button>",
    "<a class='button' href='figures/", spec$stem, ".pdf' download>Save vector PDF</a>",
    "<button onclick=\"copyText('latex-", spec$stem, "')\">Copy figure + caption for LaTeX</button>",
    "</div><textarea id='latex-", spec$stem, "' hidden>", html_escape(latex_figure), "</textarea></article>"
  )
}, character(1)), collapse = "\n")

html <- paste0(
  "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>",
  "<title>BET 2026 sensitivity analysis</title><style>",
  "body{margin:0;background:#eef3f5;color:#172b3a;font-family:Arial,sans-serif}header{background:#103c56;color:#fff;padding:22px 5vw}",
  "header h1{margin:0;font-family:Georgia,serif;font-size:30px}header p{margin:7px 0 0;color:#d8e8ef}",
  ".tabs{display:flex;gap:8px;padding:14px 5vw;background:#dde8ec;position:sticky;top:0;z-index:5}.tab{border:1px solid #9db4be;background:#f7fbfc;padding:10px 16px;font-weight:700;cursor:pointer}.tab.active{background:#176c80;color:#fff}",
  "main{max-width:1220px;margin:22px auto;padding:0 18px}.panel{display:none}.panel.active{display:block}.card{background:#fff;border:1px solid #cad8de;padding:22px;margin-bottom:22px}",
  ".summary{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.metric{background:#f2f7f8;border-left:5px solid #176c80;padding:16px}.metric b{font-size:25px;display:block}",
  ".paper-page{background:#fff;border:1px solid #cad8de;padding:17px 22px;margin:0 auto 28px;box-sizing:border-box}.paper-page h2{font-family:Georgia,serif;margin:0 0 10px;color:#103c56}.paper-page img{width:100%;height:auto;display:block}.paper-page figcaption{font-family:Georgia,serif;font-size:14px;line-height:1.45;margin-top:11px;color:#263238}",
  "table{border-collapse:collapse;width:100%;font-family:Georgia,serif;font-size:13px}th,td{padding:7px 9px;border-bottom:1px solid #d5dfe3;text-align:left;vertical-align:top}th{background:#e8f1f4}.diagnostics-table{font-size:11.4px}.diagnostics-table th,.diagnostics-table td{padding:5px 6px}.diagnostics-table .num{white-space:nowrap;text-align:right}.diagnostics-table .center{text-align:center}",
  ".buttons{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0}.buttons button,.button{background:#176c80;color:white;border:0;padding:9px 13px;font-weight:700;cursor:pointer;text-decoration:none;font-size:13px}.buttons button:hover,.button:hover{background:#103c56}.method-list{max-width:980px;line-height:1.6;font-family:Georgia,serif;color:#29495b}.method-list li{margin:.45rem 0}.copy-status{position:fixed;right:22px;bottom:22px;background:#103c56;color:#fff;padding:10px 14px;border-radius:3px;opacity:0;transition:opacity .15s;z-index:9}.copy-status.show{opacity:1}",
  "@media(max-width:760px){.summary{grid-template-columns:1fr}.tabs{position:static}}",
  "@media print{body{background:#fff}.tabs,.buttons,.copy-status{display:none}header{background:#fff;color:#000;padding:0 0 8mm}.panel{display:block}.card{border:0}.paper-page{width:277mm;min-height:0;border:0;padding:5mm 8mm;break-before:page;break-after:page;break-inside:avoid;page-break-before:always;page-break-after:always;page-break-inside:avoid}.paper-page h2{font-size:14pt}.paper-page img{display:block;width:auto;max-width:100%;height:auto;max-height:135mm;margin:0 auto;object-fit:contain}.paper-page figcaption{font-size:9.5pt}.summary{display:none}main{max-width:none;margin:0;padding:0}@page{size:A4 landscape;margin:10mm}}",
  "</style></head><body><header><h1>BET 2026 sensitivity analysis</h1><p>Diagnostic model · 17 one-at-a-time fits · eight sensitivity axes</p></header>",
  "<div id='copyStatus' class='copy-status'>Copied</div><nav class='tabs'><button class='tab active' data-target='overview'>Overview</button><button class='tab' data-target='figures'>Figures and tables</button></nav><main>",
  "<section id='overview' class='panel active'><div class='summary'><div class='metric'><b>17</b>completed sensitivity fits</div><div class='metric'><b>8</b>one-at-a-time axes</div><div class='metric'><b>73</b>annual values per fit</div></div>",
  "<div class='card'><h2>Analysis design</h2><ul class='method-list'>",
  "<li><strong>Diagnostic-model basis.</strong> The Diagnostic model fixes steepness at <i>h</i> = 0.90 and direct negative-binomial tag overdispersion at &tau; = 2, uses 33 independent selectivity groups with weak non-decreasing penalties for F10 and F33, and retains the Diagnostic-model DM settings.</li>",
  "<li><strong>One-at-a-time comparison.</strong> Each completed fit changes only its named sensitivity component. Model data, selectivity and other controls remain at their Diagnostic-model values unless they define the selected axis.</li>",
  "<li><strong>Lower τ sensitivity.</strong> Under the direct parameterization τ = 1 + exp(<i>x</i>), exactly τ = 1 would require <i>x</i> = log(0) = −∞ and cannot be represented by a finite parameter. The finite lower bound <i>x</i> = −5 therefore gives the near-one case τ = 1 + exp(−5) ≈ 1.00674.</li>",
  "<li><strong>Initialization.</strong> Every sensitivity is fitted independently from an ordinary makepar-generated initial PAR. It does not start from the fitted final PAR of the Diagnostic model, a selected jitter seed, or any fitted checkpoint.</li>",
  "<li><strong>Quantities.</strong> Figures compare annual dynamic spawning depletion, recruitment, spawning potential and fishing mortality. They are deterministic model comparisons and do not represent confidence intervals.</li>",
  "</ul></div></section>",
  "<section id='figures' class='panel'>", figure_html,
  "<article class='paper-page table-page'><h2>Sensitivity design</h2><div class='buttons'><button onclick=\"copyTable('designTable','designTableCaption','wordTable')\">Copy table for Word</button><button onclick=\"copyText('latexTable')\">Copy LaTeX</button></div>",
  "<p id='designTableCaption'><b>Table <span contenteditable='true'>XX</span>.</b> ", design_caption, "</p>",
  "<table id='designTable'><thead><tr><th>Axis</th><th>Diagnostic setting</th><th>Alternatives</th><th>Changed component</th></tr></thead><tbody>", table_rows_html, "</tbody></table>",
  "<textarea id='wordTable' hidden>", html_escape(word_table), "</textarea><textarea id='latexTable' hidden>", html_escape(latex_table), "</textarea></article>",
  "<article class='paper-page table-page'><h2>Fit and Hessian diagnostics</h2><div class='buttons'><button onclick=\"copyTable('diagnosticTable','diagnosticTableCaption','diagnosticWordTable')\">Copy table for Word</button><button onclick=\"copyText('diagnosticLatexTable')\">Copy LaTeX</button></div>",
  "<p id='diagnosticTableCaption'><b>Table <span contenteditable='true'>XX</span>.</b> ", diagnostic_caption, "</p>",
  "<table id='diagnosticTable' class='diagnostics-table'><thead><tr><th>Fit</th><th>Axis</th><th class='num'>MGC</th><th class='num'>Objective function value</th><th class='center'>PDH</th></tr></thead><tbody>",
  diagnostic_rows_html, "</tbody></table><textarea id='diagnosticWordTable' hidden>",
  html_escape(diagnostic_word_table), "</textarea><textarea id='diagnosticLatexTable' hidden>",
  html_escape(diagnostic_latex_table), "</textarea></article></section></main>",
  "<script>document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tab,.panel').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById(b.dataset.target).classList.add('active')});function flash(msg='Copied'){const s=document.getElementById('copyStatus');s.textContent=msg;s.classList.add('show');setTimeout(()=>s.classList.remove('show'),1300)}function copyText(id){navigator.clipboard.writeText(document.getElementById(id).value).then(()=>flash())}async function copyTable(tableId,captionId,textId){const table=document.getElementById(tableId);const caption=document.getElementById(captionId);const html='<p>'+caption.innerHTML+'</p>'+table.outerHTML;const text=document.getElementById(textId).value;try{await navigator.clipboard.write([new ClipboardItem({'text/html':new Blob([html],{type:'text/html'}),'text/plain':new Blob([text],{type:'text/plain'})})]);flash('Table and caption copied')}catch(e){await navigator.clipboard.writeText(text);flash('Table copied as tab-separated text')}}async function copyFigure(id,cap){const img=document.getElementById(id);const blob=await(await fetch(img.src)).blob();const caption=document.getElementById(cap).innerText;try{await navigator.clipboard.write([new ClipboardItem({'image/png':blob,'text/plain':new Blob([caption],{type:'text/plain'})})]);flash('Figure and caption copied')}catch(e){await navigator.clipboard.writeText(caption);flash('Caption copied; use Save PNG for the figure')}}function saveImage(id,name){const a=document.createElement('a');a.href=document.getElementById(id).src;a.download=name;a.click();flash('PNG saved')}</script>",
  "</body></html>"
)

html_file <- file.path(output_dir, "bet-2026-sensitivity-report.html")
writeLines(html, html_file, useBytes = TRUE)

files <- list.files(output_dir, recursive = TRUE, full.names = TRUE)
files <- files[file.info(files)$isdir %in% FALSE]
manifest <- data.frame(
  file = sub(paste0("^", normalizePath(output_dir, winslash = "/"), "/"), "", normalizePath(files, winslash = "/")),
  bytes = file.info(files)$size,
  stringsAsFactors = FALSE
)
utils::write.csv(manifest, file.path(output_dir, "report-manifest.csv"), row.names = FALSE)

cat("Rendered eight A4 sensitivity figures and a self-contained public report with no MFCL rerun.\n")
