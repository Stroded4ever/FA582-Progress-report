# =============================================================================
# partB_week2.R - Validation tuning, forecast evaluation, and figures (RQ1/RQ2)
# Run from the fa582-sentiment-volatility project root in RStudio:
#   source("partB/partB_week2.R")
#
# Keeps partB_starter.R unchanged. Requires its original data/features_daily.csv.
# Tuning decisions use 2021 only; 2022-2023 is used for final evaluation.
# =============================================================================

options(repos = c(CRAN = "https://cloud.r-project.org"))
for (p in c("data.table", "rpart", "randomForest", "gbm")) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
}
suppressPackageStartupMessages({
  library(data.table)
  library(rpart)
  library(randomForest)
  library(gbm)
})

set.seed(582)
OUT <- "outputs/part_b"
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

# 1. Read data and reproduce the starter's predictors.
df <- fread("data/features_daily.csv")
df[, date := as.IDate(date)]
setorder(df, ticker, date)
df[, vol_lag22 := frollmean(gk_vol, 22), by = ticker]
df[, abs_ret := abs(ret)]
df <- df[data_error == 0 & !is.na(vol_next5) & !is.na(vol_lag22) & !is.na(ret)]

PRICE <- c("gk_vol", "vol_lag5", "vol_lag22", "abs_ret")
NEWS  <- c("sent_mean", "neg_share", "pos_share", "n_articles", "no_news")
stopifnot(all(c("ticker", "sector", "vol_next5", PRICE, NEWS) %in% names(df)))

f_price <- reformulate(PRICE, response = "vol_next5")
f_news  <- reformulate(c(PRICE, NEWS), response = "vol_next5")

train <- df[date <= as.IDate("2020-12-31")]
valid <- df[date >= as.IDate("2021-01-01") & date <= as.IDate("2021-12-31")]
test  <- df[date >= as.IDate("2022-01-01") & date <= as.IDate("2023-12-31")]
cat(sprintf("Raw split: train %d | valid %d | test %d\n",
            nrow(train), nrow(valid), nrow(test)))

# Each target includes 5 *future* trading days. Drop the last 5 rows per ticker
# at every tuning/test boundary so targets used for training or validation do
# not extend into the following period.
purge_last5 <- function(x) {
  x[, .SD[seq_len(max(0L, .N - 5L))], by = ticker]
}
train_tune <- purge_last5(train)
valid_tune <- purge_last5(valid)
final_train <- purge_last5(df[date < as.IDate("2022-01-01")])

cat(sprintf("Purged tuning split: train %d | valid %d\n",
            nrow(train_tune), nrow(valid_tune)))
cat(sprintf("Final pretest fit %d | test %d\n", nrow(final_train), nrow(test)))
stopifnot(nrow(train_tune) > 0L, nrow(valid_tune) > 0L, nrow(test) > 0L)

# The starter deliberately trains Random Forest on at most 20,000 rows.
# Use one fixed row sample in all tuning comparisons and a fixed sample again
# when refitting on the pretest data.
set.seed(582)
rf_train_tune <- train_tune[sample.int(nrow(train_tune), min(20000L, nrow(train_tune)))]
set.seed(582)
rf_train_final <- final_train[sample.int(nrow(final_train), min(20000L, nrow(final_train)))]

rmse <- function(y, p) sqrt(mean((y - p)^2))
qlike <- function(y, p) {
  # QLIKE on variance proxies, with numerical guards for zero volatility.
  realized_variance <- pmax(y^2, 1e-12)
  forecast_variance <- pmax(p, 1e-6)^2
  ratio <- realized_variance / forecast_variance
  mean(ratio - log(ratio) - 1)
}

# Date-aggregated, two-sided loss-differential test with Bartlett-HAC lags 0..4.
# Pooling ticker-major rows as one series (as in the starter) misses the
# cross-stock correlation on the same date. Aggregating by date first helps
# address that dependence. Treat p-values as approximate diagnostics.
dm_date_hac <- function(x, h = 5L) {
  daily <- x[, .(d = mean((actual - pred_price)^2 -
                            (actual - pred_news)^2)), by = date][order(date)]
  d <- daily$d
  n <- length(d)
  if (n < 20L || any(!is.finite(d))) return(NA_real_)
  centered <- d - mean(d)
  lag_max <- min(h - 1L, n - 1L)
  gammas <- vapply(0:lag_max, function(k) {
    if (k == 0L) mean(centered^2)
    else sum(centered[(k + 1L):n] * centered[seq_len(n - k)]) / n
  }, numeric(1))
  weights <- 1 - seq_len(lag_max) / (lag_max + 1L)
  long_run_variance <- gammas[1L] + 2 * sum(weights * gammas[-1L])
  if (!is.finite(long_run_variance) || long_run_variance <= 0) return(NA_real_)
  z <- mean(d) / sqrt(long_run_variance / n)
  2 * pnorm(-abs(z))
}

# 2. All model fitting is performed on the dataset provided as an argument.
fit_model <- function(model, formula, training_data, pars) {
  if (model == "HAR-RV (linear regression)") {
    return(lm(formula, data = training_data))
  }
  if (model == "Regression tree") {
    return(rpart(formula, data = training_data,
                 control = rpart.control(cp = pars$cp, xval = 0)))
  }
  if (model == "Random Forest") {
    return(randomForest(formula, data = training_data,
                        ntree = pars$ntree, mtry = pars$mtry,
                        nodesize = 50, importance = TRUE))
  }
  if (model == "Boosting (gbm)") {
    return(gbm(formula, data = as.data.frame(training_data),
               distribution = "gaussian", n.trees = pars$n.trees,
               interaction.depth = 3, shrinkage = pars$shrinkage,
               verbose = FALSE))
  }
  stop("Unknown model: ", model)
}

predict_model <- function(model, fitted, new_data, pars) {
  if (model == "Boosting (gbm)") {
    return(as.numeric(predict(fitted, newdata = as.data.frame(new_data),
                              n.trees = pars$n.trees)))
  }
  as.numeric(predict(fitted, newdata = new_data))
}

fit_pair <- function(model, training_data, evaluation_data, pars, rf_sample) {
  fit_data <- if (model == "Random Forest") rf_sample else training_data
  set.seed(582)
  price_model <- fit_model(model, f_price, fit_data, pars)
  set.seed(582)
  news_model <- fit_model(model, f_news, fit_data, pars)
  p0 <- predict_model(model, price_model, evaluation_data, pars)
  p1 <- predict_model(model, news_model, evaluation_data, pars)
  stopifnot(length(p0) == nrow(evaluation_data),
            length(p1) == nrow(evaluation_data),
            all(is.finite(p0)), all(is.finite(p1)))
  list(price_model = price_model, news_model = news_model,
       p0 = p0, p1 = p1)
}

# 3. Candidate grids. Use the SAME configuration for the price and news
# versions of each model. The selection criterion is their mean validation RMSE.
grids <- list(
  "HAR-RV (linear regression)" = data.table(configuration = "baseline"),
  "Regression tree" = data.table(cp = c(0.0005, 0.001, 0.005, 0.01)),
  "Random Forest" = CJ(ntree = c(200L, 400L), mtry = c(2L, 3L, 4L)),
  "Boosting (gbm)" = CJ(n.trees = c(300L, 600L),
                        shrinkage = c(0.02, 0.05))
)

# WARNING: do NOT inspect 2022-2023 for model selection.
tuning_rows <- list()
for (model in names(grids)) {
  grid <- grids[[model]]
  for (i in seq_len(nrow(grid))) {
    pars <- as.list(grid[i])
    cat(sprintf("Tuning %-28s config %d/%d\n", model, i, nrow(grid)))
    fitted <- fit_pair(model, train_tune, valid_tune, pars, rf_train_tune)
    y <- valid_tune$vol_next5
    r0 <- rmse(y, fitted$p0)
    r1 <- rmse(y, fitted$p1)
    tuning_rows[[length(tuning_rows) + 1L]] <- cbind(
      data.table(model = model), grid[i],
      data.table(validation_rmse_price = r0,
                 validation_rmse_news = r1,
                 validation_rmse_mean = (r0 + r1) / 2)
    )
  }
}

tuning <- rbindlist(tuning_rows, fill = TRUE)
setorder(tuning, model, validation_rmse_mean)
fwrite(tuning, file.path(OUT, "03_week2_tuning_results.csv"))

best <- tuning[, .SD[1L], by = model]
cat("\nSelected configurations based only on 2021 validation RMSE:\n")
print(best)
fwrite(best, file.path(OUT, "04_week2_selected_parameters.csv"))

# 4. Final refit on pretest data, then evaluate on 2022-2023 exactly once.
results_list <- list()
predictions_list <- list()
for (model in names(grids)) {
  pars <- as.list(best[best[["model"]] == model][1L])
  cat("Final refit and test:", model, "\n")
  fitted <- fit_pair(model, final_train, test, pars, rf_train_final)
  pred <- data.table(model = model, ticker = test$ticker, date = test$date,
                     sector = test$sector, actual = test$vol_next5,
                     pred_price = fitted$p0, pred_news = fitted$p1)
  predictions_list[[model]] <- pred

  sectors <- c("All", sort(unique(test$sector)))
  results_list[[model]] <- rbindlist(lapply(sectors, function(sector_name) {
    x <- if (sector_name == "All") pred else pred[sector == sector_name]
    price_rmse <- rmse(x$actual, x$pred_price)
    news_rmse <- rmse(x$actual, x$pred_news)
    data.table(model = model, sector = sector_name,
               rmse_price = price_rmse, rmse_news = news_rmse,
               qlike_price = qlike(x$actual, x$pred_price),
               qlike_news = qlike(x$actual, x$pred_news),
               rmse_change_pct = 100 * (news_rmse - price_rmse) / price_rmse,
               dm_date_hac_p_value = dm_date_hac(x))
  }))

  # Feature importance from the final news-augmented fitted models.
  if (model == "Random Forest") {
    imp <- randomForest::importance(fitted$news_model, type = 1)
    imp_df <- data.table(feature = rownames(imp),
                         importance = as.numeric(imp[, 1L]))
    setorder(imp_df, -importance)
    fwrite(imp_df, file.path(OUT, "06_week2_rf_importance.csv"))
  }
  if (model == "Boosting (gbm)") {
    imp <- summary(fitted$news_model, n.trees = pars$n.trees, plotit = FALSE)
    imp_df <- data.table(feature = imp$var, importance = imp$rel.inf)
    setorder(imp_df, -importance)
    fwrite(imp_df, file.path(OUT, "07_week2_gbm_importance.csv"))
  }
}

results <- rbindlist(results_list)
predictions <- rbindlist(predictions_list)
setorder(predictions, model, sector, date, ticker)
print(results, digits = 5)
fwrite(results, file.path(OUT, "05_week2_tuned_forecast_results.csv"))
fwrite(predictions, file.path(OUT, "08_week2_test_predictions.csv"))

# 5. Sector-level average actual versus predicted volatility over time.
# These are equal-weight averages across the stocks in each sector on each day.
for (model_name in names(grids)) {
  for (sector_name in sort(unique(predictions$sector))) {
    p <- predictions[model == model_name & sector == sector_name]
    chart_dt <- p[, .(actual = mean(actual),
                      price = mean(pred_price),
                      news = mean(pred_news)), by = date][order(date)]
    slug <- function(z) gsub("_+$", "", gsub("[^a-z0-9]+", "_", tolower(z)))
    path <- file.path(OUT, sprintf("plot_%s_%s.png", slug(model_name), slug(sector_name)))
    png(path, width = 1400, height = 720, res = 140)
    plot(as.Date(chart_dt$date), chart_dt$actual,
         type = "l", col = "black", lwd = 2,
         ylim = range(c(chart_dt$actual, chart_dt$price, chart_dt$news)),
         xlab = "Trading date", ylab = "Volatility",
         main = paste(model_name, "-", sector_name))
    lines(as.Date(chart_dt$date), chart_dt$price, col = "steelblue", lwd = 1.4)
    lines(as.Date(chart_dt$date), chart_dt$news, col = "darkorange", lwd = 1.4)
    legend("topright", legend = c("Actual", "Price only", "Price + news"),
           col = c("black", "steelblue", "darkorange"), lty = 1,
           lwd = c(2, 1.4, 1.4), bty = "n")
    dev.off()
  }
}

# 6. Feature importance figures (rankings of the news-augmented pooled models).
importance_plot <- function(filename, title, output_file) {
  x <- fread(file.path(OUT, filename))
  x <- x[order(importance)]
  png(file.path(OUT, output_file), width = 1100, height = 700, res = 140)
  par(mar = c(5, 10, 4, 2))
  barplot(x$importance, names.arg = x$feature, horiz = TRUE,
          las = 1, col = "steelblue", cex.names = 0.9,
          main = title, xlab = "Importance (within-model measure)")
  dev.off()
}
importance_plot("06_week2_rf_importance.csv",
                "Random Forest permutation importance (price + news)",
                "plot_random_forest_importance.png")
importance_plot("07_week2_gbm_importance.csv",
                "Boosting relative influence (price + news)",
                "plot_boosting_importance.png")

cat("\nFinished. Results and 10 figures saved in: ", OUT, "\n", sep = "")
cat("Files 03 and 04: validation tuning; file 05: tuned test results;",
    " file 08: forecast-level predictions.\n")
cat("Test p-values use date-level Bartlett-HAC and are not directly",
    " comparable to the starter's pooled-row DM p-values.\n")
