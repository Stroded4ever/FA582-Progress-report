# =============================================================================
# partC_starter.R - Part C: classifying high-volatility weeks (RQ3) + clustering
#
#   source("partC/partC_starter.R")     (run from the project folder in RStudio)
#
# A working first version that Part C builds on, following the Lecture 5 example
# (LDA, QDA and KNN for a High / Low volatility regime). It
#   1. loads the shared file data/features_daily.csv (made by Part A),
#   2. fits logistic regression, LDA, QDA, KNN and a classification tree,
#      each with price features only vs. price + news features,
#   3. tunes k (KNN) and the probability threshold on 2021 (validation),
#   4. reports accuracy, sensitivity, specificity, Brier score on 2022-2023 (test),
#   5. clusters trading days into market regimes with PCA + k-means and hierarchical clustering,
#   6. saves the results to outputs/part_c/.
# =============================================================================

options(repos = c(CRAN = "https://cloud.r-project.org"))
for (p in c("data.table", "MASS", "class", "rpart"))
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
suppressPackageStartupMessages({ library(data.table); library(MASS); library(class); library(rpart) })
set.seed(582)
OUT <- "outputs/part_c"; dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

# ---- 1. Data ------------------------------------------------------------------
df <- fread("data/features_daily.csv")
setorder(df, ticker, date)
df[, vol_lag22 := frollmean(gk_vol, 22), by = ticker]
# volatility is roughly log-normal -> log features (as in the Lecture 5 code)
df[, `:=`(log_vol = log(pmax(gk_vol, 1e-6)), log_vol5 = log(pmax(vol_lag5, 1e-6)),
          log_vol22 = log(pmax(vol_lag22, 1e-6)), abs_ret = abs(ret))]
df <- df[data_error == 0 & !is.na(high_vol) & !is.na(vol_lag22) & !is.na(ret)]
df[, high_vol := factor(high_vol, levels = c(0, 1), labels = c("Low", "High"))]

train <- df[date <= as.IDate("2020-12-31")]
valid <- df[date >= as.IDate("2021-01-01") & date <= as.IDate("2021-12-31")]
test  <- df[date >= as.IDate("2022-01-01")]
cat(sprintf("train %d | valid %d | test %d | share of High weeks: train %.2f, test %.2f\n",
            nrow(train), nrow(valid), nrow(test), mean(train$high_vol == "High"), mean(test$high_vol == "High")))

PRICE <- c("log_vol", "log_vol5", "log_vol22", "abs_ret")
NEWS  <- c("sent_mean", "neg_share", "pos_share", "n_articles", "no_news")
# When Part A adds FinBERT, try: NEWS <- c("fb_sent_mean", "fb_neg_share", "fb_pos_share", "n_articles", "no_news")

# ---- 2. Helpers ---------------------------------------------------------------------
fml <- function(v) reformulate(v, "high_vol")
metrics <- function(p_high, truth, thr) {
  y <- as.integer(truth == "High"); yhat <- as.integer(p_high > thr)
  data.table(accuracy = mean(yhat == y), sensitivity = mean(yhat[y == 1] == 1),
             specificity = mean(yhat[y == 0] == 0), brier = mean((p_high - y)^2), threshold = thr)
}
best_threshold <- function(p_high, truth) {          # pick the threshold that maximizes balanced accuracy on 2021
  ths <- seq(0.1, 0.9, by = 0.05)
  ba <- sapply(ths, function(t) { m <- metrics(p_high, truth, t); (m$sensitivity + m$specificity) / 2 })
  ths[which.max(ba)]
}
knn_prob <- function(trn, new, vars, k) {           # standardize with TRAINING means/SDs only
  mu <- sapply(trn[, ..vars], mean); s <- sapply(trn[, ..vars], sd)
  zt <- scale(trn[, ..vars], mu, s); zn <- scale(new[, ..vars], mu, s)
  cl <- knn(zt, zn, cl = trn$high_vol, k = k, prob = TRUE)
  ifelse(cl == "High", attr(cl, "prob"), 1 - attr(cl, "prob"))
}
knn_train <- train[sample(.N, min(.N, 15000))]       # KNN is slow on very large data; subsample training rows

models <- list(
  "Logistic regression" = function(v, new) predict(glm(fml(v), data = train, family = binomial), new, type = "response"),
  "LDA"                 = function(v, new) predict(lda(fml(v), data = train), new)$posterior[, "High"],
  "QDA"                 = function(v, new) predict(qda(fml(v), data = train), new)$posterior[, "High"],
  "Classification tree" = function(v, new) predict(rpart(fml(v), data = train, method = "class",
                                                         control = rpart.control(cp = 0.001)), new)[, "High"]
)

# ---- 3. Fit, tune on 2021, evaluate on 2022-2023 -------------------------------------
res <- list()
for (set in c("price only", "price + news")) {
  v <- if (set == "price only") PRICE else c(PRICE, NEWS)
  for (m in names(models)) {
    cat("Fitting", m, "-", set, "...\n")
    thr <- best_threshold(models[[m]](v, valid), valid$high_vol)
    res[[length(res) + 1]] <- cbind(model = m, features = set, metrics(models[[m]](v, test), test$high_vol, thr))
  }
  # KNN: tune k on the 2021 validation year (time-ordered, as in Lecture 5)
  ks <- c(5, 15, 25, 51, 101)
  auc_like <- sapply(ks, function(k) { p <- knn_prob(knn_train, valid, v, k)
    m <- metrics(p, valid$high_vol, best_threshold(p, valid$high_vol)); (m$sensitivity + m$specificity) / 2 })
  k_best <- ks[which.max(auc_like)]
  pv <- knn_prob(knn_train, valid, v, k_best); thr <- best_threshold(pv, valid$high_vol)
  res[[length(res) + 1]] <- cbind(model = sprintf("KNN (k = %d)", k_best), features = set,
                                  metrics(knn_prob(knn_train, test, v, k_best), test$high_vol, thr))
}
res <- rbindlist(res)
print(res, digits = 3)
fwrite(res, file.path(OUT, "01_classification_results.csv"))

# ---- 4. Clustering: market regimes (Lecture 6) ----------------------------------------
# one row per sector per day: average volatility, return, news tone, news volume
reg <- df[, .(vol = mean(gk_vol), ret = mean(ret), tone = mean(sent_mean), neg = mean(neg_share),
              articles = mean(n_articles)), by = .(date, sector)]
X <- scale(reg[, .(log(vol), ret, tone, neg, articles)])
pca <- prcomp(X)
cat("\nPCA: share of variance explained by each component\n"); print(round(summary(pca)$importance[2, ], 3))
km <- kmeans(X, centers = 3, nstart = 25)
reg[, cluster_kmeans := km$cluster]
hc <- hclust(dist(X[sample(nrow(X), min(nrow(X), 3000)), ]), method = "complete")   # dendrogram on a sample
regimes <- reg[, .(days = .N, avg_vol = mean(vol), avg_tone = mean(tone), avg_articles = mean(articles)),
               by = .(sector, cluster_kmeans)][order(sector, avg_vol)]
print(regimes, digits = 4)
fwrite(regimes, file.path(OUT, "02_kmeans_regimes.csv"))
png(file.path(OUT, "03_hierarchical_dendrogram.png"), width = 1000, height = 500)
plot(hc, labels = FALSE, main = "Hierarchical clustering of sector-days (sample of 3,000)", xlab = "", sub = "")
dev.off()
cat("\nSaved results to", OUT, "\n",
    "Compare 'price only' vs 'price + news' for each model: higher sensitivity and lower Brier = news helps.\n")
