#' ---
#' title: "Lane 0: Simulate Payment Data"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' SIM PATTERN: Data Generation for Social Services Simulation
#' ============================================================================
#'
#' **Purpose**: Generate a synthetic `ds_payment` table representing atomic
#' financial support payments to social services clients. This table is the
#' single simulated data object in the pipeline — everything else is derived.
#'
#' **Pattern**: Sim (not Ferry). This script generates data rather than
#' transporting it from an external source. It serves the same structural
#' role as a Ferry script — producing the raw input for all downstream
#' transformations — but its internal logic is generative, not extractive.
#'
#' **Input**:
#'   - `./data-public/raw/fictional/demo-persons.csv` (canonical demo persons,
#'     negative person_ids, sourced from real RDB test cases)
#'   - Simulation parameters from `config.yml`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §4):
#'   - payment_id   (integer)  Surrogate key
#'   - person_id    (integer)  Links to person
#'   - pay_period   (date)     Month of payment (YYYY-MM-01)
#'   - client_type  (factor)   ETW | BFE
#'   - household_role (factor) HH | SP
#'   - need_code    (factor)   client_type-specific payment category
#'   - payment_amount (numeric) Dollar amount
#'
#' **Invariants**:
#'   - One client_type per person_id per pay_period
#'   - Multiple rows per person_id × pay_period allowed (one per need_code)
#'   - household_role constant per person_id within a pay_period
#'
#' **Demo persons**: Canonical test cases with person_id < 0, loaded from
#' rectangular data file (not invented — sourced from real administrative
#' patterns in the RDB).
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/00-sim.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE)) # Clear memory
cat("\014") # Clear console
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 0: Simulate Payment Data\n")
cat("Started at:", format(report_render_start_time), "\n")
cat("Working directory:", getwd(), "\n")
cat("============================================================================\n\n")

# ---- load-packages -----------------------------------------------------------
library(magrittr)
library(dplyr)
library(tidyr)
library(lubridate)
requireNamespace("DBI")
requireNamespace("RSQLite")
requireNamespace("config")
requireNamespace("readr")

# ---- load-sources ------------------------------------------------------------
base::source("./scripts/common-functions.R")
base::source("./scripts/operational-functions.R")

# ---- declare-globals ---------------------------------------------------------
config <- config::get()

# Simulation parameters
time_start   <- as.Date(config$simulation$time_start)
time_end     <- as.Date(config$simulation$time_end)
n_persons    <- config$simulation$n_persons
random_seed  <- config$simulation$random_seed

# Database
db_dir  <- config$pipeline$db_dir
db_path <- config$pipeline$payment_db

# Demo persons file
demo_persons_file <- config$simulation$demo_persons_file

# Ensure output directory exists
if (!dir.exists(db_dir)) dir.create(db_dir, recursive = TRUE)

# Time spine (all pay periods)
pay_periods <- seq.Date(time_start, time_end, by = "month")
cat("📅 Time range:", format(time_start, "%Y-%m"), "to", format(time_end, "%Y-%m"),
    "(", length(pay_periods), "months)\n")
cat("👥 Random persons to generate:", n_persons, "\n")
cat("🎲 Random seed:", random_seed, "\n")

# Need code taxonomy (from universe-guide.md §3)
need_codes_etw <- c("core", "shelter", "health_benefit", "child_benefit",
                    "transportation", "child_care")
need_codes_bfe <- c("core", "shelter", "health_benefit", "child_benefit",
                    "barrier_supplement", "personal_care", "utility")

# ---- declare-functions -------------------------------------------------------

# Placeholder: Generate payment history for a single person
# TODO: Implement realistic simulation logic
#   - Career trajectory (entry, duration, exit, possible re-entry)
#   - Client type assignment (ETW vs BFE, possible transitions)
#   - Household role (mostly stable, rare changes)
#   - Need code assignment (subset of available codes per client_type)
#   - Payment amounts (realistic ranges by need_code and client_type)
generate_person_payments <- function(person_id, pay_periods, seed = NULL) {
  # TODO: Replace with realistic simulation logic
  # This placeholder generates a minimal payment history
  if (!is.null(seed)) set.seed(seed)

  # Placeholder: random entry point and duration
  n_periods <- length(pay_periods)
  entry_idx <- sample(1:max(1, n_periods - 6), 1)
  duration  <- sample(3:min(24, n_periods - entry_idx + 1), 1)
  active_periods <- pay_periods[entry_idx:(entry_idx + duration - 1)]

  # Placeholder: assign client_type (stable for now)
  client_type <- sample(c("ETW", "BFE"), 1, prob = c(0.7, 0.3))
  household_role <- sample(c("HH", "SP"), 1, prob = c(0.8, 0.2))

  # Placeholder: assign need codes (core + random subset)
  available_codes <- if (client_type == "ETW") need_codes_etw else need_codes_bfe
  n_codes <- sample(2:min(4, length(available_codes)), 1)
  assigned_codes <- c("core", sample(setdiff(available_codes, "core"), n_codes - 1))

  # Build payment rows: one row per person × pay_period × need_code
  expand.grid(
    person_id      = person_id,
    pay_period     = active_periods,
    need_code      = assigned_codes,
    stringsAsFactors = FALSE
  ) %>%
    as.data.frame() %>%
    mutate(
      client_type    = client_type,
      household_role = household_role,
      payment_amount = round(runif(n(), 100, 1500), 2)  # TODO: realistic amounts
    )
}

# ==============================================================================
# SECTION 1: LOAD DEMO PERSONS
# ==============================================================================
# ---- load-demo-persons -------------------------------------------------------
cat("\n📂 SECTION 1: Load demo persons\n")

# Load canonical demo persons from rectangular data file
if (file.exists(demo_persons_file)) {
  ds_demo <- readr::read_csv(demo_persons_file, show_col_types = FALSE)
  cat("✅ Loaded", nrow(ds_demo), "demo payment records from", demo_persons_file, "\n")
  cat("   Demo person_ids:", paste(sort(unique(ds_demo$person_id)), collapse = ", "), "\n")
} else {
  cat("⚠️  Demo persons file not found:", demo_persons_file, "\n")
  cat("   Pipeline will generate data without canonical demo persons.\n")
  cat("   To add demo persons, create the file with columns:\n")
  cat("   person_id, pay_period, client_type, household_role, need_code, payment_amount\n")
  ds_demo <- data.frame(
    person_id      = integer(0),
    pay_period     = as.Date(character(0)),
    client_type    = character(0),
    household_role = character(0),
    need_code      = character(0),
    payment_amount = numeric(0)
  )
}

# ==============================================================================
# SECTION 2: SIMULATE RANDOM PERSONS
# ==============================================================================
# ---- simulate ----------------------------------------------------------------
cat("\n🔧 SECTION 2: Simulate random persons\n")
set.seed(random_seed)

# TODO: Replace with realistic simulation engine
# Current implementation: simple placeholder for pipeline scaffolding
ds_random <- do.call(rbind, lapply(
  seq_len(n_persons),
  function(i) generate_person_payments(
    person_id   = i,
    pay_periods = pay_periods,
    seed        = random_seed + i
  )
))

cat("✅ Generated", nrow(ds_random), "payment records for", n_persons, "random persons\n")

# ==============================================================================
# SECTION 3: COMBINE & FINALIZE
# ==============================================================================
# ---- combine -----------------------------------------------------------------
cat("\n📋 SECTION 3: Combine demo + random persons\n")

ds_payment <- bind_rows(ds_demo, ds_random) %>%
  mutate(
    payment_id     = row_number(),
    pay_period     = as.Date(pay_period),
    client_type    = as.character(client_type),
    household_role = as.character(household_role),
    need_code      = as.character(need_code)
  ) %>%
  select(payment_id, person_id, pay_period, client_type, household_role,
         need_code, payment_amount) %>%
  arrange(person_id, pay_period, need_code)

cat("✅ Combined dataset:", nrow(ds_payment), "rows,", ncol(ds_payment), "cols\n")
cat("   Unique persons:", n_distinct(ds_payment$person_id), "\n")
cat("   Pay period range:", format(min(ds_payment$pay_period), "%Y-%m"),
    "to", format(max(ds_payment$pay_period), "%Y-%m"), "\n")
cat("   Client types:", paste(sort(unique(ds_payment$client_type)), collapse = ", "), "\n")

# ==============================================================================
# SECTION 4: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 4: Validate invariants\n")

# Invariant 1: One client_type per person_id per pay_period
ct_check <- ds_payment %>%
  group_by(person_id, pay_period) %>%
  summarise(n_types = n_distinct(client_type), .groups = "drop") %>%
  filter(n_types > 1)
stopifnot("Invariant violated: multiple client_types per person-month" = nrow(ct_check) == 0)
cat("✅ Invariant 1: One client_type per person-month — PASSED\n")

# Invariant 2: household_role constant per person_id within pay_period
hr_check <- ds_payment %>%
  group_by(person_id, pay_period) %>%
  summarise(n_roles = n_distinct(household_role), .groups = "drop") %>%
  filter(n_roles > 1)
stopifnot("Invariant violated: multiple household_roles per person-month" = nrow(hr_check) == 0)
cat("✅ Invariant 2: One household_role per person-month — PASSED\n")

# Invariant 3: need_codes valid for client_type
invalid_codes <- ds_payment %>%
  filter(
    (client_type == "ETW" & !(need_code %in% need_codes_etw)) |
    (client_type == "BFE" & !(need_code %in% need_codes_bfe))
  )
stopifnot("Invariant violated: need_code invalid for client_type" = nrow(invalid_codes) == 0)
cat("✅ Invariant 3: Need codes valid for client_type — PASSED\n")

# ==============================================================================
# SECTION 5: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 5: Demonstrate — sample person\n")

# Show a sample person (first available demo person, or random)
demo_ids <- sort(unique(ds_payment$person_id[ds_payment$person_id < 0]))
if (length(demo_ids) > 0) {
  demo_id <- demo_ids[1]
  cat("Showing demo person_id =", demo_id, "\n")
} else {
  demo_id <- ds_payment$person_id[1]
  cat("No demo persons available. Showing person_id =", demo_id, "\n")
}

ds_payment %>%
  filter(person_id == demo_id) %>%
  as.data.frame() %>%
  head(50) %>%
  print()

# ==============================================================================
# SECTION 6: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 6: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)

# Drop existing table if present (simulation is regenerative)
if (DBI::dbExistsTable(con, "ds_payment")) {
  DBI::dbRemoveTable(con, "ds_payment")
}

DBI::dbWriteTable(con, "ds_payment", ds_payment)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_payment")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_payment))
cat("✅ Wrote", n_written, "rows to", db_path, "::ds_payment\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 0 complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", db_path, "::ds_payment\n")
cat("Rows:", nrow(ds_payment), " | Cols:", ncol(ds_payment), "\n")
cat("============================================================================\n")
