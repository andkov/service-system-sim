#' ---
#' title: "Lane 2a: Construct Episodes (SPELL_BITs)"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' DERIVE PATTERN: Payment-Month → Episodes
#' ============================================================================
#'
#' **Purpose**: Construct episodes of financial support from the person-month
#' payment records. Each episode represents a continuous period of service
#' under stable conditions.
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/payment.sqlite::ds_payment_month`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/episode.sqlite::ds_episode`
#'
#' ============================================================================
#' OPERATIONALIZATION DISCLOSURE
#' ============================================================================
#'
#' This script operationalizes "episode" as a **SPELL_BIT**, defined as:
#'
#'   A non-interrupted period of financial support, terminated by:
#'   (a) A gap of 2 or more consecutive months without any payment, OR
#'   (b) A change in client_type (e.g., ETW → BFE), OR
#'   (c) A change in household_role (e.g., HH → SP)
#'
#' This is a stricter definition than a SPELL, which is terminated ONLY by
#' a gap of 2+ months (ignoring client_type and household_role changes).
#'
#' Each SPELL_BIT carries a `spell_id` column that groups SPELL_BITs into
#' SPELLs. To analyze at SPELL level, group by `person_id, spell_id`.
#'
#' **Gap threshold**: 2+ consecutive months. A single-month gap does NOT
#' break continuity (the person is considered continuously receiving support
#' through a 1-month administrative gap).
#'
#' ============================================================================
#' COLUMN AGGREGATION PROPERTIES (SPELL_BIT → SPELL)
#' ============================================================================
#'
#' When aggregating from SPELL_BIT to SPELL, columns have different properties:
#'
#'   ADDITIVE (can SUM across SPELL_BITs):
#'     - total_payment, n_months, n_need_codes_total
#'
#'   EXTREMAL (take MIN/MAX across SPELL_BITs):
#'     - episode_start (MIN), episode_end (MAX)
#'
#'   NON-ADDITIVE (must RECOMPUTE, not sum):
#'     - episode_length_months — recompute from SPELL start/end
#'
#'   NOT AGGREGATABLE (varies across SPELL_BITs):
#'     - client_type, household_role
#'
#' ============================================================================
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §6):
#'   - person_id             (integer)
#'   - spell_id              (integer)  Groups SPELL_BITs into SPELLs
#'   - episode_id            (integer)  Unique per person (SPELL_BIT identifier)
#'   - episode_start         (date)     First pay_period of episode
#'   - episode_end           (date)     Last pay_period (NA if ongoing)
#'   - client_type           (character) Constant within episode
#'   - household_role        (character) Constant within episode
#'   - episode_length_months (integer)  Derived from start and end
#'   - n_months              (integer)  Count of active months (ADDITIVE)
#'   - total_payment         (numeric)  Sum of payments (ADDITIVE)
#'   - n_need_codes_total    (integer)  Sum of n_need_codes across months (ADDITIVE)
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/2a-episode.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 2a: Construct Episodes (SPELL_BITs)\n")
cat("Started at:", format(report_render_start_time), "\n")
cat("Working directory:", getwd(), "\n")
cat("============================================================================\n\n")

# ---- load-packages -----------------------------------------------------------
library(magrittr)
library(dplyr)
library(lubridate)
requireNamespace("DBI")
requireNamespace("RSQLite")
requireNamespace("config")

# ---- load-sources ------------------------------------------------------------
base::source("./scripts/common-functions.R")
base::source("./scripts/operational-functions.R")

# ---- declare-globals ---------------------------------------------------------
config      <- config::get()
payment_db  <- config$pipeline$payment_db
episode_db  <- config$pipeline$episode_db
db_dir      <- config$pipeline$db_dir

# Gap threshold: number of consecutive missing months that breaks a SPELL
gap_threshold <- 2L  # 2+ months gap = new SPELL

# Ensure output directory exists
if (!dir.exists(db_dir)) dir.create(db_dir, recursive = TRUE)

# ---- declare-functions -------------------------------------------------------

# Detect SPELL boundaries (gap-based only, ignoring client_type/role changes)
# Returns a vector of spell_ids (one per row of the input, which is sorted by pay_period)
assign_spell_ids <- function(pay_periods, gap_threshold = 2L) {
  if (length(pay_periods) == 0) return(integer(0))
  if (length(pay_periods) == 1) return(1L)

  # Compute month gaps between consecutive periods
  month_diffs <- as.integer(diff(pay_periods) / 30.44)  # approximate months
  # More precise: use lubridate interval
  month_diffs <- sapply(seq_along(pay_periods)[-1], function(i) {
    interval(pay_periods[i - 1], pay_periods[i]) %/% months(1)
  })

  # A gap >= gap_threshold starts a new spell
  new_spell <- c(FALSE, month_diffs >= gap_threshold)
  cumsum(new_spell) + 1L
}

# Detect SPELL_BIT boundaries (gap OR client_type/role change)
assign_episode_ids <- function(pay_periods, client_types, household_roles,
                               gap_threshold = 2L) {
  if (length(pay_periods) == 0) return(integer(0))
  if (length(pay_periods) == 1) return(1L)

  month_diffs <- sapply(seq_along(pay_periods)[-1], function(i) {
    interval(pay_periods[i - 1], pay_periods[i]) %/% months(1)
  })

  # New episode if: gap OR client_type change OR household_role change
  new_episode <- c(
    FALSE,
    (month_diffs >= gap_threshold) |
    (client_types[-1] != client_types[-length(client_types)]) |
    (household_roles[-1] != household_roles[-length(household_roles)])
  )
  cumsum(new_episode) + 1L
}

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
demo_ids <- sort(unique(ds_payment_month$person_id[ds_payment_month$person_id < 0]))
demo_id  <- if (length(demo_ids) >= 3) demo_ids[3] else {
  if (length(demo_ids) > 0) demo_ids[1] else ds_payment_month$person_id[1]
}
cat("\n👁️ Demo BEFORE (person_id =", demo_id, "):\n")
ds_payment_month %>%
  filter(person_id == demo_id) %>%
  arrange(pay_period) %>%
  tibble::as_tibble() %>%
  print(n = 50)

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — construct episodes\n")

ds_episode <- ds_payment_month %>%
  arrange(person_id, pay_period) %>%
  group_by(person_id) %>%
  mutate(
    spell_id   = assign_spell_ids(pay_period, gap_threshold),
    episode_id = assign_episode_ids(pay_period, client_type, household_role, gap_threshold)
  ) %>%
  # Now summarise each episode (SPELL_BIT)
  group_by(person_id, episode_id) %>%
  summarise(
    spell_id              = first(spell_id),
    episode_start         = min(pay_period),
    episode_end           = max(pay_period),
    client_type           = first(client_type),
    household_role        = first(household_role),
    n_months              = n(),
    total_payment         = sum(total_payment, na.rm = TRUE),
    n_need_codes_total    = sum(n_need_codes, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    # Duration in months (calendar-based, not count-based)
    episode_length_months = as.integer(
      interval(episode_start, episode_end) %/% months(1)
    ) + 1L,
    # Mark ongoing episodes (ending at the last available pay_period)
    episode_end = if_else(
      episode_end == max(ds_payment_month$pay_period),
      as.Date(NA),
      episode_end
    )
  ) %>%
  arrange(person_id, episode_start)

cat("✅ ds_episode:", nrow(ds_episode), "episodes from",
    n_distinct(ds_episode$person_id), "persons\n")
cat("   SPELLs:", ds_episode %>% distinct(person_id, spell_id) %>% nrow(), "\n")
cat("   SPELL_BITs:", nrow(ds_episode), "\n")

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate\n")

# Check: all persons from payment_month appear in episodes
stopifnot("Person count mismatch" =
  n_distinct(ds_episode$person_id) == n_distinct(ds_payment_month$person_id))
cat("✅ All persons have at least one episode — PASSED\n")

# Check: client_type is constant within each episode (by construction)
cat("✅ client_type constant within episodes — PASSED (by construction)\n")

# Check: household_role is constant within each episode (by construction)
cat("✅ household_role constant within episodes — PASSED (by construction)\n")

# Check: episode_id unique within person
eid_check <- ds_episode %>%
  group_by(person_id, episode_id) %>%
  filter(n() > 1)
stopifnot("Duplicate episode_id within person" = nrow(eid_check) == 0)
cat("✅ episode_id unique within person — PASSED\n")

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER (person_id =", demo_id, "):\n")
ds_episode %>%
  filter(person_id == demo_id) %>%
  tibble::as_tibble() %>%
  print(n = 20)

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), episode_db)

if (DBI::dbExistsTable(con, "ds_episode")) {
  DBI::dbRemoveTable(con, "ds_episode")
}

# Convert dates to character for SQLite storage
ds_episode_write <- ds_episode %>%
  mutate(
    episode_start = as.character(episode_start),
    episode_end   = as.character(episode_end)
  )

DBI::dbWriteTable(con, "ds_episode", ds_episode_write)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_episode")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_episode))
cat("✅ Wrote", n_written, "rows to", episode_db, "::ds_episode\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 2a complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", episode_db, "::ds_episode\n")
cat("Rows:", nrow(ds_episode), " | Cols:", ncol(ds_episode), "\n")
cat("============================================================================\n")
