#' ---
#' title: "Lane 2b: Count Active Caseload"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' DERIVE PATTERN: Payment-Month → Caseload (Monthly Client Counts)
#' ============================================================================
#'
#' **Purpose**: Count the number of active clients per month, optionally
#' stratified by client_type and household_role. This produces the "stock"
#' side of the stock-flow identity.
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment_month`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/timeseries.sqlite::ds_caseload`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §9):
#'   - pay_period       (date)
#'   - client_type      (character)
#'   - household_role   (character)
#'   - active_clients   (integer)  Count of persons with payment in this cell
#'
#' **Note**: Caseload is derived, not simulated. It is the integral of the
#' flow (events). See `05-caseload-event.R` for reconciliation.
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/2b-caseload.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 2b: Count Active Caseload\n")
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
config         <- config::get()
payment_db     <- config$pipeline$payment_db
timeseries_db  <- config$pipeline$timeseries_db
db_dir         <- config$pipeline$db_dir

# Ensure output directory exists
if (!dir.exists(db_dir)) dir.create(db_dir, recursive = TRUE)

# ---- declare-functions -------------------------------------------------------
# (none needed for this aggregation)

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data ---------------------------------------------------------------
cat("📂 SECTION 1: Load data\n")

con <- DBI::dbConnect(RSQLite::SQLite(), payment_db)
ds_payment_month <- DBI::dbReadTable(con, "ds_payment_month") %>%
  mutate(pay_period = as.Date(pay_period))
DBI::dbDisconnect(con)

cat("✅ Loaded ds_payment_month:", nrow(ds_payment_month), "rows\n")

# ---- demo-before -------------------------------------------------------------
cat("\n👁️ Demo BEFORE — sample of person-month records:\n")
ds_payment_month %>%
  slice_sample(n = 10) %>%
  arrange(pay_period) %>%
  print()

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — count active clients per month\n")

ds_caseload <- ds_payment_month %>%
  group_by(pay_period, client_type, household_role) %>%
  summarise(
    active_clients = n_distinct(person_id),
    .groups = "drop"
  ) %>%
  arrange(pay_period, client_type, household_role)

cat("✅ ds_caseload:", nrow(ds_caseload), "rows\n")
cat("   Pay periods:", n_distinct(ds_caseload$pay_period), "\n")
cat("   Client types:", paste(sort(unique(ds_caseload$client_type)), collapse = ", "), "\n")
cat("   Household roles:", paste(sort(unique(ds_caseload$household_role)), collapse = ", "), "\n")

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate\n")

# Check: no duplicates per cell
dup_check <- ds_caseload %>%
  group_by(pay_period, client_type, household_role) %>%
  filter(n() > 1)
stopifnot("Duplicate caseload cells" = nrow(dup_check) == 0)
cat("✅ Unique cells (pay_period × client_type × household_role) — PASSED\n")

# Check: active_clients > 0 in every cell
stopifnot("Zero-count cells should not exist" = all(ds_caseload$active_clients > 0))
cat("✅ All cells have active_clients > 0 — PASSED\n")

# Check: sum of active_clients per pay_period matches unique persons
total_check <- ds_payment_month %>%
  group_by(pay_period) %>%
  summarise(n_persons = n_distinct(person_id), .groups = "drop")
caseload_total <- ds_caseload %>%
  group_by(pay_period) %>%
  summarise(n_total = sum(active_clients), .groups = "drop")
compare <- inner_join(total_check, caseload_total, by = "pay_period")
# Note: a person with a given client_type and role is counted once per cell,
# so total across cells equals total unique persons (since client_type and
# household_role are unique per person-month by invariant)
stopifnot("Caseload total mismatch with person count" =
  all(compare$n_persons == compare$n_total))
cat("✅ Caseload totals match person counts — PASSED\n")

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER — first and last months:\n")
cat("First 3 months:\n")
ds_caseload %>%
  filter(pay_period %in% sort(unique(ds_caseload$pay_period))[1:3]) %>%
  tibble::as_tibble() %>%
  print(n = 20)
cat("\nLast 3 months:\n")
ds_caseload %>%
  filter(pay_period %in% tail(sort(unique(ds_caseload$pay_period)), 3)) %>%
  tibble::as_tibble() %>%
  print(n = 20)

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), timeseries_db)

if (DBI::dbExistsTable(con, "ds_caseload")) {
  DBI::dbRemoveTable(con, "ds_caseload")
}

ds_caseload_write <- ds_caseload %>%
  mutate(pay_period = as.character(pay_period))

DBI::dbWriteTable(con, "ds_caseload", ds_caseload_write)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_caseload")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_caseload))
cat("✅ Wrote", n_written, "rows to", timeseries_db, "::ds_caseload\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 2b complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", timeseries_db, "::ds_caseload\n")
cat("Rows:", nrow(ds_caseload), " | Cols:", ncol(ds_caseload), "\n")
cat("============================================================================\n")
