# Corrections Log: 2026-03-17

Pipeline review corrections and decisions for the next version.
Companion to [`universe-guide.md`](universe-guide.md) and [`../../manipulation/pipeline.md`](../../manipulation/pipeline.md).

---

## C-01 · Simulation is a Placeholder — No Realistic Behavioral Patterns

**File**: `manipulation/00-sim.R`
**Priority**: Critical

**Issue**: The current `generate_person_payments()` function produces a single continuous episode per person — one fixed `client_type`, one fixed `household_role`, no gaps, no transitions, no re-entries. This means:

- `ds_event` will contain only `NEW` and `CLOSED` events — **zero `RETURNED` events**.
- The stock-flow identity will hold trivially, providing no stress test.
- The simulation is useless as a teaching/testing tool for forecasting pipelines.

**Required fix**: Implement a realistic behavioral simulation engine with:

- **Entry probability**: Not all persons enter at the same time. Entry should be distributed across the simulation window.
- **Spell duration**: Realistic distributions (e.g., log-normal) — some short (1–3 months), some long (12–36 months).
- **Gap probability**: After exiting, some persons re-enter within 1–6 months (gap = 1 month → continuity in SPELL, new SPELL_BIT); others after 12+ months (new SPELL entirely).
- **Client type transitions**: A subset of persons transitions ETW → BFE (or vice versa) mid-spell, generating a new SPELL_BIT but continuing the same SPELL.
- **Household role changes**: Rare — SP occasionally becomes HH (or vice versa) after a gap.
- **Payment amounts**: Realistic by `client_type` and `need_code` (BFE `core` > ETW `core`; `shelter` uniform, etc.).
- **Need code mix**: Should reflect realistic uptake rates (e.g., 95% have `core`, 80% `shelter`, 30% `health_benefit`, etc.).

**Decision**: Implement in two phases:
- **Phase A** (this sprint): Realistic entry/exit/re-entry patterns with multi-spell persons. Keep amounts approximately realistic. Target: at least 20% of persons with ≥2 spells.
- **Phase B** (next sprint): Calibrate to match empirical distributions from real caseload data if/when available.

---

## C-02 · demo-persons.csv Does Not Exist

**File**: `manipulation/00-sim.R`, `config.yml`
**Priority**: Critical

**Issue**: `config$simulation$demo_persons_file` points to `./data-public/raw/fictional/demo-persons.csv`, which does not exist. When 00-sim.R runs, it falls back gracefully (empty data frame), but this means the "canonical demo persons" feature — a key design principle stated in `pipeline.prompt.md` — is never exercised.

**Required fix**: Create `demo-persons.csv` with 5–8 canonical cases covering:

- Person with single continuous ETW spell (simplest case)
- Person with single continuous BFE spell
- Person transitioning ETW → BFE mid-spell (new SPELL_BIT, same SPELL)
- Person with gap of exactly 1 month (should remain in same SPELL)
- Person with gap of 2+ months (new SPELL, generates RETURNED event)
- Person with multiple distinct spells separated by long gaps
- HH/SP pair from same household (same spell structure, different roles)

Person IDs must be negative integers to distinguish from simulated persons.

**Decision**: Create the CSV manually with hand-crafted records. Persons use `person_id` in range -1 to -8. Dates must fall within simulation range 2015-01 to 2024-12.

---

## C-03 · Gap Threshold: Definitional Inconsistency Across Documents

**Files**: `analysis/sim-1/universe-guide.md` §6, `ai/project/glossary.md`, `manipulation/2a-episode.R`
**Priority**: High

**Issue**: Three sources define the gap rule differently:

| Source | Rule |
|---|---|
| `universe-guide.md` §6 | "A payment gap — **at least one** `pay_period` with no payment" starts a new episode |
| `glossary.md` (SPELL) | "separated from other SPELLs by **two or more** consecutive months of non-use" |
| `2a-episode.R` code | `gap_threshold <- 2L` — gap ≥ 2 months breaks continuity |

The code matches the glossary (2+ months), but the universe-guide says "at least one" (≥1 month). These are contradictory.

**Decision**: Adopt the glossary definition as authoritative:
- **SPELL boundary**: 2+ consecutive months without payment
- **SPELL_BIT boundary**: same OR a change in `client_type`/`household_role`
- A **1-month gap** does NOT break a SPELL (person is considered continuously supported through a short administrative interruption).
- Universe-guide §6 must be corrected to say "two or more consecutive months."

**Fix**: Update `universe-guide.md` §6 "Episode Boundary Rules" item 1.

---

## C-04 · Column Name Inconsistency: `role_type` vs `household_role`

**Files**: `analysis/sim-1/universe-guide.md` §2, pipeline scripts, `ai/project/glossary.md`
**Priority**: High

**Issue**: The universe-guide §2 introduces the field as `role_type` (with values `HH`, `SP`, `DP`). The actual pipeline columns are named `household_role` (in `ds_payment`, `ds_payment_month`, `ds_episode`, `ds_event`, `ds_caseload`). The glossary uses `ROLE_TYPE`.

**Decision**: `household_role` is the implemented name and should be authoritative. Update universe-guide §2 to use `household_role` instead of `role_type`. The glossary reference `ROLE_TYPE` should be treated as the RDB/legacy field name; the simulation uses `household_role`.

**Fix**: Update `universe-guide.md` §2 People table and surrounding text.

---

## C-05 · CLOSED Event Timestamp Ambiguity

**Files**: `manipulation/3a-event.R`, `analysis/sim-1/universe-guide.md` §7, `data-public/metadata/CACHE-manifest.md`
**Priority**: Medium

**Issue**: A CLOSED event is assigned `event_month = episode_end` (the last month the person received payment). This means the same month in which a person is still in the caseload (counted as `active_clients` in `ds_caseload`) also produces a CLOSED event. In the stock-flow identity:

$$\text{Caseload}(t) = \text{Caseload}(t-1) + \text{NEW}(t) + \text{RETURNED}(t) - \text{CLOSED}(t)$$

If CLOSED events are recorded in the last *active* month, then a person CLOSED in month t is still counted in the caseload at month t, but subtracted from it simultaneously. This creates an off-by-one ledger problem.

**Decision**: CLOSED event month should be `episode_end + 1 month` — the first month the person is *absent*, not the last month they were *present*. This aligns with the stock-flow identity: CLOSED(t) subtracts from caseload starting at t+1. Under this convention:
- `event_month` for CLOSED = first month of absence
- `event_month` for NEW/RETURNED = first month of presence (already correct)

**Fix**: Update `3a-event.R` CLOSED event construction. Update universe-guide §7 event type definitions. Update `ds_event_count` downstream (4a, 05).

---

## C-06 · Stock-Flow Identity Is a Soft Warning, Not a Hard Stop

**File**: `manipulation/05-caseload-event.R`
**Priority**: Medium

**Issue**: The `stopifnot()` for the stock-flow identity violation is commented out with a `# TODO` comment. The script issues a warning but continues execution. This defeats the purpose of the reconciliation step — identity violations should halt the pipeline.

**Decision**: Once C-05 (CLOSED timing) is resolved and the simulation produces valid output, make the identity check a hard `stopifnot()`. The universe-guide states: "Any discrepancy is a pipeline bug, not a modeling finding."

**Fix**: Uncomment and restore the `stopifnot` in the validate section of `05-caseload-event.R`.

---

## C-07 · Script Numbering Inconsistency

**Files**: `manipulation/` directory, `flow.R`
**Priority**: Low

**Issue**: Script numbering follows no consistent convention:
- `00-sim.R` (two-digit prefix)
- `01-payment-month.R` (two-digit prefix)
- `2a-episode.R` (single-digit prefix)
- `2b-caseload.R` (single-digit prefix)
- `3a-event.R` (single-digit prefix)
- `4a-event-count.R` (single-digit prefix)
- `05-caseload-event.R` (two-digit prefix, no letter suffix)
- `99-export.R` (two-digit prefix)

The inconsistency (some zero-padded, some not; some with letter suffixes, some without) makes the execution order harder to read at a glance.

**Decision**: Standardize to two-digit prefix with letter suffix for branches:
- `00-sim.R` → keep
- `01-payment-month.R` → keep
- `2a-episode.R` → `02a-episode.R`
- `2b-caseload.R` → `02b-caseload.R`
- `3a-event.R` → `03a-event.R`
- `4a-event-count.R` → `04a-event-count.R`
- `05-caseload-event.R` → keep (already two-digit)
- `99-export.R` → keep

**Fix**: Rename files and update all references in `flow.R` and `pipeline.md`.

---

## C-08 · `spell_id` Undocumented in Universe-Guide

**Files**: `manipulation/2a-episode.R`, `analysis/sim-1/universe-guide.md` §6
**Priority**: Low

**Issue**: `ds_episode` includes a `spell_id` column that groups SPELL_BITs into SPELLs. This is a valuable analytical handle (enabling SPELL-level aggregation), but it is not mentioned in the universe-guide §6 table schema or the Appendix creation order table.

**Fix**: Add `spell_id` to the `ds_episode` schema in universe-guide §6 with a clear description of how SPELLs relate to SPELL_BITs, and which columns are additive/extremal/non-additive at the SPELL aggregation level.

---

## C-09 · EDA-1 Uses mtcars, Not Pipeline Data

**Files**: `analysis/eda-1/eda-1.R`, `analysis/eda-1/eda-1.qmd`
**Priority**: Low (next phase)

**Issue**: The EDA report uses `mtcars` as a placeholder. There is no analysis of the simulated social services data yet. The `flow.R` pipeline runs the simulation and then immediately tries to render the EDA, which will not demonstrate any pipeline output.

**Decision**: Defer to next sprint. The EDA will be redesigned once the simulation is realistic (C-01). At that point, `eda-1` should load from `timeseries.sqlite` and visualize caseload and event count timeseries.

---

## C-10 · `ds_payment` Has No `payment_id` After bind_rows

**File**: `manipulation/00-sim.R`
**Priority**: Low

**Issue**: `payment_id` is assigned via `row_number()` *after* combining demo and random persons. This means `payment_id` values are not stable across runs (they depend on insertion order). More importantly, the current code does `bind_rows(ds_demo, ds_random) %>% mutate(payment_id = row_number())`, but the `generate_person_payments()` function does not include `payment_id` in its output — so the column is added correctly. However, the demo CSV might include its own `payment_id` column which would then be overwritten. This should be made explicit.

**Fix**: Strip any incoming `payment_id` from `ds_demo` before bind, then assign fresh surrogate after combining.

---

## C-11 · Stock-Flow Identity Formulation Error

**File**: `manipulation/05-caseload-event.R`, `analysis/sim-1/universe-guide.md`
**Priority**: Critical (found during implementation of C-06)

**Issue**: The original check `implied_next_caseload(t) = active(t) + NEW(t) + RETURNED(t) - CLOSED(t)`, verified against `active(t+1)`, is not a valid accounting identity. It double-counts entries: NEW(t) and RETURNED(t) people are already in `active(t)`, so adding them again inflates the "implied next" by their count, making the check virtually always fail.

**Correct identity**:

$$\text{active}(t) = \text{active}(t-1) + \text{NEW}(t) + \text{RETURNED}(t) - \text{CLOSED}(t)$$

Verified as: `lag(active) + NEW + RETURNED - CLOSED == active` for each month and cell.

**Fix**: Changed `05-caseload-event.R` to compute `implied_caseload = active_clients - delta_caseload` and check it equals `lag(active_clients)`. The column `implied_next_caseload` is removed in favour of `implied_caseload`. Updated universe-guide §10 and CACHE-manifest accordingly.

---

## Summary Table

| ID | Description | Priority | Status |
|---|---|---|---|
| C-01 | Simulation is a placeholder — no realistic patterns | Critical | ✅ Implemented |
| C-02 | demo-persons.csv does not exist | Critical | ✅ Implemented |
| C-03 | Gap threshold inconsistency across documents | High | ✅ Implemented |
| C-04 | Column name inconsistency: role_type vs household_role | High | ✅ Implemented |
| C-05 | CLOSED event timestamp ambiguity | Medium | ✅ Implemented |
| C-06 | Stock-flow identity is a soft warning | Medium | ✅ Implemented |
| C-07 | Script numbering inconsistency | Low | ✅ Implemented |
| C-08 | spell_id undocumented in universe-guide | Low | ✅ Implemented |
| C-09 | EDA-1 uses mtcars, not pipeline data | Low | Deferred |
| C-10 | payment_id stability after bind_rows | Low | ✅ Implemented |
| C-11 | Stock-flow identity formulation error | Critical | ✅ Implemented |
