#' ---
#' title: "Lane 3a: Classify Episode Boundaries as Events"
#' author: "service-system-sim"
#' date: "2026-03-17"
#' ---
#'
#' ============================================================================
#' DERIVE PATTERN: Episode → Events (NEW / RETURNED / CLOSED)
#' ============================================================================
#'
#' **Purpose**: Classify episode boundaries as events. Each episode generates
#' at most two events: one at its start (NEW or RETURNED) and one at its end
#' (CLOSED). Events are the "flow" counterpart to the caseload "stock".
#'
#' **Input**:
#'   - `./data-private/derived/pipeline/episode.sqlite::ds_episode`
#'
#' **Output**:
#'   - `./data-private/derived/pipeline/episode.sqlite::ds_event`
#'
#' **Table schema** (see `./analysis/sim-1/universe-guide.md` §7):
#'   - person_id       (integer)
#'   - event_month      (date)     pay_period in which the event is recorded
#'   - event_type       (character) NEW | RETURNED | CLOSED
#'   - client_type      (character)
#'   - household_role   (character)
#'   - episode_id       (integer)  Links back to ds_episode
#'
#' **Event type definitions**:
#'   - NEW:      Episode start; person has never had a prior episode
#'   - RETURNED: Episode start; person had at least one prior episode
#'   - CLOSED:   Episode end; person leaves the active caseload
#'
#' **Note**: An ongoing episode (episode_end = NA) generates only a start
#' event. No CLOSED event is produced until the episode ends.
#'
#' ============================================================================

#+ echo=F
# rmarkdown::render(input = "./manipulation/3a-event.R") # run to knit
# ---- setup -------------------------------------------------------------------
rm(list = ls(all.names = TRUE))
cat("\014")
report_render_start_time <- Sys.time()
cat("============================================================================\n")
cat("Lane 3a: Classify Episode Boundaries as Events\n")
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
config     <- config::get()
episode_db <- config$pipeline$episode_db

# ---- declare-functions -------------------------------------------------------
# (none needed — logic inline)

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data ---------------------------------------------------------------
cat("📂 SECTION 1: Load data\n")

con <- DBI::dbConnect(RSQLite::SQLite(), episode_db)
ds_episode <- DBI::dbReadTable(con, "ds_episode") %>%
  mutate(
    episode_start = as.Date(episode_start),
    episode_end   = as.Date(episode_end)
  )
DBI::dbDisconnect(con)

cat("✅ Loaded ds_episode:", nrow(ds_episode), "episodes from",
    n_distinct(ds_episode$person_id), "persons\n")

# ---- demo-before -------------------------------------------------------------
demo_ids <- sort(unique(ds_episode$person_id[ds_episode$person_id < 0]))
demo_id  <- if (length(demo_ids) >= 3) demo_ids[3] else {
  # Pick a person with multiple episodes for a more interesting demo
  multi_ep <- ds_episode %>%
    count(person_id) %>%
    filter(n > 1) %>%
    slice_sample(n = 1) %>%
    pull(person_id)
  if (length(multi_ep) > 0) multi_ep else ds_episode$person_id[1]
}
cat("\n👁️ Demo BEFORE — episodes for person_id =", demo_id, ":\n")
ds_episode %>%
  filter(person_id == demo_id) %>%
  tibble::as_tibble() %>%
  print(n = 20)

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform ---------------------------------------------------------------
cat("\n🔧 SECTION 2: Transform — classify events\n")

# Determine episode order within each person (for NEW vs RETURNED)
ds_episode_ordered <- ds_episode %>%
  arrange(person_id, episode_start) %>%
  group_by(person_id) %>%
  mutate(episode_seq = row_number()) %>%
  ungroup()

# START events: NEW (first episode) or RETURNED (subsequent episodes)
ds_start_events <- ds_episode_ordered %>%
  transmute(
    person_id,
    event_month    = episode_start,
    event_type     = if_else(episode_seq == 1L, "NEW", "RETURNED"),
    client_type,
    household_role,
    episode_id
  )

# END events: CLOSED (only for episodes that have ended)
ds_end_events <- ds_episode_ordered %>%
  filter(!is.na(episode_end)) %>%
  transmute(
    person_id,
    event_month    = episode_end,
    event_type     = "CLOSED",
    client_type,
    household_role,
    episode_id
  )

# Combine
ds_event <- bind_rows(ds_start_events, ds_end_events) %>%
  arrange(person_id, event_month, event_type)

cat("✅ ds_event:", nrow(ds_event), "events\n")
cat("   NEW:", sum(ds_event$event_type == "NEW"), "\n")
cat("   RETURNED:", sum(ds_event$event_type == "RETURNED"), "\n")
cat("   CLOSED:", sum(ds_event$event_type == "CLOSED"), "\n")

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate ----------------------------------------------------------------
cat("\n🔍 SECTION 3: Validate\n")

# Check: every person has exactly one NEW event
n_new_per_person <- ds_event %>%
  filter(event_type == "NEW") %>%
  count(person_id)
stopifnot("Every person must have exactly one NEW event" =
  all(n_new_per_person$n == 1))
cat("✅ Every person has exactly one NEW event — PASSED\n")

# Check: RETURNED count = total episodes - number of persons
n_returned <- sum(ds_event$event_type == "RETURNED")
expected_returned <- nrow(ds_episode) - n_distinct(ds_episode$person_id)
stopifnot("RETURNED count mismatch" = n_returned == expected_returned)
cat("✅ RETURNED count matches (episodes - persons):", n_returned, "— PASSED\n")

# Check: CLOSED events only for non-ongoing episodes
n_closed <- sum(ds_event$event_type == "CLOSED")
n_ended <- sum(!is.na(ds_episode$episode_end))
stopifnot("CLOSED count mismatch with ended episodes" = n_closed == n_ended)
cat("✅ CLOSED count matches ended episodes:", n_closed, "— PASSED\n")

# Check: event_type values are valid
stopifnot("Invalid event_type values" =
  all(ds_event$event_type %in% c("NEW", "RETURNED", "CLOSED")))
cat("✅ All event_type values valid — PASSED\n")

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after --------------------------------------------------------------
cat("\n👁️ SECTION 4: Demo AFTER — events for person_id =", demo_id, ":\n")
ds_event %>%
  filter(person_id == demo_id) %>%
  tibble::as_tibble() %>%
  print(n = 20)

# ==============================================================================
# SECTION 5: SAVE TO DATABASE
# ==============================================================================
# ---- save-to-db --------------------------------------------------------------
cat("\n💾 SECTION 5: Save to database\n")

con <- DBI::dbConnect(RSQLite::SQLite(), episode_db)

if (DBI::dbExistsTable(con, "ds_event")) {
  DBI::dbRemoveTable(con, "ds_event")
}

ds_event_write <- ds_event %>%
  mutate(event_month = as.character(event_month))

DBI::dbWriteTable(con, "ds_event", ds_event_write)

# Round-trip verification
n_written <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ds_event")$n
stopifnot("Round-trip row count mismatch" = n_written == nrow(ds_event))
cat("✅ Wrote", n_written, "rows to", episode_db, "::ds_event\n")

DBI::dbDisconnect(con)

# ---- session-info ------------------------------------------------------------
cat("\n============================================================================\n")
cat("Lane 3a complete\n")
cat("Duration:", round(difftime(Sys.time(), report_render_start_time, units = "secs"), 1), "seconds\n")
cat("Output:", episode_db, "::ds_event\n")
cat("Rows:", nrow(ds_event), " | Cols:", ncol(ds_event), "\n")
cat("============================================================================\n")
