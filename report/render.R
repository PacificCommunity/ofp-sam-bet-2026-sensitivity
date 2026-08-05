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
  list(column = "recruitment", label = "Recruitment (millions of fish)", lrp = FALSE),
  list(column = "spawning_potential", label = bquote(Spawning~potential~(10^3~plain(MT))), lrp = FALSE),
  list(column = "fishing_mortality", label = bquote(italic(F)~(year^{-1})), lrp = FALSE)
)

axis_palette <- c("#0072B2", "#009E73", "#E69F00", "#56B4E9", "#CC79A7")
diagnostic_colour <- "#C62828"

slugify <- function(value) {
  value <- tolower(gsub("[^A-Za-z0-9]+", "-", value))
  gsub("(^-|-$)", "", value)
}

latex_escape <- function(value) {
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
  "Steepness" = "Fixed Beverton–Holt steepness only",
  "Tag overdispersion" = "Fixed direct negative-binomial tag overdispersion only",
  "Tag mixing periods (KS D-statistic cutoff)" = "Release-group mixing periods derived from the KS D-statistic cutoff only",
  "Conditional age-at-length" = "Conditional age-at-length effective sample sizes only",
  "Natural mortality" = "The first fixed Lorenzen natural-mortality coefficient only",
  "Effort creep" = "Effort for fisheries F29–F33 only",
  "Regional scaling" = "The regional-scaling time window only",
  "Pre-mixing tag reporting" = "The pre-mixing tag-reporting flag only"
)

axis_reference_label <- c(
  "Steepness" = "h = 0.90 fixed",
  "Tag overdispersion" = "tau = 2 fixed",
  "Tag mixing periods (KS D-statistic cutoff)" = "K = 0.20",
  "Conditional age-at-length" = "0.75 sub-basin",
  "Natural mortality" = "M scalar = 0.078",
  "Effort creep" = "1% / 0.5%",
  "Regional scaling" = "Current five-year window",
  "Pre-mixing tag reporting" = "Pre-mixing reports excluded"
)

figure_specs <- vector("list", length(unique(design$axis)))
axis_order <- unique(design$axis)
diagnostic <- series[series$is_diagnostic %in% TRUE, , drop = FALSE]

for (axis_index in seq_along(axis_order)) {
  axis <- axis_order[[axis_index]]
  axis_design <- design[design$axis == axis, , drop = FALSE]
  alternatives <- series[series$key %in% axis_design$key, , drop = FALSE]
  plot_data <- rbind(diagnostic, alternatives)
  labels <- c("Diagnostic model", unique(alternatives$label))
  colours <- stats::setNames(c(diagnostic_colour, axis_palette[seq_len(length(labels) - 1L)]), labels)
  plot_data$label <- factor(plot_data$label, levels = labels)

  panels <- lapply(metric_specs, function(spec) {
    panel <- ggplot2::ggplot(
      plot_data,
      ggplot2::aes(x = .data$year, y = .data[[spec$column]], colour = .data$label)
    ) +
      ggplot2::geom_line(
        data = plot_data[!plot_data$is_diagnostic, , drop = FALSE],
        linewidth = 0.82, alpha = 0.92
      ) +
      ggplot2::geom_line(
        data = plot_data[plot_data$is_diagnostic, , drop = FALSE],
        linewidth = 1.08
      ) +
      ggplot2::scale_colour_manual(values = colours, breaks = labels, drop = FALSE) +
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
  caption <- paste0(
    "Annual estimates of dynamic spawning depletion, recruitment, spawning potential and fishing mortality for the ",
    "Diagnostic model and the ", tolower(axis), " sensitivity fits (", alternative_text, "). Each alternative changes ",
    "only ", tolower(axis_short_change[[axis]]), "; all other Diagnostic-model settings are retained. The red line is ",
    "the Diagnostic model. The dashed line in panel (a) marks the limit reference point (LRP = 0.2)."
  )
  latex_caption <- paste0(
    "Annual estimates of dynamic spawning depletion ($SB/SB_{F=0}$), recruitment, spawning potential, and fishing ",
    "mortality for the Diagnostic model and the ", latex_escape(tolower(axis)), " sensitivity fits (",
    latex_escape(alternative_text), "). Each alternative changes only ",
    latex_escape(tolower(axis_short_change[[axis]])), "; all other Diagnostic-model settings are retained. The red line ",
    "is the Diagnostic model. The dashed line in panel (a) marks the limit reference point ($\\mathrm{LRP}=0.2$)."
  )
  figure_specs[[axis_index]] <- list(
    axis = axis,
    stem = stem,
    png = unname(files[["png"]]),
    pdf = unname(files[["pdf"]]),
    caption = caption,
    latex_caption = latex_caption
  )
}

axis_table <- do.call(rbind, lapply(axis_order, function(axis) {
  axis_design <- design[design$axis == axis, , drop = FALSE]
  labels <- unique(series$label[series$key %in% axis_design$key])
  data.frame(
    Axis = axis,
    `Diagnostic setting` = unname(axis_reference_label[[axis]]),
    Alternatives = paste(labels, collapse = "; "),
    `Changed component` = unname(axis_short_change[[axis]]),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
}))
utils::write.csv(axis_table, file.path(table_dir, "sensitivity-design-summary.csv"), row.names = FALSE)

table_rows_html <- paste0(
  "<tr><td>", html_escape(axis_table$Axis), "</td><td>",
  html_escape(axis_table[["Diagnostic setting"]]), "</td><td>",
  html_escape(axis_table$Alternatives), "</td><td>",
  html_escape(axis_table[["Changed component"]]), "</td></tr>",
  collapse = "\n"
)
word_table <- paste(
  c(
    paste(names(axis_table), collapse = "\t"),
    apply(axis_table, 1L, function(row) paste(row, collapse = "\t"))
  ),
  collapse = "\n"
)
latex_rows <- paste0(
  latex_escape(axis_table$Axis), " & ",
  latex_escape(axis_table[["Diagnostic setting"]]), " & ",
  latex_escape(axis_table$Alternatives), " & ",
  latex_escape(axis_table[["Changed component"]]), " \\\\",
  collapse = "\n"
)
latex_table <- paste0(
  "% Requires \\usepackage{booktabs,tabularx,array}\n",
  "\\begin{table}[htbp]\n\\centering\n\\caption{One-at-a-time sensitivity design for the Diagnostic model. Each fit changes only the named component.}\n",
  "\\label{tab:bet-sensitivity-design}\n\\scriptsize\n\\setlength{\\tabcolsep}{3pt}\n\\renewcommand{\\arraystretch}{1.08}\n",
  "\\begin{tabularx}{\\textwidth}{@{}>{\\raggedright\\arraybackslash}p{0.19\\textwidth}>{\\raggedright\\arraybackslash}p{0.18\\textwidth}>{\\raggedright\\arraybackslash}p{0.27\\textwidth}X@{}}\n",
  "\\toprule\nAxis & Diagnostic setting & Alternatives & Changed component \\\\\n\\midrule\n",
  latex_rows,
  "\n\\bottomrule\n\\end{tabularx}\n\\end{table}\n"
)
writeLines(latex_table, file.path(table_dir, "sensitivity-design-summary.tex"), useBytes = TRUE)

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
  "table{border-collapse:collapse;width:100%;font-family:Georgia,serif;font-size:13px}th,td{padding:7px 9px;border-bottom:1px solid #d5dfe3;text-align:left;vertical-align:top}th{background:#e8f1f4}",
  ".buttons{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0}.buttons button,.button{background:#176c80;color:white;border:0;padding:9px 13px;font-weight:700;cursor:pointer;text-decoration:none;font-size:13px}.buttons button:hover,.button:hover{background:#103c56}.method-list{max-width:980px;line-height:1.6;font-family:Georgia,serif;color:#29495b}.method-list li{margin:.45rem 0}.copy-status{position:fixed;right:22px;bottom:22px;background:#103c56;color:#fff;padding:10px 14px;border-radius:3px;opacity:0;transition:opacity .15s;z-index:9}.copy-status.show{opacity:1}",
  "@media(max-width:760px){.summary{grid-template-columns:1fr}.tabs{position:static}}",
  "@media print{body{background:#fff}.tabs,.buttons,.copy-status{display:none}header{background:#fff;color:#000;padding:0 0 8mm}.panel{display:block}.card{border:0}.paper-page{width:277mm;min-height:190mm;border:0;padding:5mm 8mm;page-break-after:always}.paper-page h2{font-size:14pt}.paper-page img{max-height:150mm;object-fit:contain}.paper-page figcaption{font-size:9.5pt}.summary{display:none}main{max-width:none;margin:0;padding:0}@page{size:A4 landscape;margin:10mm}}",
  "</style></head><body><header><h1>BET 2026 sensitivity analysis</h1><p>Diagnostic model · 17 one-at-a-time fits · eight sensitivity axes</p></header>",
  "<div id='copyStatus' class='copy-status'>Copied</div><nav class='tabs'><button class='tab active' data-target='overview'>Overview</button><button class='tab' data-target='figures'>Figures and tables</button></nav><main>",
  "<section id='overview' class='panel active'><div class='summary'><div class='metric'><b>17</b>completed sensitivity fits</div><div class='metric'><b>8</b>one-at-a-time axes</div><div class='metric'><b>73</b>annual values per fit</div></div>",
  "<div class='card'><h2>Analysis design</h2><ul class='method-list'>",
  "<li><strong>Diagnostic-model basis.</strong> The Diagnostic model fixes steepness at <i>h</i> = 0.90 and direct negative-binomial tag overdispersion at &tau; = 2, uses 33 independent selectivity groups with weak non-decreasing penalties for F10 and F33, and retains the Diagnostic-model DM settings.</li>",
  "<li><strong>One-at-a-time comparison.</strong> Each completed fit changes only its named sensitivity component. Model data, selectivity and other controls remain at their Diagnostic-model values unless they define the selected axis.</li>",
  "<li><strong>Initialization.</strong> Every fit starts from an ordinary makepar model with no selected jitter seed or fitted checkpoint.</li>",
  "<li><strong>Quantities.</strong> Figures compare annual dynamic spawning depletion, recruitment, spawning potential and fishing mortality. They are deterministic model comparisons and do not represent confidence intervals.</li>",
  "</ul></div></section>",
  "<section id='figures' class='panel'>", figure_html,
  "<article class='paper-page table-page'><h2>Sensitivity design</h2><div class='buttons'><button onclick=\"copyText('wordTable')\">Copy table for Word</button><button onclick=\"copyText('latexTable')\">Copy LaTeX</button></div>",
  "<p><b>Table <span contenteditable='true'>XX</span>.</b> One-at-a-time sensitivity design for the Diagnostic model. Each fit changes only the named component.</p>",
  "<table><thead><tr><th>Axis</th><th>Diagnostic setting</th><th>Alternatives</th><th>Changed component</th></tr></thead><tbody>", table_rows_html, "</tbody></table>",
  "<textarea id='wordTable' hidden>", html_escape(word_table), "</textarea><textarea id='latexTable' hidden>", html_escape(latex_table), "</textarea></article></section></main>",
  "<script>document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tab,.panel').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById(b.dataset.target).classList.add('active')});function flash(msg='Copied'){const s=document.getElementById('copyStatus');s.textContent=msg;s.classList.add('show');setTimeout(()=>s.classList.remove('show'),1300)}function copyText(id){navigator.clipboard.writeText(document.getElementById(id).value).then(()=>flash())}async function copyFigure(id,cap){const img=document.getElementById(id);const blob=await(await fetch(img.src)).blob();const caption=document.getElementById(cap).innerText;try{await navigator.clipboard.write([new ClipboardItem({'image/png':blob,'text/plain':new Blob([caption],{type:'text/plain'})})]);flash('Figure and caption copied')}catch(e){await navigator.clipboard.writeText(caption);flash('Caption copied; use Save PNG for the figure')}}function saveImage(id,name){const a=document.createElement('a');a.href=document.getElementById(id).src;a.download=name;a.click();flash('PNG saved')}</script>",
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
