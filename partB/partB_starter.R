# =============================================================================
# partB_starter.R - Part B: forecasting next-week volatility (RQ1, RQ2)
#
#   source("partB/partB_starter.R")     (run from the project folder in RStudio)
#
# A working first version that Part B builds on. It
#   1. loads the shared file data/features_daily.csv (made by Part A),
#   2. builds the HAR-RV inputs (daily, weekly, monthly volatility),
#   3. fits each model twice - price features only vs. price + news features,
#   4. compares them on the test years 2022-2023 (RMSE, QLIKE, Diebold-Mariano test),
#   5. saves the results to outputs/part_b/.
# Models: HAR-RV (linear regression), regression tree, Random Forest, boosting.
# =============================================================================

options(repos = c(CRAN = "https://cloud.r-project.org"))
for (p in c("data.table", "rpart", "randomForest", "gbm"))
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
suppressPackageStartupMessages({ library(data.table); library(rpart); library(randomForest); library(gbm) })
set.seed(582)
OUT <- "outputs/part_b"; dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

# ---- 1. Data ------------------------------------------------------------------
df <- fread("data/features_daily.csv")
setorder(df, ticker, date)
df[, vol_lag22 := frollmean(gk_vol, 22), by = ticker]          # monthly volatility (HAR-RV)
df[, abs_ret := abs(ret)]
df <- df[data_error == 0 & !is.na(vol_next5) & !is.na(vol_lag22) & !is.na(ret)]

train <- df[date <= as.IDate("2020-12-31")]
valid <- df[date >= as.IDate("2021-01-01") & date <= as.IDate("2021-12-31")]   # use this to tune settings
test  <- df[date >= as.IDate("2022-01-01")]
cat(sprintf("train %d rows | valid %d | test %d\n", nrow(train), nrow(valid), nrow(test)))

# ---- 2. Feature sets (the same for every model) --------------------------------
PRICE <- c("gk_vol", "vol_lag5", "vol_lag22", "abs_ret")
NEWS  <- c("sent_mean", "neg_share", "pos_share", "n_articles", "no_news")
# When Part A adds FinBERT, try: NEWS <- c("fb_sent_mean", "fb_neg_share", "fb_pos_share", "n_articles", "no_news")
f_price <- reformulate(PRICE, "vol_next5")
f_news  <- reformulate(c(PRICE, NEWS), "vol_next5")

# ---- 3. Error measures -----------------------------------------------------------
rmse  <- function(y, p) sqrt(mean((y - p)^2))
qlike <- function(y, p) { p <- pmax(p, 1e-6); mean(y^2 / p^2 - log(y^2 / p^2) - 1) }   # Patton (2011), on variances
dm_p  <- function(y, p1, p2) {           # Diebold-Mariano test on squared errors: is model 2 better than model 1?
  d <- (y - p1)^2 - (y - p2)^2
  n <- length(d); h <- 5                 # 5-day overlapping target -> Newey-West variance with 5 lags
  g <- sapply(0:(h - 1), function(k) sum((d[(k + 1):n] - mean(d)) * (d[1:(n - k)] - mean(d))) / n)
  v <- g[1] + 2 * sum(g[-1]); stat <- mean(d) / sqrt(v / n)
  2 * pnorm(-abs(stat))
}

# ---- 4. Models ------------------------------------------------------------------
fit_predict <- list(
  "HAR-RV (linear regression)" = function(f) predict(lm(f, data = train), test),
  "Regression tree"            = function(f) predict(rpart(f, data = train, control = rpart.control(cp = 0.001)), test),
  "Random Forest"              = function(f) predict(randomForest(f, data = train[sample(.N, min(.N, 20000))],
                                                                  ntree = 200, nodesize = 50), test),
  "Boosting (gbm)"             = function(f) predict(gbm(f, data = train, distribution = "gaussian", n.trees = 300,
                                                         interaction.depth = 3, shrinkage = 0.05, verbose = FALSE),
                                                     test, n.trees = 300)
)

res <- rbindlist(lapply(names(fit_predict), function(m) {
  cat("Fitting", m, "...\n")
  p0 <- fit_predict[[m]](f_price); p1 <- fit_predict[[m]](f_news)
  test[, `:=`(pred_price = p0, pred_news = p1)]
  by_sector <- test[, .(rmse_price = rmse(vol_next5, pred_price), rmse_news = rmse(vol_next5, pred_news),
                        qlike_price = qlike(vol_next5, pred_price), qlike_news = qlike(vol_next5, pred_news)), by = sector]
  all <- test[, .(sector = "All", rmse_price = rmse(vol_next5, pred_price), rmse_news = rmse(vol_next5, pred_news),
                  qlike_price = qlike(vol_next5, pred_price), qlike_news = qlike(vol_next5, pred_news))]
  out <- rbind(all, by_sector)
  out[, `:=`(model = m, rmse_change_pct = 100 * (rmse_news - rmse_price) / rmse_price,
             dm_p_value = c(dm_p(test$vol_next5, p0, p1),
                            sapply(by_sector$sector, function(s) test[sector == s, dm_p(vol_next5, pred_price, pred_news)])))]
  out
}))
setcolorder(res, c("model", "sector"))
print(res, digits = 4)
fwrite(res, file.path(OUT, "01_forecast_results.csv"))

# ---- 5. Which features matter? (HAR-RV with news, coefficients) -------------------
coefs <- as.data.table(summary(lm(f_news, data = train))$coefficients, keep.rownames = "term")
print(coefs, digits = 3)
fwrite(coefs, file.path(OUT, "02_har_rv_news_coefficients.csv"))
cat("\nSaved results to", OUT, "\n",
    "rmse_change_pct < 0 means the news features improved the forecast;",
    "dm_p_value < 0.05 means the difference is statistically significant.\n")
