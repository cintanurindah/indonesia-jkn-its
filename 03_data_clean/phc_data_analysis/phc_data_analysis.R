# Out-of-pocket share, catastrophic spending and primary care spending after
# Indonesia's national health insurance: an interrupted time series analysis, 2000-2019
# Segmented regression, interruption = 2014 (JKN launch)
# Cinta Nurindah Sari

library(tidyverse)
library(readxl)
library(sandwich)
library(lmtest)
library(nlme)

dat <- read_excel("../phc_master_file_v2.xlsx") %>%
  arrange(year) %>%
  transmute(
    year,
    phc_share = phc_share_mil * 100,
    oop  = oop_share * 100,
    # WHO's CHE estimates switch to a reprocessed Susenas series from 2019
    # (IDN_2019_SUSENAS-CC2), and the Sept 2019 Susenas changed the OOP questions
    che  = if_else(year <= 2018, che_incidence * 100, NA_real_),
    dpt3 = dpt3_coverage * 100,
    mcv1 = mcv1_coverage * 100,
    nmr  = nmr * 100,   # stored per 100 live births in the master file
    imr  = imr * 100
  )

outcomes <- tribble(
  ~var,        ~label,                                        ~logged,
  "phc_share", "PHC share of health spending (%)",            FALSE,
  "oop",       "Out-of-pocket share of health spending (%)",  FALSE,
  "che",       "Catastrophic health spending >10% (% pop.)",  FALSE,
  "dpt3",      "DPT3 coverage (%)",                           FALSE,
  "mcv1",      "MCV1 coverage (%)",                           FALSE,
  "nmr",       "Neonatal mortality (per 1000 live births)",   TRUE,
  "imr",       "Infant mortality (per 1000 live births)",     TRUE
)

its_data <- function(var, logged = FALSE, start = 2014, from = 2000, to = 2019) {
  dat %>%
    filter(between(year, from, to)) %>%
    mutate(y = .data[[var]],
           t = year - 2000,
           post = as.numeric(year >= start),
           t_post = pmax(0, year - start)) %>%
    filter(!is.na(y)) %>%
    mutate(y = if (logged) log(y) else y)
}


# Descriptives ------------------------------------------------------------

table1 <- outcomes %>%
  mutate(d = map(var, ~ dat %>% select(year, y = all_of(.x)) %>% drop_na())) %>%
  transmute(
    Outcome = label,
    Years = map_int(d, nrow),
    `2000` = map_dbl(d, ~ .x$y[.x$year == 2000][1]),
    `Mean 2000-2013` = map_dbl(d, ~ mean(.x$y[.x$year < 2014])),
    `2013` = map_dbl(d, ~ .x$y[.x$year == 2013][1]),
    `Mean 2014-2019` = map_dbl(d, ~ mean(.x$y[.x$year >= 2014])),
    `2019` = map_dbl(d, ~ .x$y[.x$year == 2019][1])
  ) %>%
  mutate(across(where(is.double), ~ round(.x, 2)))

table1


# ITS models --------------------------------------------------------------

# y = b0 + b1*t + b2*post + b3*t_post
# b2 = level change in 2014, b3 = change in annual trend after 2014
#
# Main model: GLS with AR(1) errors, which handles autocorrelation better than
# OLS + Newey-West in short series (Turner et al. 2021, BMC Med Res Methodol).
# Fitted by ML because REML pushed rho to the boundary (1.0) for DPT3, MCV1
# and NMR. Sensitivity: OLS with Newey-West SEs, 2015 as the interruption, and
# a shorter pre-period (2005 onwards). Placebo: fake interruptions in 2006-2011
# using pre-JKN years only.

its_model <- function(d, method) {
  if (method == "ar1") {
    m <- gls(y ~ t + post + t_post, data = d,
             correlation = corAR1(form = ~ t), method = "ML")
    list(b = coef(m), V = vcov(m),
         rho = coef(m$modelStruct$corStruct, unconstrained = FALSE)[[1]])
  } else {
    m <- lm(y ~ t + post + t_post, data = d)
    list(b = coef(m), V = NeweyWest(m, lag = 1, prewhite = FALSE),
         rho = NA_real_)
  }
}

its_fit <- function(var, logged = FALSE, start = 2014, method = "ar1",
                    from = 2000, to = 2019) {
  d <- its_data(var, logged, start, from, to)
  fit <- its_model(d, method)

  L <- rbind(pre_trend = c(0, 1, 0, 0),
             level     = c(0, 0, 1, 0),
             slope     = c(0, 0, 0, 1))

  est <- drop(L %*% fit$b)
  se  <- sqrt(diag(L %*% fit$V %*% t(L)))
  df  <- nrow(d) - 4
  q   <- qt(0.975, df)

  res <- tibble(term = rownames(L), est, lo = est - q * se, hi = est + q * se,
                p = 2 * pt(-abs(est / se), df), n = nrow(d), rho = fit$rho)

  # log outcomes reported as % change
  if (logged) res <- res %>% mutate(across(c(est, lo, hi), ~ 100 * (exp(.x) - 1)))
  res
}

fmt <- function(est, lo, hi) sprintf("%.2f (%.2f, %.2f)", est, lo, hi)

run_all <- function(...) {
  outcomes %>%
    mutate(res = map2(var, logged, function(v, lg) its_fit(v, lg, ...))) %>%
    unnest(res)
}

main <- run_all()

table2 <- main %>%
  mutate(value = fmt(est, lo, hi)) %>%
  select(Outcome = label, n, rho, term, value) %>%
  pivot_wider(names_from = term, values_from = value) %>%
  transmute(Outcome, n,
            `Pre-JKN trend per year` = pre_trend,
            `Level change in 2014` = level,
            `Trend change per year` = slope,
            `AR(1) rho` = round(rho, 2))

table2


# Sensitivity -------------------------------------------------------------

sens <- bind_rows(
  main %>% mutate(model = "GLS AR(1), 2014 (main)"),
  run_all(method = "nw") %>% mutate(model = "OLS Newey-West, 2014"),
  run_all(start = 2015) %>% mutate(model = "GLS AR(1), 2015"),
  run_all(from = 2005) %>% mutate(model = "GLS AR(1), 2014, data from 2005")
)

level_slope_table <- function(x, group) {
  x %>%
    filter(term %in% c("level", "slope")) %>%
    mutate(value = fmt(est, lo, hi),
           term = recode(term, level = "Level change", slope = "Trend change per year")) %>%
    select(Outcome = label, all_of(group), term, value) %>%
    pivot_wider(names_from = term, values_from = value) %>%
    arrange(factor(Outcome, levels = outcomes$label))
}

tableS1 <- sens %>% rename(Model = model) %>% level_slope_table("Model")
tableS1

placebo <- map_dfr(2006:2011, ~ run_all(start = .x, to = 2013) %>% mutate(start = .x))

tableS2 <- placebo %>%
  rename(`Placebo interruption` = start) %>%
  level_slope_table("Placebo interruption")
tableS2


# Figure ------------------------------------------------------------------

fig_data <- outcomes %>%
  mutate(d = map2(var, logged, function(v, lg) {
    d <- its_data(v, lg)
    b <- its_model(d, "ar1")$b
    back <- if (lg) exp else identity
    d %>% mutate(observed = back(y),
                 fitted = back(b[1] + b[2] * t + b[3] * post + b[4] * t_post),
                 counterfactual = if_else(year >= 2013, back(b[1] + b[2] * t), NA_real_))
  })) %>%
  select(label, d) %>%
  unnest(d) %>%
  mutate(label = factor(label, levels = outcomes$label),
         period = if_else(year >= 2014, "post", "pre"))

fig1 <- ggplot(fig_data, aes(year)) +
  annotate("rect", xmin = 2013.5, xmax = 2019.5, ymin = -Inf, ymax = Inf,
           fill = "grey92") +
  geom_point(aes(y = observed), size = 1.6, colour = "grey30") +
  geom_line(aes(y = fitted, group = period), colour = "#1f4e79", linewidth = 0.8) +
  geom_line(aes(y = counterfactual), colour = "#1f4e79", linetype = "dashed",
            linewidth = 0.6, na.rm = TRUE) +
  # wider y range for PHC share so 0.1-point wiggles don't look like real change
  geom_blank(data = tibble(year = 2000, observed = c(38, 42),
                           label = factor(outcomes$label[1], levels = outcomes$label)),
             aes(y = observed)) +
  facet_wrap(~ label, scales = "free_y", ncol = 3) +
  scale_x_continuous(breaks = seq(2000, 2020, 5)) +
  labs(x = NULL, y = NULL) +
  theme_bw(base_size = 10) +
  theme(panel.grid.minor = element_blank(),
        strip.background = element_blank(),
        strip.text = element_text(face = "bold", hjust = 0))

fig1


# Save --------------------------------------------------------------------

write_csv(table1, "../../05_results/table1_descriptives.csv")
write_csv(table2, "../../05_results/table2_its_main.csv")
write_csv(tableS1, "../../05_results/tableS1_sensitivity.csv")
write_csv(tableS2, "../../05_results/tableS2_placebo.csv")
write_csv(sens %>% select(model, var, term, est, lo, hi, p, n, rho),
          "../../05_results/its_estimates_all.csv")

ggsave("../../06_outputs/fig1_its.png", fig1, width = 9, height = 7, dpi = 300)
ggsave("../../06_outputs/fig1_its.pdf", fig1, width = 9, height = 7)
