# Sentiment-Enhanced Volatility Forecasting (FA 582, Fall 2026)

Group project for **FA 582 - Foundations of Financial Data Science**, Stevens Institute of Technology.

**Question:** Does financial news sentiment improve short-term volatility forecasts for S&P 500 stocks,
does the effect differ between Information Technology and Financials, and can it help flag
high-volatility weeks?

| | |
|---|---|
| Data | FNSPID news and prices (Dong et al., 2024), Yahoo Finance via `quantmod` |
| Period | 2013-2023 |
| Course methods | Linear regression (HAR-RV), Logistic Regression, LDA, QDA, KNN, trees, Random Forest, boosting, PCA, k-means, hierarchical clustering |
| Advanced comparison | FinBERT sentiment, LSTM |

## Project structure

```
fa582-sentiment-volatility/
├── R/
│   ├── config.R               # shared settings: tickers, dates, file paths (edit here only)
│   ├── 01_download_data.R     # downloads Yahoo prices (+ FNSPID prices/news for the first 20-stock EDA)
│   └── 03_select_stocks.R     # Part A: news coverage scan for all IT + Financials stocks -> final stock list
├── python/
│   └── finbert_scores.ipynb   # Part A (advanced): FinBERT headline sentiment, run in Google Colab
├── reports/
│   └── 02_eda_feasibility.Rmd # data header, feasibility check, EDA (knit to HTML / Word)
├── docs/
│   ├── PART_A_DATA_GUIDE.md   # what the shared data is (all columns, rules, limitations)
│   ├── PART_B_GUIDE.md        # Part B: forecasting - what to use, tasks, how to start
│   └── PART_C_GUIDE.md        # Part C: classification + clustering - what to use, tasks, how to start
├── partB/partB_starter.R      # working first version of Part B
├── partC/partC_starter.R      # working first version of Part C
├── outputs/
│   ├── tables/                # CSV tables written by the report (committed to GitHub)
│   └── figures/               # PNG figures written by the report (committed to GitHub)
├── data/                      # small data files are on GitHub; large raw downloads stay local
├── CONTRIBUTIONS.md           # who did what, at every phase (required by the course)
└── fa582-sentiment-volatility.Rproj
```

## How to run

1. Open `fa582-sentiment-volatility.Rproj` in RStudio.
2. **Download the data (one person, once):** open `R/01_download_data.R` and click **Source**.
   - Prices: the FNSPID price zip and Yahoo Finance take a few minutes.
   - News: the original FNSPID news CSV is 21.6 GB, so by default the script does **not** download it.
     DuckDB queries a Parquet copy of the same table on Hugging Face online and keeps only our
     tickers, years and columns in `data/news_filtered.csv` (a small file).
   - The small files that the project needs (`features_daily.csv`, `news_filtered.csv`, `yahoo_prices.csv`,
     the stock list) are pushed to GitHub, so the others get them with `git pull`. Large downloads stay local.
   - **Hugging Face token (recommended, free):** without one, Hugging Face may rate-limit you (HTTP 429).
     Create an account at huggingface.co → Settings → Access Tokens → **Create new token** (type *Read*).
     In RStudio run `file.edit(".Renviron")`, add the line `HF_TOKEN=hf_your_token_here`, save, and restart R
     (Session → Restart R). `.Renviron` is in `.gitignore`, so your token is never pushed to GitHub.
   - The news step processes 44 files one by one and saves each in `data/news_parts/`. If it stops
     (rate limit, Wi-Fi), just run it again: finished files are skipped.
3. **Everyone else:** just clone or pull the repository - the data files come with it.
4. Open `reports/02_eda_feasibility.Rmd` and click **Knit**. The tables and figures are saved in
   `outputs/` and can go straight into the proposal and the progress report.

Packages used: `data.table`, `ggplot2`, `knitr`, `rmarkdown`, `quantmod`, `readr`, `curl`,
`SentimentAnalysis` (for the Loughran-McDonald dictionary), `DBI` and `duckdb` (online news query). The scripts install any that are missing.

To change the stocks or the study period, edit `R/config.R` only.

## Part A pipeline (final stock list and shared data file)

Run these once, in this order (one person; then push to GitHub):

1. `source("R/03_select_stocks.R")` - scans FNSPID news for every S&P 500 IT and Financials stock,
   picks the best-covered stocks per sector, flags headlines that do not mention the company, and writes
   `data/final_stocks.csv` and `data/news_filtered.csv`. From now on every script uses the final list.
2. In the Console: `RUN_FNSPID_PRICES <- FALSE; RUN_FNSPID_NEWS <- FALSE; RUN_YAHOO_PRICES <- TRUE`,
   then `source("R/01_download_data.R")` - Yahoo prices for the final list.
3. Knit `reports/02_eda_feasibility.Rmd` - writes the shared modeling file **`data/features_daily.csv`**.
4. (Advanced) Open `python/finbert_scores.ipynb` in Google Colab with a GPU, upload `data/news_filtered.csv`,
   download `finbert_scores.csv` and `finbert_accuracy.csv` into `data/`, and knit again. The FinBERT columns
   (`fb_sent_mean`, `fb_neg_share`, `fb_pos_share`) are then filled in `features_daily.csv`.

**Parts B and C only need `data/features_daily.csv`** - read `docs/PART_A_DATA_GUIDE.md` first. Its columns never change; when Part A uploads a new
version, just re-run your code.

## Working together on GitHub

- Pull before you start: `git pull`
- Work on your own branch: `git checkout -b <your-name>/<task>` (for example `dinithi/eda`)
- Commit small, clear changes, push, and open a Pull Request. Another member reviews it before merging.
- Only the data files listed in `.gitignore` are pushed; don't force-add large files (GitHub rejects files over 100 MB).
- Add a line to `CONTRIBUTIONS.md` for what you did in each phase.

## Data sources

- Dong, Z., Fan, X. and Peng, Z. (2024). *FNSPID: A Comprehensive Financial News Dataset in Time Series.* KDD 2024. https://huggingface.co/datasets/Zihan1004/FNSPID
- Yahoo Finance, via the `quantmod` R package.
- Loughran, T. and McDonald, B. (2011). *When Is a Liability Not a Liability?* Journal of Finance 66(1). Dictionary via the `SentimentAnalysis` R package.
