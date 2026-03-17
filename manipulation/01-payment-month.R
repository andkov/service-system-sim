#' ---
#' title: "Lane 1: Collapse Payments to Person-Month"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' DERIVE PATTERN: Payment → Payment-Month
#' ============================================================================
#'
#' **Purpose**: Collapse the atomic `ds_payment` table (one row per person ×
#' month × need_code) into `ds_payment_month` (one row per person × month).
#' This is the immediate source for episode construction and caseload counting.
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment_month`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §5):
#'   - person_id       (integer)
#'   - pay_period       (date)
#'   - client_type      (character)  Consistent within month (invariant)
#'   - household_role   (character)  Consistent within month (invariant)
#'   - n_need_codes     (integer)    Count of distinct need codes received
#'   - total_payment    (numeric)    Sum of payment_amount for the month
#'
#' **Transformation**: GROUP BY person_id, pay_period; aggregate need codes
#' and payment amounts. client_type and household_role are carried through
#' (guaranteed unique per person-month by upstream invariant).
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/01-payment-month.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 1: Collapse Payments to Person-Month\n")
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
config  <- config::get()
db_path <- config$pipeline$payment_db

# ---- declare-functions -------------------------------------------------------
# (none needed for this transformation)

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data ---------------------------------------------------------------
cat("📂 SECTION 1: Load data\n")

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
ds_payment <- DBI::dbReadTable(con, "ds_payment") %>%
  mutate(pay_period = as.Date(pay_period))
DBI::dbDisconnect(con)

cat("✅ Loaded ds_payment:", nrow(ds_payment), "rows,", ncol(ds_payment), "cols\n")
cat("   Unique persons:", n_distinct(ds_payment$person_id), "\n")
cat("   Pay periods:", n_distinct(ds_payment$pay_period), "\n")

# ---- demo-before -------------------------------------------------------------
# Show a demo person BEFORE transformation
demo_ids <- sort(unique(ds_payment$person_id[ds_payment$person_id < 0]))
demo_id  <- if (length(demo_ids) > 0) demo_ids[1] else ds_payment$person_id[1]
cat("\n👁️ Demo BEFORE (person_id =", demo_id, "):\n")
ds_payment %>%
  filter(person_id == demo_id) %>%
  arrange(pay_period, need_code) %>%
  tibble::as_tibble() %>%
  print(n = 30)

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — collapse to person-month\n")

ds_payment_month <- ds_payment %>%
  group_by(person_id, pay_period) %>%
  summarise(
    client_type    = first(client_type),     # unique per person-month (invariant)
    household_role = first(household_role),   # unique per person-month (invariant)
    n_need_codes   = n_distinct(need_code),
    total_payment  = sum(payment_amount, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(person_id, pay_period)

cat("✅ ds_payment_month:", nrow(ds_payment_month), "rows,", ncol(ds_payment_month), "cols\n")
cat("   Compression:", nrow(ds_payment), "→", nrow(ds_payment_month), "rows",
    "(", round(nrow(ds_payment_month) / nrow(ds_payment) * 100, 1), "%)\n")

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate\n")

# Check: one row per person × pay_period
dup_check <- ds_payment_month %>%
  group_by(person_id, pay_period) %>%
  filter(n() > 1)
stopifnot("Duplicate person-month rows detected" = nrow(dup_check) == 0)
cat("✅ Uniqueness: one row per person × pay_period — PASSED\n")

# Check: all persons preserved
stopifnot("Person count mismatch" =
  n_distinct(ds_payment_month$person_id) == n_distinct(ds_payment$person_id))
cat("✅ All persons preserved — PASSED\n")

# Check: total payment sums match
total_source <- sum(ds_payment$payment_amount, na.rm = TRUE)
total_derived <- sum(ds_payment_month$total_payment, na.rm = TRUE)
stopifnot("Total payment mismatch" = abs(total_source - total_derived) < 0.01)
cat("✅ Total payment preserved ($", format(total_derived, big.mark = ","), ") — PASSED\n")

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER (person_id =", demo_id, "):\n")
ds_payment_month %>%
  filter(person_id == demo_id) %>%
  tibble::as_tibble() %>%
  print(n = 30)

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)

if (DBI::dbExistsTable(con, "ds_payment_month")) {
  DBI::dbRemoveTable(con, "ds_payment_month")
}
DBI::dbWriteTable(con, "ds_payment_month", ds_payment_month)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_payment_month")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_payment_month))
cat("✅ Wrote", n_written, "rows to", db_path, "::ds_payment_month\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 1 complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", db_path, "::ds_payment_month\n")
cat("Rows:", nrow(ds_payment_month), " | Cols:", ncol(ds_payment_month), "\n")
cat("============================================================================\n")
