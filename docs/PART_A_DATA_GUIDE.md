# Part A - Data Guide for Parts B and C

**Owner:** Dinithi Samarakoon (Part A: data, features and advanced methods)
**Read this before you start Part B or Part C.** It explains what the shared data is, where it comes from,
and how to use it correctly.

---

## 1. What you need

You only need **one file**: `data/features_daily.csv`. It has one row per **stock** and **trading day**.

| File | What it is | Who uses it |
|---|---|---|
| `data/features_daily.csv` | **The modeling file**: prices, volatility, targets, news and sentiment features, outlier flags | **Parts B and C** |
| `data/final_stocks.csv` | Final stock list with sector and news coverage | Everyone (for the report) |
| `data/news_filtered.csv` | All headlines for the final stocks (raw text) | Part A only |
| `data/yahoo_prices.csv` | Daily prices from Yahoo Finance | Part A only |
| `data/finbert_scores.csv` | FinBERT score for each headline | Part A only |

**Where to get it:** the data files are in the GitHub repository, in `data/`. Run `git pull` on the `main`
branch to get the newest version. Do not edit them in your branch - if you need a new feature, compute it in
your own code or ask Part A to add it.

When Part A uploads a new version, the **existing column names never change**; new columns may be added.
Just `git pull` and re-run your code. See the version log at the end.

---

## 2. Where the data comes from

| Source | Used for | Notes |
|---|---|---|
| **Yahoo Finance** (via `quantmod::getSymbols()`) | Daily open, high, low, close, adjusted close, volume | Chosen over FNSPID prices, which have false jumps (e.g. AAPL -138% on 2020-07-06) and some stocks ending in 2020 |
| **FNSPID** news (Dong et al., 2024) | Headlines per stock per day | 14.7 million records scanned; only the date is available (no time of day) |
| **Loughran-McDonald** dictionary | Course-level sentiment (word counts) | Finance-specific positive / negative word lists |
| **FinBERT** (ProsusAI/finbert) | Advanced sentiment (`fb_*` columns) | Transformer model; run by Part A in Google Colab |

**Stocks:** the 10 S&P 500 Information Technology and 10 Financials stocks with the best news coverage in every year
(selected from 152 stocks by `R/03_select_stocks.R`; see `data/final_stocks.csv`). **Period:** see `data/final_study_period.txt` (2013-2023 unless coverage
forced a later start).

---

## 3. Columns in `features_daily.csv`

| Column | Type | Meaning |
|---|---|---|
| `ticker` | text | Stock symbol |
| `sector` | text | `Information Technology` or `Financials` |
| `date` | date | Trading day *t* |
| `ret` | number | Daily log return on day *t* (from adjusted close). NA on the first day of each stock |
| `gk_vol` | number | **Daily volatility** on day *t* (Garman-Klass estimator from open, high, low, close) |
| `vol_lag5` | number | Average `gk_vol` over the last 5 days (*t-4* ... *t*) |
| `vol_next5` | number | **Target for forecasting (Part B):** average `gk_vol` over the next 5 days (*t+1* ... *t+5*) |
| `high_vol` | 0/1 | **Target for classification (Part C):** 1 if `vol_next5` is in the top 20% of the stock's own 2013-2020 values |
| `sent_mean` | -1 to +1 | Average dictionary tone of the day's headlines ((positive - negative words) / (positive + negative words)); 0 if no news |
| `neg_share` / `pos_share` | 0 to 1 | Share of the day's headlines that are more negative / more positive |
| `n_articles` | count | Number of headlines for the stock that day |
| `n_named` | count | Headlines that actually mention the company name or ticker (the others may be wrongly tagged) |
| `no_news` | 0/1 | 1 if there were no headlines that day |
| `fb_sent_mean` | -1 to +1 | **FinBERT** average tone: P(positive) - P(negative). **0 until FinBERT is added** (check the version log) |
| `fb_neg_share` / `fb_pos_share` | 0 to 1 | Share of headlines FinBERT labels negative / positive |
| `outlier_vol` | 0/1 | Volatility far from the stock's normal level (\|z\| of log volatility > 3) |
| `outlier_news` | 0/1 | Unusually many headlines for that stock (more than 3 SD above its mean) |
| `data_error` | 0/1 | Suspicious price row (\|return\| > 40%, high < low, high = low, or an intraday low/high more than 30% from the open and close, e.g. KKR on the 2015-08-24 flash crash) |
| `price_source` | text | Always `Yahoo` in the current version |

---

## 4. Rules everyone must follow

1. **Time split - never shuffle rows.**

   | Set | Dates | Use |
   |---|---|---|
   | Training | start - 2020-12-31 | Fit models |
   | Validation | 2021-01-01 - 2021-12-31 | Choose settings (k in KNN, tree size, threshold) |
   | Test | 2022-01-01 - 2023-12-31 | Report final results **once** |

2. **No look-ahead.** Features are from day *t* or earlier; targets are from *t+1* onward. Never use
   `vol_next5` or `high_vol` as a predictor. If you build new lags, compute them **by ticker**
   (`by = ticker` in data.table, `group_by(ticker)` in dplyr).
3. **Drop rows with missing values** in the columns you use (the first and last days of each stock have
   NA in `ret`, `vol_lag5` or `vol_next5`). Also drop `data_error == 1` rows.
4. **Run every model twice**: price features only, and price + news features. The difference is the
   value of the news signal (this is the core of all three research questions).
5. **Heavy tails:** returns and volatility are far from normal. For LDA, QDA and KNN, also try
   `log(gk_vol)` and `log(vol_lag5)`, as in the Lecture 5 code. Standardize features for KNN using
   training-set means and SDs only.
6. **Report by sector** (IT vs. Financials) as well as overall - RQ2 needs it.

### Suggested feature sets

| Set | Columns |
|---|---|
| Price only | `vol_lag5`, `gk_vol`, `ret` (or `abs(ret)`), plus a 22-day volatility you compute (see below) |
| + News (dictionary) | price set + `sent_mean`, `neg_share`, `pos_share`, `n_articles`, `no_news` |
| + News (FinBERT) | price set + `fb_sent_mean`, `fb_neg_share`, `fb_pos_share`, `n_articles`, `no_news` |

---

## 5. Starter code (R)

```r
library(data.table)
df <- fread("data/features_daily.csv")
setorder(df, ticker, date)

# monthly volatility for HAR-RV (Part B): average gk_vol over the last 22 days, by stock
df[, vol_lag22 := frollmean(gk_vol, 22), by = ticker]

df <- df[data_error == 0 & !is.na(vol_next5) & !is.na(vol_lag22) & !is.na(ret)]
train <- df[date <= as.IDate("2020-12-31")]
valid <- df[date >= as.IDate("2021-01-01") & date <= as.IDate("2021-12-31")]
test  <- df[date >= as.IDate("2022-01-01")]
```

**Part B - HAR-RV with and without news (linear regression):**

```r
har   <- lm(vol_next5 ~ gk_vol + vol_lag5 + vol_lag22, data = train)
har_x <- lm(vol_next5 ~ gk_vol + vol_lag5 + vol_lag22 + neg_share + n_articles + no_news, data = train)
rmse <- function(m) sqrt(mean((predict(m, test) - test$vol_next5)^2))
c(price_only = rmse(har), with_news = rmse(har_x))
```

**Part C - LDA with and without news (Lecture 5):**

```r
library(MASS)
lda_p <- lda(high_vol ~ log(gk_vol) + log(vol_lag5) + abs(ret), data = train)
lda_n <- lda(high_vol ~ log(gk_vol) + log(vol_lag5) + abs(ret) + neg_share + n_articles + no_news, data = train)
acc <- function(m) mean(predict(m, test)$class == test$high_vol)
c(price_only = acc(lda_p), with_news = acc(lda_n))
```

(`gk_vol` can be 0 on a few days; use `log(pmax(gk_vol, 1e-6))` if you get `-Inf`.)

---

## 6. Known limitations (mention these in your sections)

- **News timing:** FNSPID gives only the date, not the time, so we cannot tell whether a story came before
  or after the market close. Using news from day *t* only for volatility from *t+1* avoids look-ahead.
- **Uneven coverage:** news grows sharply after 2021 (2023 has about 10 times more headlines than 2013),
  and some stocks have years with few headlines. `n_articles` and `no_news` help models handle this.
- **Tagging noise:** some headlines are linked to a stock they are not about; `n_named` counts only the
  ones that mention the company.
- **Dictionary sentiment** finds positive or negative words in only about a quarter of headlines; FinBERT
  scores every headline.
- **Survivorship bias:** the stock list is today's S&P 500, so companies that failed or left the index
  (e.g. banks that failed in 2023) are not included.

---

## 7. Version log

| Version | Date | Stocks | What changed |
|---|---|---|---|
| v1 | 2026-11-10 | 20 (10 IT, 10 Financials), 2013-2023 | First version from the proposal EDA: dictionary sentiment |
| v2 | 2026-11-10 | 20, 2013-2023. **IT:** MU, QCOM, ORCL, TXN, ADBE, ACN, FSLR, MRVL, HPQ, WDC. **Financials:** BX, MS, WFC, V, KKR, USB, ICE, PRU, CME, NDAQ | Final stock list: the 10 stocks per sector with the most headlines in their weakest year (at least 156 headlines in every year); `n_named`; outlier flags |
| v3 | [date] | same as v2 | FinBERT columns (`fb_*`) filled |

Questions about the data: ask Dinithi (Part A) or open a GitHub issue.
