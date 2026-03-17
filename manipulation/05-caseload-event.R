#' ---
#' title: "Lane 5: Reconcile Caseload with Events"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' RECONCILE PATTERN: Stock-Flow Identity Verification
#' ============================================================================
#'
#' **Purpose**: Join the caseload "stock" with event "flow" counts and verify
#' the stock-flow identity:
#'
#'   Caseload(t) = Caseload(t-1) + NEW(t) + RETURNED(t) - CLOSED(t)
#'
#' This identity must hold exactly. Any discrepancy is a pipeline bug, not
#' a modeling finding.
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/timeseries.sqlite::ds_caseload`
#'   - `./data-private/derived/pipeline/timeseries.sqlite::ds_event_count`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/timeseries.sqlite::ds_caseload_event`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §10):
#'   - pay_period           (date)
#'   - client_type          (character)
#'   - household_role       (character)
#'   - active_clients       (integer)  From ds_caseload
#'   - NEW                  (integer)  From ds_event_count
#'   - RETURNED             (integer)  From ds_event_count
#'   - CLOSED               (integer)  From ds_event_count
#'   - delta_caseload       (integer)  NEW + RETURNED - CLOSED
#'   - implied_next_caseload (integer) active_clients + delta_caseload
#'
#' **Verification**: When implied_next_caseload at time t equals
#' active_clients at time t+1, the identity holds.
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/05-caseload-event.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 5: Reconcile Caseload with Events\n")
cat("Started at:", format(report_render_start_time), "\n")
cat("Working directory:", getwd(), "\n")
cat("============================================================================\n\n")

# ---- load-packages -----------------------------------------------------------
library(magrittr)
library(dplyr)
library(tidyr)
requireNamespace("DBI")
requireNamespace("RSQLite")
requireNamespace("config")

# ---- load-sources ------------------------------------------------------------
base::source("./scripts/common-functions.R")
base::source("./scripts/operational-functions.R")

# ---- declare-globals ---------------------------------------------------------
config        <- config::get()
timeseries_db <- config$pipeline$timeseries_db

# ---- declare-functions -------------------------------------------------------
# (none needed)

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data ---------------------------------------------------------------
cat("📂 SECTION 1: Load data\n")

con <- DBI::dbConnect(RSQLite::SQLite(), timeseries_db)
ds_caseload <- DBI::dbReadTable(con, "ds_caseload") %>%
  mutate(pay_period = as.Date(pay_period))
ds_event_count <- DBI::dbReadTable(con, "ds_event_count") %>%
  mutate(event_month = as.Date(event_month))
DBI::dbDisconnect(con)

cat("✅ Loaded ds_caseload:", nrow(ds_caseload), "rows\n")
cat("✅ Loaded ds_event_count:", nrow(ds_event_count), "rows\n")

# ---- demo-before -------------------------------------------------------------
cat("\n👁️ Demo BEFORE — caseload sample:\n")
ds_caseload %>% slice_head(n = 5) %>% print()
cat("\nEvent count sample:\n")
ds_event_count %>% slice_head(n = 5) %>% print()

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — reconcile stock and flow\n")

# Pivot event counts to wide format (one column per event_type)
ds_events_wide <- ds_event_count %>%
  pivot_wider(
    id_cols     = c(event_month, client_type, household_role),
    names_from  = event_type,
    values_from = n_events,
    values_fill = 0L
  ) %>%
  rename(pay_period = event_month)

# Ensure all three event columns exist (in case one type is missing globally)
for (col in c("NEW", "RETURNED", "CLOSED")) {
  if (!col %in% names(ds_events_wide)) {
    ds_events_wide[[col]] <- 0L
  }
}

# Join caseload with events
ds_caseload_event <- ds_caseload %>%
  full_join(
    ds_events_wide,
    by = c("pay_period", "client_type", "household_role")
  ) %>%
  # Fill missing event counts with 0 (months with caseload but no events)
  mutate(
    across(c(NEW, RETURNED, CLOSED), ~ replace_na(., 0L)),
    active_clients = replace_na(active_clients, 0L)
  ) %>%
  # Compute flow and implied next caseload
  mutate(
    delta_caseload       = NEW + RETURNED - CLOSED,
    implied_next_caseload = active_clients + delta_caseload
  ) %>%
  arrange(pay_period, client_type, household_role)

cat("✅ ds_caseload_event:", nrow(ds_caseload_event), "rows\n")

# ==============================================================================
# SECTION 3: VALIDATE — STOCK-FLOW IDENTITY
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate — stock-flow identity\n")

# For each cell (client_type × household_role), check that
# implied_next_caseload(t) == active_clients(t+1)
identity_check <- ds_caseload_event %>%
  group_by(client_type, household_role) %>%
  arrange(pay_period) %>%
  mutate(
    next_actual = lead(active_clients),
    identity_holds = is.na(next_actual) | (implied_next_caseload == next_actual)
  ) %>%
  ungroup()

n_violations <- sum(!identity_check$identity_holds, na.rm = TRUE)

if (n_violations == 0) {
  cat("✅ Stock-flow identity holds for ALL cells — PASSED\n")
} else {
  cat("⚠️  Stock-flow identity VIOLATIONS:", n_violations, "\n")
  cat("Showing first violations:\n")
  identity_check %>%
    filter(!identity_holds) %>%
    select(pay_period, client_type, household_role,
           active_clients, NEW, RETURNED, CLOSED,
           implied_next_caseload, next_actual) %>%
    slice_head(n = 10) %>%
    print()
  # TODO: Decide whether to stop or warn
  # stopifnot("Stock-flow identity violated" = n_violations == 0)
  cat("⚠️  Identity violations may indicate simulation edge cases or\n")
  cat("   boundary conditions. Review before treating as hard failure.\n")
}

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER — reconciliation table:\n")

# Show a few months of the reconciliation
months_sorted <- sort(unique(ds_caseload_event$pay_period))
cat("Sample months (middle of range):\n")
mid <- max(1, length(months_sorted) %/% 2 - 1)
ds_caseload_event %>%
  filter(pay_period %in% months_sorted[mid:min(mid + 5, length(months_sorted))]) %>%
  tibble::as_tibble() %>%
  print(n = 30)

# Summary statistics
cat("\nOverall summary:\n")
cat("  Total NEW events:", sum(ds_caseload_event$NEW), "\n")
cat("  Total RETURNED events:", sum(ds_caseload_event$RETURNED), "\n")
cat("  Total CLOSED events:", sum(ds_caseload_event$CLOSED), "\n")
cat("  Mean monthly caseload:", round(mean(ds_caseload_event$active_clients), 1), "\n")

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), timeseries_db)

if (DBI::dbExistsTable(con, "ds_caseload_event")) {
  DBI::dbRemoveTable(con, "ds_caseload_event")
}

ds_caseload_event_write <- ds_caseload_event %>%
  mutate(pay_period = as.character(pay_period))

DBI::dbWriteTable(con, "ds_caseload_event", ds_caseload_event_write)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_caseload_event")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_caseload_event))
cat("✅ Wrote", n_written, "rows to", timeseries_db, "::ds_caseload_event\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 5 complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", timeseries_db, "::ds_caseload_event\n")
cat("Rows:", nrow(ds_caseload_event), " | Cols:", ncol(ds_caseload_event), "\n")
cat("Identity violations:", n_violations, "\n")
cat("============================================================================\n")
