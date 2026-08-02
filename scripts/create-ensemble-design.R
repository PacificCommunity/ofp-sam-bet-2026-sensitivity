#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
if (length(script_arg) != 1L) stop("Cannot locate repository root.", call. = FALSE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", script_arg)), ".."), mustWork = TRUE)
output_dir <- file.path(repo, "ensemble")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

n_models <- 100L
design_seed <- 20260802L

# 2024 South Pacific albacore assessment: h = 0.2 + 0.8Y,
# Y ~ Beta(alpha, beta), with E[h] = 0.87 and SD[h] = 0.063.
h_lower <- 0.2
h_upper <- 1.0
h_mean <- 0.87
h_sd <- 0.063
y_mean <- (h_mean - h_lower) / (h_upper - h_lower)
y_var <- (h_sd / (h_upper - h_lower))^2
beta_total <- y_mean * (1 - y_mean) / y_var - 1
h_alpha <- y_mean * beta_total
h_beta <- (1 - y_mean) * beta_total
h_probability <- (seq_len(n_models) - 0.5) / n_models
h_draw <- h_lower + (h_upper - h_lower) * qbeta(h_probability, h_alpha, h_beta)

# Evidence-synthesised quarterly M at age 40. The selected tag-analysis midpoint
# and previous-assessment value define the mode, the current Diagnostic
# Lorenzen intercept is the median, and the Hamel-Cope 95% limits define the
# truncation bounds. Calibrating a truncated lognormal to the requested mode and
# median gives a log SD close to the Hamel-Cope value of 0.31.
m_min <- 0.050
m_mode <- 0.0702
m_median <- exp(-2.54930339768360)
m_max <- 0.165
m_log_sd_hamel_cope <- 0.31

truncated_lognormal_median <- function(log_sd) {
  meanlog <- log(m_mode) + log_sd^2
  lower_cdf <- plnorm(m_min, meanlog, log_sd)
  upper_cdf <- plnorm(m_max, meanlog, log_sd)
  qlnorm(lower_cdf + 0.5 * (upper_cdf - lower_cdf), meanlog, log_sd)
}
m_log_sd <- uniroot(
  function(log_sd) truncated_lognormal_median(log_sd) - m_median,
  interval = c(0.05, 0.80), tol = 1e-13
)$root
m_meanlog <- log(m_mode) + m_log_sd^2
m_lower_cdf <- plnorm(m_min, m_meanlog, m_log_sd)
m_upper_cdf <- plnorm(m_max, m_meanlog, m_log_sd)

qtruncated_lnorm <- function(p) {
  qlnorm(m_lower_cdf + p * (m_upper_cdf - m_lower_cdf), m_meanlog, m_log_sd)
}

# Retain both truncation limits and duplicate the central quantile so the
# finite 100-model representation contains the requested median exactly.
m_probability <- seq(0, 1, length.out = n_models)
m_probability[c(n_models / 2L, n_models / 2L + 1L)] <- 0.5
m_draw <- qtruncated_lnorm(m_probability)

# Exact finite-sample counts. The mixing weights approximate the transparent
# symmetric 1:2:3:4:3:2:1 distribution while making 0.20 clearly modal.
mixing_levels <- c(0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35)
mixing_counts <- c(6L, 12L, 19L, 26L, 19L, 12L, 6L)
mixing_draw <- rep(mixing_levels, mixing_counts)

# MFCL tag flag column 2: 0 includes pre-mixing reporting, 1 excludes it.
rr_draw <- rep(c(0L, 1L), each = n_models / 2L)

effort <- data.frame(
  effort_level = seq_len(5L),
  effort_creep_primary = c(0.005, 0.010, 0.015, 0.020, 0.025),
  effort_creep_secondary = c(0.0025, 0.0050, 0.0075, 0.0100, 0.0125),
  effort_source_file = c(
    "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.005-0.0025.frq",
    "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.01-0.005.frq",
    "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.015-0.0075.frq",
    "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.02-0.01.frq",
    "bet.2026.new-strucure.regional-cpue.wt-as-len-plus-len.eff.creep.0.025-0.0125.frq"
  ),
  source_sha256 = c(
    "c96fe33c6ebc6ecdbb9c2a4fde062102145d90cd7dc8f81bb82ff62176f03b59",
    "e100402b22ae33a2c218781e09957b02aa8c4747bac880f1a7f83150b5b86168",
    "471a84b1e251a7b2879bad73628eee5fcf6931735d033440966f3b1a27db8203",
    "0da5ebd90d9bb95acb17b33397bdaa1c894416616052cb95c423f4f17ea2a487",
    "82c417ca877de61f94b305956d994b1efffd033d496264d46019149842f525a0"
  ),
  stringsAsFactors = FALSE
)
effort_draw <- rep(effort$effort_level, each = n_models / nrow(effort))

cramers_v <- function(x, y) {
  tab <- table(x, y)
  chi <- suppressWarnings(chisq.test(tab, correct = FALSE)$statistic)
  as.numeric(sqrt(chi / (sum(tab) * min(nrow(tab) - 1L, ncol(tab) - 1L))))
}

balance_score <- function(x) {
  numeric_values <- data.frame(
    steepness = h_draw[x$h],
    mixing = mixing_draw[x$mixing],
    rr = rr_draw[x$rr],
    m = m_draw[x$m],
    effort = effort_draw[x$effort]
  )
  correlations <- abs(cor(numeric_values, method = "spearman"))
  diag(correlations) <- 0
  associations <- c(
    max(correlations),
    cramers_v(numeric_values$mixing, numeric_values$rr),
    cramers_v(numeric_values$mixing, numeric_values$effort),
    cramers_v(numeric_values$rr, numeric_values$effort)
  )
  max(associations)
}

# Independently permute each marginal distribution and retain the most balanced
# of 20,000 candidates. This does not alter any marginal draw or exact count.
RNGkind("Mersenne-Twister", "Inversion", "Rejection")
set.seed(design_seed)
best <- NULL
best_score <- Inf
for (iteration in seq_len(20000L)) {
  candidate <- list(
    h = sample.int(n_models),
    mixing = sample.int(n_models),
    rr = sample.int(n_models),
    m = sample.int(n_models),
    effort = sample.int(n_models)
  )
  score <- balance_score(candidate)
  if (score < best_score) {
    best <- candidate
    best_score <- score
  }
}

effort_index <- effort_draw[best$effort]
design <- data.frame(
  ensemble_id = sprintf("ensemble-%03d", seq_len(n_models)),
  steepness = h_draw[best$h],
  steepness_prior_quantile = h_probability[best$h],
  tag_mixing_period = mixing_draw[best$mixing],
  tag_reporting_flag2 = rr_draw[best$rr],
  tag_reporting = ifelse(rr_draw[best$rr] == 0L, "inclusion", "exclusion"),
  m_age40_quarterly = m_draw[best$m],
  lorenzen_log_intercept = log(m_draw[best$m]),
  m_prior_quantile = m_probability[best$m],
  effort_creep_primary = effort$effort_creep_primary[effort_index],
  effort_creep_secondary = effort$effort_creep_secondary[effort_index],
  effort_source_file = effort$effort_source_file[effort_index],
  initialization = "Diagnostic seed-23 path",
  design_seed = design_seed,
  stringsAsFactors = FALSE
)

stopifnot(
  nrow(design) == 100L,
  identical(as.integer(table(design$tag_mixing_period)), mixing_counts),
  identical(as.integer(table(design$tag_reporting_flag2)), c(50L, 50L)),
  identical(as.integer(table(design$effort_creep_primary)), rep(20L, 5L)),
  abs(mean(design$steepness) - h_mean) < 0.001,
  abs(sd(design$steepness) - h_sd) < 0.002,
  abs(min(design$m_age40_quarterly) - m_min) < 1e-12,
  abs(max(design$m_age40_quarterly) - m_max) < 1e-12,
  sum(abs(design$m_age40_quarterly - m_median) < 1e-12) == 2L,
  abs(exp(m_meanlog - m_log_sd^2) - m_mode) < 1e-12,
  abs(m_log_sd - m_log_sd_hamel_cope) < 0.03
)

options(digits = 15)
write.csv(design, file.path(output_dir, "model-draws.csv"), row.names = FALSE, quote = TRUE)
write.csv(effort, file.path(output_dir, "effort-creep-sources.csv"), row.names = FALSE, quote = TRUE)

distribution_parameters <- data.frame(
  axis = c(
    rep("Steepness", 6L),
    rep("Quarterly M at age 40", 7L),
    rep("Design", 3L)
  ),
  parameter = c(
    "lower", "upper", "mean", "sd", "beta_alpha", "beta_beta",
    "lower", "upper", "mode", "conditional_median", "meanlog", "log_sd", "hamel_cope_log_sd",
    "models", "seed", "candidate_permutations"
  ),
  value = c(
    h_lower, h_upper, h_mean, h_sd, h_alpha, h_beta,
    m_min, m_max, m_mode, m_median, m_meanlog, m_log_sd, m_log_sd_hamel_cope,
    n_models, design_seed, 20000L
  ),
  stringsAsFactors = FALSE
)
write.csv(distribution_parameters, file.path(output_dir, "distribution-parameters.csv"),
          row.names = FALSE, quote = TRUE)

continuous_summary <- rbind(
  data.frame(
    axis = "Steepness", distribution = "0.2 + 0.8 * Beta(17.541500, 3.403575)",
    minimum = min(design$steepness), q25 = unname(quantile(design$steepness, 0.25)),
    median = median(design$steepness), mean = mean(design$steepness),
    q75 = unname(quantile(design$steepness, 0.75)), maximum = max(design$steepness),
    sd = sd(design$steepness)
  ),
  data.frame(
    axis = "Quarterly M at age 40",
    distribution = sprintf("Truncated lognormal(0.050, 0.165; mode 0.0702; log-SD %.6f)", m_log_sd),
    minimum = min(design$m_age40_quarterly), q25 = unname(quantile(design$m_age40_quarterly, 0.25)),
    median = median(design$m_age40_quarterly), mean = mean(design$m_age40_quarterly),
    q75 = unname(quantile(design$m_age40_quarterly, 0.75)), maximum = max(design$m_age40_quarterly),
    sd = sd(design$m_age40_quarterly)
  )
)
write.csv(continuous_summary, file.path(output_dir, "continuous-summary.csv"), row.names = FALSE, quote = TRUE)

discrete_summary <- rbind(
  data.frame(axis = "Tag mixing period", level = names(table(design$tag_mixing_period)),
             count = as.integer(table(design$tag_mixing_period))),
  data.frame(axis = "Tag reporting", level = names(table(design$tag_reporting)),
             count = as.integer(table(design$tag_reporting))),
  data.frame(axis = "Effort creep", level = sprintf("%.1f%% / %.2f%%",
             100 * effort$effort_creep_primary, 100 * effort$effort_creep_secondary),
             count = as.integer(table(factor(design$effort_creep_primary,
                                             levels = effort$effort_creep_primary))))
)
discrete_summary$proportion <- discrete_summary$count / n_models
write.csv(discrete_summary, file.path(output_dir, "discrete-summary.csv"), row.names = FALSE, quote = TRUE)

numeric_design <- data.frame(
  steepness = design$steepness,
  mixing = design$tag_mixing_period,
  reporting_flag2 = design$tag_reporting_flag2,
  m_age40_quarterly = design$m_age40_quarterly,
  effort_primary = design$effort_creep_primary
)
rank_correlation <- cor(numeric_design, method = "spearman")
write.csv(rank_correlation, file.path(output_dir, "rank-correlation.csv"), quote = TRUE)

png(file.path(output_dir, "distributions.png"), width = 2200, height = 1250, res = 180)
old_par <- par(no.readonly = TRUE)
par(mfrow = c(2, 3), mar = c(4.5, 4.6, 3.0, 1.0), las = 1,
    cex.axis = 0.85, cex.lab = 0.95, cex.main = 1.0)
hist(design$steepness, breaks = seq(0.65, 1.00, by = 0.025), col = "#2C7FB8",
     border = "white", main = "Steepness", xlab = "h")
abline(v = h_mean, col = "#D7301F", lwd = 2)
barplot(table(factor(design$tag_mixing_period, levels = mixing_levels)),
        names.arg = format(mixing_levels, trim = TRUE), col = "#41AB5D", border = NA,
        main = "Tag mixing period", xlab = "Mixing period", ylab = "Models")
barplot(table(factor(design$tag_reporting, levels = c("inclusion", "exclusion"))),
        col = c("#756BB1", "#9E9AC8"), border = NA,
        main = "Tag reporting", ylab = "Models")
hist(design$m_age40_quarterly, breaks = seq(m_min, m_max, length.out = 13L),
     col = "#F28E2B", border = "white", main = "Natural mortality", xlab = expression(M[age~40]~(quarter^{-1})))
abline(v = m_mode, col = "#D7301F", lwd = 2)
abline(v = m_median, col = "#222222", lwd = 2, lty = 2)
effort_names <- sprintf("%.1f/%.2f", 100 * effort$effort_creep_primary,
                        100 * effort$effort_creep_secondary)
barplot(table(factor(design$effort_creep_primary, levels = effort$effort_creep_primary)),
        names.arg = effort_names, col = "#4E79A7", border = NA,
        main = "Effort creep", xlab = "Primary / secondary (%)", ylab = "Models")
plot.new()
text(0, 0.90, "BET 2026 joint ensemble", adj = c(0, 0), font = 2, cex = 1.25)
text(0, 0.72, "100 deterministic balanced draws", adj = c(0, 0), cex = 1.0)
text(0, 0.56, paste0("Design seed: ", design_seed), adj = c(0, 0), cex = 0.95)
text(0, 0.40, sprintf("Maximum balance score: %.3f", best_score), adj = c(0, 0), cex = 0.95)
text(0, 0.24, "Discrete margins are exact; continuous margins use quantiles.",
     adj = c(0, 0), cex = 0.85)
par(old_par)
dev.off()

cat("Created ", n_models, " ensemble draws in ", output_dir, "\n", sep = "")
cat(sprintf("Steepness: mean %.4f, SD %.4f, range %.4f-%.4f\n",
            mean(design$steepness), sd(design$steepness),
            min(design$steepness), max(design$steepness)))
cat(sprintf("Quarterly M at age 40: mean %.4f, median %.5f, mode %.4f, range %.3f-%.3f\n",
            mean(design$m_age40_quarterly), median(design$m_age40_quarterly), m_mode,
            min(design$m_age40_quarterly), max(design$m_age40_quarterly)))
cat(sprintf("M log-SD: %.6f (Hamel-Cope reference: %.2f)\n",
            m_log_sd, m_log_sd_hamel_cope))
cat(sprintf("Maximum balance score: %.4f\n", best_score))
