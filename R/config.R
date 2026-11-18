# =============================================================================
# config.R - shared settings for the whole project
# Every script and the EDA report source this file, so change things here only.
# =============================================================================

# ---- Study period ------------------------------------------------------------
START_DATE <- as.Date("2013-01-01")
END_DATE   <- as.Date("2023-12-31")   # FNSPID ends in 2023
TRAIN_END  <- as.Date("2020-12-31")   # train 2013-2020 | validate 2021 | test 2022-2023
VALID_END  <- as.Date("2021-12-31")

# ---- Stocks (subset for the proposal EDA; finalize after the feasibility check)
SECTORS <- list(
  "Information Technology" = c("AAPL", "MSFT", "NVDA", "ORCL", "CSCO",
                               "ADBE", "CRM", "INTC", "AMD", "QCOM"),
  "Financials"             = c("JPM", "BAC", "WFC", "C", "GS",
                               "MS", "AXP", "BLK", "SCHW", "USB")
)
TICKERS <- unlist(SECTORS, use.names = FALSE)
TICKER_SECTOR <- setNames(rep(names(SECTORS), lengths(SECTORS)), TICKERS)

# ---- FNSPID on Hugging Face (check the "Files" tab if a path ever changes) ------
HF_BASE          <- "https://huggingface.co/datasets/Zihan1004/FNSPID/resolve/main"
FNSPID_PRICE_ZIP <- "Stock_price/full_history.zip"
FNSPID_NEWS_CSV  <- "Stock_news/nasdaq_exteral_data.csv"   # (sic) spelling used by FNSPID; 21.6 GB
# Parquet copy of the same FNSPID news table (same 12 columns, 14.7M rows), queried online
NEWS_PARQUET_DIR     <- "hf://datasets/sabareesh88/FNSPID_nasdaq_sorted/data/"
NEWS_PARQUET_N_FILES <- 44   # files are named train-00000-of-00044.parquet ... train-00043-of-00044.parquet

# ---- Folders -----------------------------------------------------------------
# PROJECT_ROOT is set by whoever sources this file; default = current directory
if (!exists("PROJECT_ROOT")) PROJECT_ROOT <- getwd()
DATA_DIR <- file.path(PROJECT_ROOT, "data")
RAW_DIR  <- file.path(DATA_DIR, "raw")
TAB_DIR  <- file.path(PROJECT_ROOT, "outputs", "tables")
FIG_DIR  <- file.path(PROJECT_ROOT, "outputs", "figures")
for (d in c(DATA_DIR, RAW_DIR, TAB_DIR, FIG_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# Processed files written by 01_download_data.R and read by the EDA report
F_FNSPID_PRICES <- file.path(DATA_DIR, "fnspid_prices.csv")
F_YAHOO_PRICES  <- file.path(DATA_DIR, "yahoo_prices.csv")
F_NEWS_HEADER   <- file.path(DATA_DIR, "fnspid_news_header.csv")
F_NEWS_FILTERED <- file.path(DATA_DIR, "news_filtered.csv")
F_NEWS_COUNTS   <- file.path(DATA_DIR, "news_scan_counts.csv")

# ---- Final stock list (written by R/03_select_stocks.R) -----------------------
# Once data/final_stocks.csv exists, every script and the report use it automatically.
F_FINAL_STOCKS <- file.path(DATA_DIR, "final_stocks.csv")
F_FINAL_PERIOD <- file.path(DATA_DIR, "final_study_period.txt")
if (!exists("USE_FINAL_STOCKS")) USE_FINAL_STOCKS <- TRUE
if (USE_FINAL_STOCKS && file.exists(F_FINAL_STOCKS)) {
  fs_ <- utils::read.csv(F_FINAL_STOCKS, stringsAsFactors = FALSE)
  SECTORS <- split(fs_$ticker, fs_$sector)
  TICKERS <- unlist(SECTORS, use.names = FALSE)
  TICKER_SECTOR <- setNames(rep(names(SECTORS), lengths(SECTORS)), TICKERS)
  YAHOO_SYMBOL  <- setNames(fs_$yahoo_symbol, fs_$ticker)
  if (file.exists(F_FINAL_PERIOD)) START_DATE <- as.Date(sprintf("%s-01-01", readLines(F_FINAL_PERIOD, 1)))
  rm(fs_)
} else {
  YAHOO_SYMBOL <- setNames(gsub(".", "-", TICKERS, fixed = TRUE), TICKERS)   # e.g. BRK.B -> BRK-B
}

# ---- Other settings ----------------------------------------------------------
NEWS_CHUNK_ROWS   <- 500000   # rows read per chunk when scanning the large news file
HIGH_VOL_QUANTILE <- 0.80     # "high-volatility week" = top 20% of a stock's training history
MIN_ARTICLES_YEAR <- 500      # coverage target per stock per year (He and Li, 2026)
