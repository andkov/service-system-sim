#' ---
#' title: "Lane 4a: Aggregate Events to Monthly Counts"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' DERIVE PATTERN: Events → Event Counts (Monthly Aggregation)
#' ============================================================================
#'
#' **Purpose**: Aggregate person-level events into monthly count time series.
#' These counts are the direct inputs to event-based caseload forecasting
#' models. They transform a person-level event log into a population-level
#' time series.
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/episode.sqlite::ds_event`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/timeseries.sqlite::ds_event_count`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §8):
#'   - event_month      (date)
#'   - event_type       (character) NEW | RETURNED | CLOSED
#'   - client_type      (character) Optional stratification
#'   - household_role   (character) Optional stratification
#'   - n_events         (integer)   Count of events in this cell
#'
#' **Downstream**: This table is the interface between the micro-level
#' administrative record and the macro-level forecast. Its rows are the
#' forecastable series.
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/4a-event-count.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 4a: Aggregate Events to Monthly Counts\n")
cat("Started at:", format(report_render_start_time), "\n")
cat("Working directory:", getwd(), "\n")
cat("============================================================================\n\n")

# ---- load-packages -----------------------------------------------------------
library(magrittr)
library(dplyr)
requireNamespace("DBI")
requireNamespace("RSQLite")
requireNamespace("config")

# ---- load-sources ------------------------------------------------------------
base::source("./scripts/common-functions.R")
base::source("./scripts/operational-functions.R")

# ---- declare-globals ---------------------------------------------------------
config        <- config::get()
episode_db    <- config$pipeline$episode_db
timeseries_db <- config$pipeline$timeseries_db
db_dir        <- config$pipeline$db_dir

if (!dir.exists(db_dir)) dir.create(db_dir, recursive = TRUE)

# ---- declare-functions -------------------------------------------------------
# (none needed)

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data ---------------------------------------------------------------
cat("📂 SECTION 1: Load data\n")

con <- DBI::dbConnect(RSQLite::SQLite(), episode_db)
ds_event <- DBI::dbReadTable(con, "ds_event") %>%
  mutate(event_month = as.Date(event_month))
DBI::dbDisconnect(con)

cat("✅ Loaded ds_event:", nrow(ds_event), "events\n")

# ---- demo-before -------------------------------------------------------------
cat("\n👁️ Demo BEFORE — event counts by type:\n")
ds_event %>%
  count(event_type) %>%
  print()

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — aggregate to monthly counts\n")

ds_event_count <- ds_event %>%
  group_by(event_month, event_type, client_type, household_role) %>%
  summarise(
    n_events = n(),
    .groups = "drop"
  ) %>%
  arrange(event_month, event_type, client_type, household_role)

cat("✅ ds_event_count:", nrow(ds_event_count), "rows\n")
cat("   Event months:", n_distinct(ds_event_count$event_month), "\n")
cat("   Event types:", paste(sort(unique(ds_event_count$event_type)), collapse = ", "), "\n")

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate\n")

# Check: no duplicates in composite key
dup_check <- ds_event_count %>%
  group_by(event_month, event_type, client_type, household_role) %>%
  filter(n() > 1)
stopifnot("Duplicate cells in event_count" = nrow(dup_check) == 0)
cat("✅ Unique composite key (month × type × client × role) — PASSED\n")

# Check: total events preserved
stopifnot("Total event count mismatch" =
  sum(ds_event_count$n_events) == nrow(ds_event))
cat("✅ Total events preserved:", sum(ds_event_count$n_events), "— PASSED\n")

# Check: all n_events > 0
stopifnot("Zero-count cells should not exist" = all(ds_event_count$n_events > 0))
cat("✅ All cells have n_events > 0 — PASSED\n")

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER — first and last months:\n")

months_sorted <- sort(unique(ds_event_count$event_month))
cat("First 2 months:\n")
ds_event_count %>%
  filter(event_month %in% months_sorted[1:min(2, length(months_sorted))]) %>%
  tibble::as_tibble() %>%
  print(n = 20)

cat("\nLast 2 months:\n")
ds_event_count %>%
  filter(event_month %in% tail(months_sorted, 2)) %>%
  tibble::as_tibble() %>%
  print(n = 20)

# Summary by event_type across all months
cat("\nTotal events by type:\n")
ds_event_count %>%
  group_by(event_type) %>%
  summarise(total = sum(n_events), .groups = "drop") %>%
  print()

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), timeseries_db)

if (DBI::dbExistsTable(con, "ds_event_count")) {
  DBI::dbRemoveTable(con, "ds_event_count")
}

ds_event_count_write <- ds_event_count %>%
  mutate(event_month = as.character(event_month))

DBI::dbWriteTable(con, "ds_event_count", ds_event_count_write)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_event_count")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_event_count))
cat("✅ Wrote", n_written, "rows to", timeseries_db, "::ds_event_count\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 4a complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", timeseries_db, "::ds_event_count\n")
cat("Rows:", nrow(ds_event_count), " | Cols:", ncol(ds_event_count), "\n")
cat("============================================================================\n")
