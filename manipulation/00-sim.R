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
#'     negative person_ids, hand-crafted to cover edge cases)
#'   - Simulation parameters from `config.yml`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §4):
#'   - payment_id     (integer)  Surrogate key (assigned after combining)
#'   - person_id      (integer)  Links to person
#'   - pay_period     (date)     Month of payment (YYYY-MM-01)
#'   - client_type    (factor)   ETW | BFE
#'   - household_role (factor)   HH | SP
#'   - need_code      (factor)   client_type-specific payment category
#'   - payment_amount (numeric)  Dollar amount
#'
#' **Invariants**:
#'   - One client_type per person_id per pay_period
#'   - Multiple rows per person_id × pay_period allowed (one per need_code)
#'   - household_role constant per person_id within a pay_period
#'
#' **Simulation design** (see corrections-2026-03-17.md C-01):
#'   - Persons have realistic entry timing distributed across simulation window
#'   - Spell durations follow a log-normal distribution (short + long tails)
#'   - ~30% of persons experience a gap and return (RETURNED events)
#'   - ~20% undergo a client_type transition ETW→BFE or BFE→ETW mid-SPELL
#'   - Need code uptake rates calibrated by client_type
#'   - Payment amounts set by need_code × client_type lookup table
#'
#' **Demo persons**: Canonical test cases with person_id < 0, loaded from
#' `./data-public/raw/fictional/demo-persons.csv`. Hand-crafted to cover:
#'   -1: Single ETW spell (simplest)
#'   -2: Single BFE spell
#'   -3: ETW → BFE client_type transition mid-SPELL (new SPELL_BIT)
#'   -4: 1-month gap (stays in same SPELL, new SPELL_BIT)
#'   -5: 2+ month gap (new SPELL, RETURNED event)
#'   -6: Multiple distinct spells (long gaps)
#'   -7: HH in household with SP (-8)
#'   -8: SP in household with HH (-7)
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

# ---- declare-functions -------------------------------------------------------

# Payment amount lookup by client_type × need_code
# Amounts reflect realistic benefit ranges (monthly, in CAD)
payment_amount_lookup <- function(client_type, need_codes) {
  base_amounts <- list(
    ETW = c(
      core           = 763,   shelter        = 490,
      health_benefit = 110,   child_benefit  = 207,
      transportation = 82,    child_care     = 350
    ),
    BFE = c(
      core              = 1035, shelter        = 575,
      health_benefit    = 130,  child_benefit  = 207,
      barrier_supplement = 342, personal_care  = 125,
      utility           = 95
    )
  )
  amounts <- base_amounts[[client_type]]
  # Apply ±15% random variation per person-month
  jitter  <- runif(length(need_codes), 0.85, 1.15)
  round(amounts[need_codes] * jitter, 2)
}

# Need code uptake rates by client_type (probability of receiving each code)
# "core" is always received; others have realistic uptake rates
need_code_uptake <- list(
  ETW = c(
    core           = 1.00, shelter        = 0.85,
    health_benefit = 0.60, child_benefit  = 0.30,
    transportation = 0.25, child_care     = 0.15
  ),
  BFE = c(
    core              = 1.00, shelter           = 0.88,
    health_benefit    = 0.72, child_benefit     = 0.25,
    barrier_supplement = 0.65, personal_care    = 0.40,
    utility           = 0.35
  )
)

# Sample need codes for a given client_type based on uptake probabilities
sample_need_codes <- function(client_type) {
  uptake <- need_code_uptake[[client_type]]
  draws  <- runif(length(uptake))
  names(uptake)[draws < uptake]
}

# Build payment rows for one contiguous active segment
build_segment_payments <- function(person_id, periods, client_type, household_role) {
  if (length(periods) == 0) return(NULL)
  codes <- sample_need_codes(client_type)
  if (length(codes) == 0) codes <- "core"  # guarantee at least core
  do.call(rbind, lapply(periods, function(pp) {
    amounts <- payment_amount_lookup(client_type, codes)
    data.frame(
      person_id      = person_id,
      pay_period     = pp,
      client_type    = client_type,
      household_role = household_role,
      need_code      = codes,
      payment_amount = amounts,
      stringsAsFactors = FALSE,
      row.names = NULL
    )
  }))
}

# Generate a realistic multi-spell payment history for one person.
#
# Behavioral parameters:
#   prob_return       ~ 30% of persons exit and re-enter at least once
#   prob_type_switch  ~ 20% undergo ETW<->BFE transition within a spell
#   spell_dur_median  ~ 8 months (log-normal); long tail to ~48 months
#   gap_months        ~ 1-5 month gap (1 month gap does NOT break a SPELL)
generate_person_payments <- function(person_id, pay_periods,
                                     prob_return      = 0.30,
                                     prob_type_switch = 0.20) {
  n_periods      <- length(pay_periods)
  client_type    <- sample(c("ETW", "BFE"), 1, prob = c(0.70, 0.30))
  household_role <- sample(c("HH",  "SP"),  1, prob = c(0.80, 0.20))

  # Entry: uniform draw across first 80% of the window to allow meaningful history
  max_entry <- max(1L, as.integer(n_periods * 0.80))
  entry_idx <- sample(seq_len(max_entry), 1)

  all_rows <- list()
  current_idx <- entry_idx

  repeat {
    if (current_idx > n_periods) break

    # Spell duration: log-normal, median 8, capped at remaining window
    spell_dur <- min(
      round(rlnorm(1, meanlog = log(8), sdlog = 0.7)),
      n_periods - current_idx + 1L
    )
    spell_dur <- max(spell_dur, 1L)

    spell_periods <- pay_periods[current_idx:(current_idx + spell_dur - 1L)]

    # Client-type transition within this spell? (ETW <-> BFE)
    if (runif(1) < prob_type_switch && spell_dur >= 4L) {
      switch_at  <- sample(2:(spell_dur - 1L), 1)
      seg1_pds   <- spell_periods[seq_len(switch_at - 1L)]
      seg2_pds   <- spell_periods[switch_at:spell_dur]
      new_type   <- if (client_type == "ETW") "BFE" else "ETW"

      rows1 <- build_segment_payments(person_id, seg1_pds, client_type,    household_role)
      rows2 <- build_segment_payments(person_id, seg2_pds, new_type,       household_role)
      all_rows <- c(all_rows, list(rows1), list(rows2))
      client_type <- new_type   # carry forward switched type
    } else {
      rows <- build_segment_payments(person_id, spell_periods, client_type, household_role)
      all_rows <- c(all_rows, list(rows))
    }

    current_idx <- current_idx + spell_dur

    # Decide whether person returns after a gap
    if (runif(1) > prob_return) break
    if (current_idx > n_periods) break

    # Gap length: 1–5 months (1-month gap keeps person in same SPELL;
    # 2+ month gap starts a new SPELL — controlled by downstream 2a-episode.R)
    gap <- sample(1:5, 1, prob = c(0.20, 0.25, 0.25, 0.15, 0.15))
    current_idx <- current_idx + gap
    if (current_idx > n_periods) break

    # After a gap, small chance of household_role change (e.g., SP→HH)
    if (runif(1) < 0.05) {
      household_role <- if (household_role == "HH") "SP" else "HH"
    }
  }

  do.call(rbind, all_rows)
}

# ==============================================================================
# SECTION 1: LOAD DEMO PERSONS
# ==============================================================================
# ---- load-demo-persons -------------------------------------------------------
cat("\n📂 SECTION 1: Load demo persons\n")

# Load canonical demo persons from rectangular data file
if (file.exists(demo_persons_file)) {
  ds_demo <- readr::read_csv(demo_persons_file, show_col_types = FALSE) %>%
    mutate(pay_period = as.Date(pay_period)) %>%
    select(-any_of("payment_id"))   # drop any stale surrogate; reassigned below
  cat("✅ Loaded", nrow(ds_demo), "demo payment records from", demo_persons_file, "\n")
  cat("   Demo person_ids:", paste(sort(unique(ds_demo$person_id)), collapse = ", "), "\n")
} else {
  cat("⚠️  Demo persons file not found:", demo_persons_file, "\n")
  cat("   Expected path:", demo_persons_file, "\n")
  cat("   Pipeline will generate data without canonical demo persons.\n")
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

# Each person gets their own independent draw.  set.seed() is called once
# before the loop so the full population is reproducible.
ds_random_list <- lapply(seq_len(n_persons), function(i) {
  generate_person_payments(person_id = i, pay_periods = pay_periods)
})

# Drop NULL results (persons with no payments — edge case for very late entry)
ds_random <- do.call(rbind, Filter(Negate(is.null), ds_random_list))

cat("✅ Generated", nrow(ds_random), "payment records for", n_persons, "random persons\n")

# Quick summary of simulation quality
spell_summary <- ds_random %>%
  group_by(person_id) %>%
  summarise(n_months = n_distinct(pay_period), .groups = "drop")
cat("   Persons with data:", nrow(spell_summary), "\n")
cat("   Median active months per person:", median(spell_summary$n_months), "\n")

# ==============================================================================
# SECTION 3: COMBINE & FINALIZE
# ==============================================================================
# ---- combine -----------------------------------------------------------------
cat("\n📋 SECTION 3: Combine demo + random persons\n")

ds_payment <- bind_rows(ds_demo, ds_random) %>%
  mutate(
    pay_period     = as.Date(pay_period),
    client_type    = as.character(client_type),
    household_role = as.character(household_role),
    need_code      = as.character(need_code)
  ) %>%
  arrange(person_id, pay_period, need_code) %>%
  mutate(payment_id = row_number()) %>%          # fresh surrogate after combining
  select(payment_id, person_id, pay_period, client_type, household_role,
         need_code, payment_amount)

cat("✅ Combined dataset:", nrow(ds_payment), "rows,", ncol(ds_payment), "cols\n")
cat("   Unique persons:", n_distinct(ds_payment$person_id), "\n")
cat("   Pay period range:", format(min(ds_payment$pay_period), "%Y-%m"),
    "to", format(max(ds_payment$pay_period), "%Y-%m"), "\n")
cat("   Client type mix:\n")
ds_payment %>%
  distinct(person_id, pay_period, client_type) %>%
  count(client_type) %>%
  mutate(pct = scales::percent(n / sum(n), accuracy = 1)) %>%
  print()

# ==============================================================================
# SECTION 4: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 4: Validate invariants\n")

valid_etw_codes <- names(need_code_uptake$ETW)
valid_bfe_codes <- names(need_code_uptake$BFE)

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
    (client_type == "ETW" & !(need_code %in% valid_etw_codes)) |
    (client_type == "BFE" & !(need_code %in% valid_bfe_codes))
  )
stopifnot("Invariant violated: need_code invalid for client_type" = nrow(invalid_codes) == 0)
cat("✅ Invariant 3: Need codes valid for client_type — PASSED\n")

# ==============================================================================
# SECTION 5: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 5: Demonstrate\n")

# 5a. Population-level behavioural summary
cat("\n--- Population behaviour summary ---\n")
person_activity <- ds_payment %>%
  group_by(person_id) %>%
  summarise(
    n_active_months = n_distinct(pay_period),
    n_client_types  = n_distinct(client_type),
    .groups = "drop"
  )
cat("Persons with client_type transition (ETW<->BFE):",
    sum(person_activity$n_client_types > 1), "\n")

# 5b. Show a canonical demo person (most complex case: -6 multiple spells)
demo_ids <- sort(unique(ds_payment$person_id[ds_payment$person_id < 0]))
if (length(demo_ids) > 0) {
  # Prefer person -6 (multiple spells); fall back to first available
  demo_id <- if (-6L %in% demo_ids) -6L else demo_ids[length(demo_ids)]
  cat("\n--- Demo person_id =", demo_id, "(canonical: multiple spells) ---\n")
} else {
  # Pick a random person with the most complex history
  demo_id <- ds_payment %>%
    group_by(person_id) %>%
    summarise(n_months = n_distinct(pay_period), .groups = "drop") %>%
    slice_max(n_months, n = 1) %>%
    pull(person_id)
  cat("\n--- Sample person_id =", demo_id, "(most active in simulated population) ---\n")
}

ds_payment %>%
  filter(person_id == demo_id) %>%
  arrange(pay_period, need_code) %>%
  tibble::as_tibble() %>%
  print(n = 60)

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
