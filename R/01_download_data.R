# =============================================================================
# 01_download_data.R - download and prepare the raw data (run ONCE)
#
#   Rscript R/01_download_data.R          (or open in RStudio and click "Source")
#
# Creates in data/:
#   fnspid_prices.csv      FNSPID daily prices for our tickers
#   yahoo_prices.csv       Yahoo Finance daily prices (validation / backup source)
#   fnspid_news_header.csv first rows of the raw FNSPID news file (all columns)
#   news_filtered.csv      FNSPID headlines for our tickers, 2013-2023
#   news_scan_counts.csv   rows scanned and kept per chunk (feasibility record)
#
# NEWS: the original FNSPID news CSV is 21.6 GB. By default (NEWS_METHOD = "online")
# we do NOT download it: DuckDB queries a Parquet copy of the same data on Hugging
# Face and pulls only our tickers, years and 5 columns, so almost nothing is stored.
# NEWS_METHOD = "download_csv" downloads the full CSV instead (needs ~25 GB free).
# Only ONE group member needs to run the news step; share data/news_filtered.csv
# with the others (e.g. Google Drive) - data files are not pushed to GitHub.
# =============================================================================

if (!exists("PROJECT_ROOT")) PROJECT_ROOT <- if (basename(getwd()) == "R") dirname(getwd()) else getwd()
source(file.path(PROJECT_ROOT, "R", "config.R"))

options(repos = c(CRAN = "https://cloud.r-project.org"))
pkgs <- c("data.table", "quantmod", "readr", "curl")
new  <- pkgs[!pkgs %in% rownames(installed.packages())]
if (length(new)) install.packages(new)
suppressPackageStartupMessages({
  library(data.table); library(quantmod); library(readr); library(curl)
})
options(timeout = 60 * 60 * 6)

if (!exists("RUN_FNSPID_PRICES")) RUN_FNSPID_PRICES <- TRUE
if (!exists("RUN_YAHOO_PRICES")) RUN_YAHOO_PRICES <- TRUE
if (!exists("RUN_FNSPID_NEWS")) RUN_FNSPID_NEWS <- TRUE
if (!exists("NEWS_METHOD")) NEWS_METHOD <- "online"     # "online" (recommended) or "download_csv"
# If you already downloaded the news CSV somewhere else, put its path here:
if (!exists("NEWS_LOCAL_FILE")) NEWS_LOCAL_FILE <- file.path(RAW_DIR, "nasdaq_exteral_data.csv")

download_once <- function(url, dest) {
  if (file.exists(dest) && file.size(dest) > 0) {
    message("Already downloaded: ", dest); return(invisible(dest))
  }
  message("Downloading ", url, "\n  -> ", dest, " (this can take a while)")
  tmp <- paste0(dest, ".part")
  curl::curl_download(url, tmp, quiet = FALSE)
  file.rename(tmp, dest)
  invisible(dest)
}

# -----------------------------------------------------------------------------
# 1. FNSPID price files
# -----------------------------------------------------------------------------
read_fnspid_price_zip <- function(zip_path, tickers) {
  listing <- unzip(zip_path, list = TRUE)$Name
  csvs    <- listing[grepl("\\.csv$", listing, ignore.case = TRUE)]
  sym     <- toupper(tools::file_path_sans_ext(basename(csvs)))
  wanted  <- csvs[sym %in% tickers]
  missing <- setdiff(tickers, sym)
  if (length(missing)) message("Tickers not found in FNSPID price files: ", paste(missing, collapse = ", "))
  exdir <- file.path(RAW_DIR, "fnspid_prices")
  unzip(zip_path, files = wanted, exdir = exdir, junkpaths = TRUE)
  out <- rbindlist(lapply(wanted, function(f) {
    d <- fread(file.path(exdir, basename(f)))
    setnames(d, gsub("[^a-z]+", "_", tolower(trimws(names(d)))))   # "Adj Close" -> adj_close
    d[, ticker := toupper(tools::file_path_sans_ext(basename(f)))]
    d
  }), fill = TRUE)
  out[, date := as.Date(substr(as.character(date), 1, 10))]
  out[date >= START_DATE & date <= END_DATE][order(ticker, date)]
}

if (RUN_FNSPID_PRICES) {
  zip_path <- file.path(RAW_DIR, "full_history.zip")
  download_once(paste(HF_BASE, FNSPID_PRICE_ZIP, sep = "/"), zip_path)
  fn <- read_fnspid_price_zip(zip_path, TICKERS)
  fwrite(fn, F_FNSPID_PRICES)
  message("Saved ", nrow(fn), " FNSPID price rows -> ", F_FNSPID_PRICES)
}

# -----------------------------------------------------------------------------
# 2. Yahoo Finance prices (quantmod, as in Lectures 2, 4 and 5)
# -----------------------------------------------------------------------------
if (RUN_YAHOO_PRICES) {
  yh <- rbindlist(lapply(TICKERS, function(t) {
    x <- tryCatch(getSymbols(YAHOO_SYMBOL[[t]], src = "yahoo", from = START_DATE, to = END_DATE + 1,
                             auto.assign = FALSE),
                  error = function(e) { message("Yahoo failed for ", t, ": ", conditionMessage(e)); NULL })
    if (is.null(x)) return(NULL)
    d <- data.table(date = index(x), coredata(x))
    setnames(d, c("date", "open", "high", "low", "close", "volume", "adj_close"))
    d[, ticker := t]
  }))
  fwrite(yh, F_YAHOO_PRICES)
  message("Saved ", nrow(yh), " Yahoo price rows -> ", F_YAHOO_PRICES)
}

# -----------------------------------------------------------------------------
# 3. FNSPID news: header sample + chunked filter to our tickers and years
# -----------------------------------------------------------------------------
filter_news_file <- function(path, tickers, out_file, counts_file) {
  # header sample with ALL columns (long text shortened so the table is readable)
  hdr <- readr::read_csv(path, n_max = 5, show_col_types = FALSE)
  hdr <- as.data.table(hdr)
  for (col in names(hdr)) if (is.character(hdr[[col]])) set(hdr, j = col, value = substr(hdr[[col]], 1, 120))
  fwrite(hdr, F_NEWS_HEADER)
  message("News columns: ", paste(names(hdr), collapse = ", "))

  if (file.exists(out_file)) file.remove(out_file)
  counts <- list()
  keep_cols <- readr::cols_only(Date = "c", Article_title = "c", Stock_symbol = "c",
                                Publisher = "c", Url = "c")
  cb <- function(x, pos) {
    x <- as.data.table(x)
    k <- x[Stock_symbol %in% tickers & !is.na(Article_title) & nzchar(Article_title)]
    k[, year := as.integer(substr(Date, 1, 4))]
    k <- k[year >= year(START_DATE) & year <= year(END_DATE)]
    k[, year := NULL]
    if (nrow(k)) fwrite(k, out_file, append = file.exists(out_file))
    counts[[length(counts) + 1]] <<- data.table(chunk_start_row = pos, rows_scanned = nrow(x), rows_kept = nrow(k))
    message(sprintf("  rows %s+ : kept %d", format(pos, big.mark = ","), nrow(k)))
  }
  readr::read_csv_chunked(path, callback = readr::SideEffectChunkCallback$new(cb),
                          chunk_size = NEWS_CHUNK_ROWS, col_types = keep_cols, progress = FALSE)
  fwrite(rbindlist(counts), counts_file)
  # de-duplicate after the scan (same headline linked to the same stock twice)
  news <- fread(out_file)
  before <- nrow(news)
  news <- unique(news, by = c("Stock_symbol", "Article_title", "Date"))
  fwrite(news, out_file)
  message("Kept ", nrow(news), " headlines (", before - nrow(news), " duplicates removed) -> ", out_file)
}

# Online method: DuckDB reads the Parquet files straight from Hugging Face. Parquet
# stores each column separately, so only the requested columns are transferred.
# The dataset is split into NEWS_PARQUET_N_FILES files; we query them ONE AT A TIME,
# save each result in data/news_parts/, and skip finished files if the script is
# re-run - so a rate limit (HTTP 429) or lost connection never loses progress.
# A free Hugging Face token (HF_TOKEN in .Renviron) gives a much higher rate limit.
news_from_parquet_online <- function(tickers, out_file, header_file, counts_file,
                                     parts_dir = file.path(DATA_DIR, "news_parts")) {
  for (p in c("DBI", "duckdb")) if (!requireNamespace(p, quietly = TRUE)) install.packages(p)
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
  token <- Sys.getenv("HF_TOKEN")
  if (nzchar(token)) {
    DBI::dbExecute(con, sprintf("CREATE OR REPLACE SECRET hf_token (TYPE huggingface, TOKEN '%s')", token))
    message("Using your Hugging Face token (higher rate limit).")
  } else {
    message("No HF_TOKEN found - running without a token. If you get rate-limited, add a token (see README).")
  }

  files <- sprintf("%strain-%05d-of-%05d.parquet", NEWS_PARQUET_DIR, 0:(NEWS_PARQUET_N_FILES - 1), NEWS_PARQUET_N_FILES)
  dir.create(parts_dir, showWarnings = FALSE)

  run_query <- function(sql, what) {
    for (attempt in 1:8) {
      res <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) e)
      if (!inherits(res, "error")) return(res)
      msg <- conditionMessage(res)
      wait <- if (grepl("429|Too Many Requests|rate limit", msg, ignore.case = TRUE)) 180 else 30
      message(sprintf("  %s failed (attempt %d): %s", what,  attempt, substr(gsub("\\s+", " ", msg), 1, 140)))
      message(sprintf("  waiting %d seconds, then retrying ...", wait))
      Sys.sleep(wait)
    }
    stop("Giving up on ", what, " after 8 attempts. Run the script again later - finished files are kept.")
  }

  if (!file.exists(header_file)) {
    message("Reading the news header (first 5 rows, all columns) ...")
    hdr <- as.data.table(run_query(sprintf("SELECT * FROM read_parquet('%s') LIMIT 5", files[1]), "header"))
    for (col in names(hdr)) if (is.character(hdr[[col]])) set(hdr, j = col, value = substr(hdr[[col]], 1, 120))
    fwrite(hdr, header_file)
    message("News columns: ", paste(names(hdr), collapse = ", "))
  }

  tick_sql <- paste0("'", tickers, "'", collapse = ", ")
  for (i in seq_along(files)) {
    part <- file.path(parts_dir, sprintf("part_%02d.csv", i - 1))
    if (file.exists(part)) { message(sprintf("File %d/%d already done - skipping", i, length(files))); next }
    message(sprintf("File %d/%d: querying ...", i, length(files)))
    n_total <- run_query(sprintf("SELECT count(*) AS n FROM read_parquet('%s')", files[i]), sprintf("file %d count", i))$n
    d <- as.data.table(run_query(sprintf(
      "SELECT Date, Article_title, Stock_symbol, Publisher, Url FROM read_parquet('%s')
        WHERE Stock_symbol IN (%s)
          AND Article_title IS NOT NULL AND length(Article_title) > 0
          AND substr(Date, 1, 4) BETWEEN '%d' AND '%d'",
      files[i], tick_sql, year(START_DATE), year(END_DATE)), sprintf("file %d", i)))
    fwrite(d, part)
    writeLines(as.character(n_total), sub("\\.csv$", ".count", part))   # rows scanned (kept even if 0 match)
    message(sprintf("  rows in file: %s | kept for our tickers: %s", format(n_total, big.mark = ","), format(nrow(d), big.mark = ",")))
    if (!nzchar(token)) Sys.sleep(10)   # be gentle without a token
  }

  part_files <- list.files(parts_dir, "^part_\\d+\\.csv$", full.names = TRUE)
  parts  <- lapply(part_files, fread, colClasses = "character")
  counts <- data.table(source_file = basename(files[seq_along(part_files)]),
                       rows_in_file = vapply(sub("\\.csv$", ".count", part_files),
                                             function(f) if (file.exists(f)) as.numeric(readLines(f, 1)) else NA_real_, 0),
                       rows_kept = vapply(parts, nrow, 0L))
  fwrite(counts, counts_file)
  news <- rbindlist(parts, fill = TRUE)[, .(Date, Article_title, Stock_symbol, Publisher, Url)]
  before <- nrow(news)
  news <- unique(news, by = c("Stock_symbol", "Article_title", "Date"))
  fwrite(news, out_file)
  message(sprintf("Total news rows scanned: %s", format(sum(counts$rows_in_file, na.rm = TRUE), big.mark = ",")))
  message("Kept ", nrow(news), " headlines (", before - nrow(news), " duplicates removed) -> ", out_file)
}

if (RUN_FNSPID_NEWS) {
  if (NEWS_METHOD == "online") {
    news_from_parquet_online(TICKERS, F_NEWS_FILTERED, F_NEWS_HEADER, F_NEWS_COUNTS)
  } else {
    if (!file.exists(NEWS_LOCAL_FILE))
      download_once(paste(HF_BASE, FNSPID_NEWS_CSV, sep = "/"), NEWS_LOCAL_FILE)
    filter_news_file(NEWS_LOCAL_FILE, TICKERS, F_NEWS_FILTERED, F_NEWS_COUNTS)
  }
}

message("Done. Next: open reports/02_eda_feasibility.Rmd in RStudio and click Knit.")
