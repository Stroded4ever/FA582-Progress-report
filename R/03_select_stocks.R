# =============================================================================
# 03_select_stocks.R - Part A: choose the final stock list from news coverage
#
#   source("R/03_select_stocks.R")      (run from the project folder in RStudio)
#
# 1. Gets the S&P 500 constituent list with GICS sectors.
# 2. Queries FNSPID news ONCE for every Information Technology and Financials stock
#    (resumable, file by file, like 01_download_data.R).
# 3. Counts headlines per stock per year and picks the best-covered stocks per sector.
# 4. Flags headlines that do not mention the company (wrongly tagged news).
#
# Writes in data/:   final_stocks.csv, final_study_period.txt, news_filtered.csv
# Writes in outputs/tables/: 10_news_coverage_all_stocks.csv, 11_final_stock_list.csv,
#                            12_tagging_check.csv
# After this, run 01_download_data.R for prices (news is already done) and knit the report.
# =============================================================================

if (!exists("PROJECT_ROOT")) PROJECT_ROOT <- if (basename(getwd()) == "R") dirname(getwd()) else getwd()
USE_FINAL_STOCKS  <- FALSE                       # scan the full universe, not a previous list
RUN_FNSPID_PRICES <- FALSE; RUN_YAHOO_PRICES <- FALSE; RUN_FNSPID_NEWS <- FALSE
source(file.path(PROJECT_ROOT, "R", "01_download_data.R"))   # loads config, packages and functions
rm(USE_FINAL_STOCKS, RUN_FNSPID_PRICES, RUN_YAHOO_PRICES, RUN_FNSPID_NEWS)

# ---- Selection settings -------------------------------------------------------
STOCKS_PER_SECTOR   <- 10    # keep up to this many stocks per sector
MIN_STOCKS_SECTOR   <- 5     # need at least this many per sector for a period to be accepted
MIN_HEADLINES_YEAR  <- 50    # a stock qualifies if it has at least this many headlines in EVERY year
CANDIDATE_STARTS    <- c(2013, 2016)   # try the full period first, then a shorter one
SECTORS_USED        <- c("Information Technology", "Financials")

# ---- 1. S&P 500 constituents with sectors --------------------------------------
F_CONST <- file.path(DATA_DIR, "sp500_constituents.csv")
if (!file.exists(F_CONST))
  curl::curl_download("https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv", F_CONST)
const <- fread(F_CONST)
univ  <- const[`GICS Sector` %in% SECTORS_USED, .(ticker = Symbol, company = Security, sector = `GICS Sector`)]
message(sprintf("Universe: %d stocks (%s)", nrow(univ),
                paste(sprintf("%s: %d", names(table(univ$sector)), table(univ$sector)), collapse = ", ")))

# ---- 2. News for the whole universe (one pass, resumable) ------------------------
F_NEWS_ALL <- file.path(DATA_DIR, "news_universe.csv")
news_from_parquet_online(univ$ticker, F_NEWS_ALL, F_NEWS_HEADER,
                         counts_file = file.path(DATA_DIR, "news_universe_scan_counts.csv"),
                         parts_dir   = file.path(DATA_DIR, "news_parts_universe"))
news <- fread(F_NEWS_ALL)
news[, year := as.integer(substr(Date, 1, 4))]

# ---- 3. Coverage per stock and year, and the selection rule ----------------------
yrs <- as.character(year(START_DATE):year(END_DATE))
cov <- dcast(news[, .N, by = .(ticker = Stock_symbol, year)], ticker ~ year, value.var = "N", fill = 0)
for (y in setdiff(yrs, names(cov))) cov[, (y) := 0L]
cov <- merge(univ, cov, by = "ticker", all.x = TRUE)
for (y in yrs) set(cov, which(is.na(cov[[y]])), y, 0L)
cov[, total := rowSums(.SD), .SDcols = yrs]
setorder(cov, sector, -total)
save_cov <- copy(cov); fwrite(save_cov, file.path(TAB_DIR, "10_news_coverage_all_stocks.csv"))

pick <- function(start) {
  ys <- as.character(start:year(END_DATE))
  c2 <- copy(cov)[, min_year := do.call(pmin, .SD), .SDcols = ys][min_year >= MIN_HEADLINES_YEAR]
  setorder(c2, sector, -min_year, -total)
  c2[, head(.SD, STOCKS_PER_SECTOR), by = sector][, .(ticker, company, sector, min_headlines_per_year = min_year,
                                                       headlines_in_period = rowSums(.SD)), .SDcols = ys]
}
chosen <- NULL
for (s in CANDIDATE_STARTS) {
  cand <- pick(s)
  n_sec <- cand[, .N, by = sector]
  message(sprintf("Start %d: %s qualify", s, paste(sprintf("%s %d", n_sec$sector, n_sec$N), collapse = ", ")))
  if (all(SECTORS_USED %in% n_sec$sector) && all(n_sec$N >= MIN_STOCKS_SECTOR)) { chosen <- cand; start_year <- s; break }
}
if (is.null(chosen)) {               # fallback: best available coverage over the last candidate period
  start_year <- tail(CANDIDATE_STARTS, 1)
  ys <- as.character(start_year:year(END_DATE))
  chosen <- copy(cov)[, min_year := do.call(pmin, .SD), .SDcols = ys]
  setorder(chosen, sector, -min_year, -total)
  chosen <- chosen[, head(.SD, MIN_STOCKS_SECTOR), by = sector][, .(ticker, company, sector, min_headlines_per_year = min_year,
            headlines_in_period = rowSums(.SD)), .SDcols = ys]
  message("Not enough stocks meet the rule - using the best-covered stocks instead (see the table).")
}
chosen[, yahoo_symbol := gsub(".", "-", ticker, fixed = TRUE)]
fwrite(chosen, F_FINAL_STOCKS)
writeLines(as.character(start_year), F_FINAL_PERIOD)
fwrite(chosen, file.path(TAB_DIR, "11_final_stock_list.csv"))
message(sprintf("Final list: %d stocks, study period %d-%d", nrow(chosen), start_year, year(END_DATE)))
print(chosen)

# ---- 4. Tagging check: does the headline mention the company? ---------------------
generic <- c("inc", "corp", "corporation", "company", "co", "holdings", "holding", "group", "ltd", "plc", "the",
             "and", "of", "financial", "bank", "bancorp", "technologies", "technology", "systems", "international",
             "american", "capital", "trust", "services", "global", "semiconductor", "software", "devices", "micro",
             "solutions", "networks", "data", "first", "national", "state", "street", "insurance", "partners",
             "class", "a", "b", "inc.", "corp.")
# Extra names for companies whose official name is short, generic or ambiguous.
# Phrases are matched case-insensitively as whole words.
ALIASES <- list(
  HPQ = c("hp", "hewlett"),           USB = c("u.s. bancorp", "us bancorp", "u.s. bank"),
  NDAQ = c("nasdaq inc", "nasdaq, inc", "nasdaq omx", "nasdaq group"),
  MS = c("morgan stanley"),           TXN = c("texas instruments"),
  ICE = c("intercontinental exchange", "nyse"),   V = c("visa"),
  WFC = c("wells fargo"),             PRU = c("prudential"),
  CME = c("cme group", "chicago mercantile"),     BX = c("blackstone"),
  WDC = c("western digital", "sandisk"),          ACN = c("accenture"),
  FSLR = c("first solar"),            MRVL = c("marvell"),     MU = c("micron"))
# For these, the automatic name words are too ambiguous (e.g. "Nasdaq" the index, "Texas" the state)
NO_AUTO <- c("NDAQ", "TXN", "MS", "USB", "HPQ")

name_tokens <- function(company) {
  w <- tolower(unlist(strsplit(gsub("[^A-Za-z ]", " ", company), " +")))
  w[nchar(w) >= 4 & !w %in% generic]
}
short_caps <- function(company) {   # short all-caps names such as HP, CME, KKR, ICE (matched case-sensitively)
  w <- unlist(strsplit(gsub("[^A-Za-z ]", " ", company), " +"))
  w[grepl("^[A-Z]{2,4}$", w)]
}
esc <- function(x) gsub("([.|()^${}+*?\\[\\]\\\\])", "\\\\\\1", x)
mentions <- function(title, ticker, company) {
  hit <- grepl(paste0("(^|[^A-Za-z])", esc(ticker), "([^A-Za-z]|$)"), title)              # ticker, case-sensitive
  caps <- short_caps(company)
  if (length(caps)) hit <- hit | grepl(paste0("(^|[^A-Za-z])(", paste(esc(caps), collapse = "|"), ")([^A-Za-z]|$)"), title)
  al <- ALIASES[[ticker]]
  if (length(al)) hit <- hit | grepl(paste0("(^|[^a-z])(", paste(esc(al), collapse = "|"), ")([^a-z]|$)"), tolower(title))
  if (!ticker %in% NO_AUTO) {
    toks <- name_tokens(company)
    if (length(toks)) hit <- hit | grepl(paste0("\\b(", paste(toks, collapse = "|"), ")"), tolower(title))
  }
  hit
}
news_final <- news[Stock_symbol %in% chosen$ticker & year >= start_year & year <= year(END_DATE)]
news_final <- merge(news_final, chosen[, .(Stock_symbol = ticker, company)], by = "Stock_symbol")
news_final[, mentions_company := mentions(Article_title, Stock_symbol[1], company[1]), by = Stock_symbol]
tag_check <- news_final[, .(headlines = .N, mention_company = sum(mentions_company),
                            share_mentioning = mean(mentions_company)), by = .(ticker = Stock_symbol, company)]
fwrite(tag_check, file.path(TAB_DIR, "12_tagging_check.csv"))
print(tag_check[order(share_mentioning)])
news_final[, `:=`(year = NULL, company = NULL)]
fwrite(news_final, F_NEWS_FILTERED)
message("Saved ", nrow(news_final), " headlines for the final stocks -> ", F_NEWS_FILTERED)
message("Next: run source('R/01_download_data.R') with RUN_FNSPID_NEWS <- FALSE and RUN_FNSPID_PRICES <- FALSE ",
        "to get Yahoo prices for the final list, then knit the report.")
