#' ---
#' title: "Lane 99: Export Pipeline Outputs"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' EXPORT PATTERN: Bundle Analysis-Ready Tables for Downstream Consumers
#' ============================================================================
#'
#' **Purpose**: Extract analysis-ready tables from the pipeline databases
#' and write them as portable formats (parquet + CSV) for consumption by
#' downstream forecasting repositories (e.g., caseload-forecast-demo).
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/payment.sqlite`
#'   - `./data-private/derived/pipeline/episode.sqlite`
#'   - `./data-private/derived/pipeline/timeseries.sqlite`
#'
#' **Output**:
#'   - `./data-private/derived/export/*.parquet` (primary)
#'   - `./data-private/derived/export/*.csv` (secondary, human-readable)
#'   - `./data-private/derived/export/export_manifest.yml`
#'
#' **Exported tables** (forecasting interface):
#'   - ds_event_count     — Monthly event counts (forecastable series)
#'   - ds_caseload        — Monthly caseload (stock)
#'   - ds_caseload_event  — Reconciliation table (stock + flow)
#'
#' **Additional exports** (full pipeline for exploration):
#'   - ds_payment_month   — Person-month records
#'   - ds_episode         — Episode table
#'   - ds_event           — Person-level events
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/99-export.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 99: Export Pipeline Outputs\n")
cat("Started at:", format(report_render_start_time), "\n")
cat("Working directory:", getwd(), "\n")
cat("============================================================================\n\n")

# ---- load-packages -----------------------------------------------------------
library(magrittr)
library(dplyr)
requireNamespace("DBI")
requireNamespace("RSQLite")
requireNamespace("config")
requireNamespace("arrow")
requireNamespace("readr")

# ---- load-sources ------------------------------------------------------------
base::source("./scripts/common-functions.R")

# ---- declare-globals ---------------------------------------------------------
config     <- config::get()
payment_db     <- config$pipeline$payment_db
episode_db     <- config$pipeline$episode_db
timeseries_db  <- config$pipeline$timeseries_db
export_dir     <- config$pipeline$export_dir

# Ensure export directory exists
if (!dir.exists(export_dir)) dir.create(export_dir, recursive = TRUE)

# Tables to export (db_path, table_name, priority)
export_registry <- tibble::tribble(
  ~db_path,       ~table_name,          ~priority,
  payment_db,     "ds_payment_month",   "exploration",
  episode_db,     "ds_episode",         "exploration",
  episode_db,     "ds_event",           "exploration",
  timeseries_db,  "ds_event_count",     "forecasting",
  timeseries_db,  "ds_caseload",        "forecasting",
  timeseries_db,  "ds_caseload_event",  "forecasting"
)

# ---- declare-functions -------------------------------------------------------

export_table <- function(db_path, table_name, export_dir) {
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  ds <- DBI::dbReadTable(con, table_name)
  DBI::dbDisconnect(con)

  # Write parquet
  parquet_path <- file.path(export_dir, paste0(table_name, ".parquet"))
  arrow::write_parquet(ds, parquet_path)

  # Write CSV
  csv_path <- file.path(export_dir, paste0(table_name, ".csv"))
  readr::write_csv(ds, csv_path)

  list(
    table_name   = table_name,
    n_rows       = nrow(ds),
    n_cols       = ncol(ds),
    parquet_path = parquet_path,
    csv_path     = csv_path
  )
}

# ==============================================================================
# SECTION 1: EXPORT ALL TABLES
# ==============================================================================
# ---- export ------------------------------------------------------------------
cat("📦 SECTION 1: Export tables\n\n")

export_results <- list()
for (i in seq_len(nrow(export_registry))) {
  reg <- export_registry[i, ]
  cat("  Exporting", reg$table_name, "(", reg$priority, ")...")

  result <- export_table(reg$db_path, reg$table_name, export_dir)
  export_results[[i]] <- result

  cat(" ✅", result$n_rows, "rows\n")
}

# ==============================================================================
# SECTION 2: ROUND-TRIP VERIFICATION
# ==============================================================================
# ---- verify ------------------------------------------------------------------
cat("\n🔍 SECTION 2: Round-trip verification\n")

for (result in export_results) {
  # Read back from parquet and verify
  ds_check <- arrow::read_parquet(result$parquet_path)
  msg <- paste("Round-trip failed for", result$table_name)
  stopifnot(msg = nrow(ds_check) == result$n_rows)
  cat("  ✅", result$table_name, ":", result$n_rows, "rows verified\n")
}

# ==============================================================================
# SECTION 3: GENERATE MANIFEST
# ==============================================================================
# ---- manifest ----------------------------------------------------------------
cat("\n📋 SECTION 3: Generate export manifest\n")

# Build manifest content
manifest_lines <- c(
  "# Export Manifest",
  paste0("# Generated: ", Sys.time()),
  paste0("# Pipeline: service-system-sim"),
  "",
  "export_timestamp: ", paste0("  \"", format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), "\""),
  "",
  "tables:"
)

for (result in export_results) {
  manifest_lines <- c(manifest_lines,
    paste0("  - name: \"", result$table_name, "\""),
    paste0("    rows: ", result$n_rows),
    paste0("    cols: ", result$n_cols),
    paste0("    parquet: \"", basename(result$parquet_path), "\""),
    paste0("    csv: \"", basename(result$csv_path), "\"")
  )
}

manifest_path <- file.path(export_dir, "export_manifest.yml")
writeLines(manifest_lines, manifest_path)
cat("✅ Wrote manifest to", manifest_path, "\n")

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 99 complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Export directory:", export_dir, "\n")
cat("Tables exported:", length(export_results), "\n")
cat("Files created:", length(export_results) * 2 + 1, "(parquet + csv + manifest)\n")
cat("============================================================================\n")
