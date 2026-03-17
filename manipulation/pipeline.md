# Pipeline Execution Guide

**Purpose**: Authoritative technical reference for the data pipeline that simulates social services payment data and derives analysis-ready tables for caseload forecasting and exploration.

**Last Updated**: 2026-03-17

---

## Overview

This document describes the pipeline architecture, data flow, and execution logic for the `service-system-sim` project. The pipeline:

1. **Simulates** a single atomic table (`ds_payment`) representing payments to social services clients
2. **Derives** six additional tables through a directed acyclic graph (DAG) of transformations
3. **Exports** analysis-ready time series for consumption by downstream forecasting repositories (e.g., `caseload-forecast-demo`)

All derived tables are logic — they follow deterministically from the simulated payment data. Nothing is independently generated after the simulation step.

Scripts are organised into two categories:

1. **Non-Flow Scripts**: Examples and ad-hoc operations (`./manipulation/examples/`)
2. **Flow Scripts**: Reproducible pipeline steps orchestrated by `./flow.R`

---

## Pipeline Architecture

### DAG (Directed Acyclic Graph)

```
00-sim.R ──► ds_payment
                │
01-payment-month.R ──► ds_payment_month
                │
        ┌───────┴───────┐
        ▼               ▼
02a-episode.R      02b-caseload.R
  ds_episode        ds_caseload
        │                   │
        ▼                   │
03a-event.R                  │
  ds_event                  │
        │                   │
        ▼                   │
04a-event-count.R            │
  ds_event_count            │
        │                   │
        └───────┬───────────┘
                ▼
    05-caseload-event.R
      ds_caseload_event
                │
                ▼
        99-export.R
```

### Pipeline Stages

| # | Script | Pattern | Key Output | Depends On |
|:--|:-------|:--------|:-----------|:-----------|
| 0 | [**00-sim.R**](#lane-0--00-simr) | Sim | `payment.sqlite::ds_payment` | — |
| 1 | [**01-payment-month.R**](#lane-1--01-payment-monthr) | Derive | `payment.sqlite::ds_payment_month` | 0 |
| 2a | [**02a-episode.R**](#lane-2a--2a-episoder) | Derive | `episode.sqlite::ds_episode` | 1 |
| 2b | [**02b-caseload.R**](#lane-2b--2b-caseloadr) | Derive | `timeseries.sqlite::ds_caseload` | 1 |
| 3a | [**03a-event.R**](#lane-3a--3a-eventr) | Derive | `episode.sqlite::ds_event` | 2a |
| 4a | [**04a-event-count.R**](#lane-4a--4a-event-countr) | Derive | `timeseries.sqlite::ds_event_count` | 3a |
| 5 | [**05-caseload-event.R**](#lane-5--05-caseload-eventr) | Reconcile | `timeseries.sqlite::ds_caseload_event` | 2b + 4a |
| 99 | [**99-export.R**](#lane-99--99-exportr) | Export | `./data-private/derived/export/` | All |

### Branch Structure

The pipeline has two branches from `ds_payment_month`:

- **Branch A** (episode path): `01 → 2a → 3a → 4a` — Constructs episodes, classifies events, aggregates event counts
- **Branch B** (caseload path): `01 → 2b` — Counts active clients per month

Both branches merge at step 5 (`05-caseload-event.R`), which reconciles the stock (caseload) with the flow (events) and validates the stock-flow identity.

---

## Database Architecture

Three SQLite databases, grouped by analytical grain:

| Database | Location | Grain | Tables |
|---|---|---|---|
| `payment.sqlite` | `./data-private/derived/pipeline/` | Person × month (atomic) | `ds_payment`, `ds_payment_month` |
| `episode.sqlite` | `./data-private/derived/pipeline/` | Person × episode/event | `ds_episode`, `ds_event` |
| `timeseries.sqlite` | `./data-private/derived/pipeline/` | Month × program (aggregate) | `ds_event_count`, `ds_caseload`, `ds_caseload_event` |

**Rationale**: Grouping by grain makes it easier for analysts to reason about which database to open. Payment-grain tables live together; episode-grain tables live together; aggregate time series live together.

---

## Execution

### To Execute This Pipeline: Run `./flow.R`

```r
source("./flow.R")
```

Or from terminal:

```bash
Rscript flow.R
```

### Individual Script Execution

Each script can be run independently (useful for development/debugging):

```bash
Rscript manipulation/00-sim.R
Rscript manipulation/01-payment-month.R
Rscript manipulation/02a-episode.R
# ... etc.
```

**Dependency**: Running a script requires its upstream dependencies to have been executed first.

---

## Patterns

### Sim Pattern (`00-sim.R`)

The simulation pattern is unique to this project. Unlike a Ferry pattern (which transports data from external sources), the Sim pattern **generates** data. It serves the same structural role — producing the raw input for all downstream transformations — but its internal logic is generative, not extractive.

**Canonical demo persons**: Real test cases extracted from the actual RDB (negative `person_oid` records), stored as rectangular R data objects (RDS or CSV in `./data-public/raw/fictional/`). The simulation script loads and seeds these real records into the simulated dataset, then generates additional random persons parametrically.

### Derive Pattern (`01`, `2a`, `2b`, `3a`, `4a`)

Each derive script takes one or more upstream tables, applies a documented transformation, and produces exactly one output table. The transformation logic is the script's reason for existing. Every derive script:

- Reads from a SQLite database
- Applies exactly one transformation step
- Writes to a SQLite database
- Demonstrates the transformation on canonical demo persons (before/after)

### Reconcile Pattern (`05-caseload-event.R`)

Joins stock and flow tables, computes the stock-flow identity, and **asserts** that it holds exactly. Any violation is a data quality failure, not a modeling finding.

### Export Pattern (`99-export.R`)

Bundles analysis-ready tables into portable formats (parquet + CSV) for consumption by downstream repositories. Produces an `export_manifest.yml` documenting what was exported, when, and with what hash.

---

## Demonstration Persons

Each pipeline script includes a demonstration section showing how data looks for canonical test cases **before** and **after** transformation. This serves two purposes:

1. **Comprehension**: Readers can follow one person's journey through the entire pipeline
2. **Validation**: Edge cases are exercised and visually inspected at every stage

### Demo Person Registry

Canonical demo persons have `person_id < 0` (negative IDs). They are sourced from real administrative patterns found in the actual RDB test data and stored as rectangular data objects in `./data-public/raw/fictional/`.

| person_id | Archetype | Demonstrates |
|---|---|---|
| -1 | Stable ETW career | Baseline: long uninterrupted service, single client_type |
| -2 | ETW → BFE transition | SPELL_BIT boundary triggered by client_type change |
| -3 | Multi-spell re-entry | Multiple gaps, RETURNED events, spell grouping |
| -4 | Single short spell | Minimal case: one episode, one event pair (NEW + CLOSED) |
| -5 | HH → SP role change | SPELL_BIT boundary triggered by household_role change |
| -6 | Complex history | Multiple transitions + gaps + role changes (stress test) |

Additional interesting cases may be discovered post-hoc from the randomly generated population.

---

## Episode Operationalization

**This section discloses the analytical choices embedded in `02a-episode.R`.**

### Default: SPELL_BIT

The pipeline's `ds_episode` table operates at the **SPELL_BIT** grain:

- **SPELL_BIT** = a non-interrupted period of financial support, terminated by:
  - A gap of **2 or more consecutive months** without any payment, OR
  - A change in `client_type` (e.g., ETW → BFE), OR
  - A change in `household_role` (e.g., HH → SP)

### Grouping to SPELL

Each SPELL_BIT carries a `spell_id` column that groups SPELL_BITs into SPELLs. A **SPELL** is terminated only by a gap of 2+ months — changes in `client_type` or `household_role` do NOT terminate a SPELL (they only terminate a SPELL_BIT within the SPELL).

### Column Aggregation Properties

When aggregating from SPELL_BIT to SPELL, columns have different properties:

| Column | Aggregation to SPELL | Property |
|---|---|---|
| `total_payment` | SUM across SPELL_BITs | **Additive** ✅ |
| `n_months` | SUM across SPELL_BITs | **Additive** ✅ |
| `n_need_codes_total` | SUM across SPELL_BITs | **Additive** ✅ |
| `episode_start` | MIN across SPELL_BITs | **Extremal** |
| `episode_end` | MAX across SPELL_BITs | **Extremal** |
| `episode_length_months` | Recompute from SPELL start/end | **Non-additive** ⚠️ |
| `client_type` | Not constant — varies across SPELL_BITs | **Not aggregatable** ❌ |
| `household_role` | Not constant — varies across SPELL_BITs | **Not aggregatable** ❌ |

**Warning**: Naively summing `episode_length_months` across SPELL_BITs does NOT yield the SPELL length when there are transitions without gaps. The SPELL length must be recomputed from `MIN(episode_start)` to `MAX(episode_end)`.

---

## Stock-Flow Identity

The reconciliation table (`ds_caseload_event`, produced by `05-caseload-event.R`) enforces:

$$\text{Caseload}_t = \text{Caseload}_{t-1} + \text{NEW}_t + \text{RETURNED}_t - \text{CLOSED}_t$$

This identity must hold exactly for every `pay_period × client_type × household_role` cell. Any discrepancy is a pipeline bug.

---

## Script Internal Template

All pipeline scripts follow a consistent internal structure:

```r
#' ---
#' title: "Lane X: [Purpose]"
#' ---
#' ============================================================================
#' [PATTERN]: [One-line philosophy]
#' ============================================================================
#' **Purpose**: [Clear objective]
#' **Input**: [Explicit source tables and databases]
#' **Output**: [Explicit target tables and databases]
#' ============================================================================

# ---- setup
# ---- load-packages
# ---- load-sources
# ---- declare-globals
# ---- declare-functions

# ==============================================================================
# SECTION 1: LOAD DATA
# ==============================================================================
# ---- load-data
# ---- demo-before (show canonical person BEFORE transformation)

# ==============================================================================
# SECTION 2: TRANSFORM
# ==============================================================================
# ---- transform (core logic)

# ==============================================================================
# SECTION 3: VALIDATE
# ==============================================================================
# ---- validate (assertions, row counts, invariant checks)

# ==============================================================================
# SECTION 4: DEMONSTRATE
# ==============================================================================
# ---- demo-after (show canonical person AFTER transformation)

# ==============================================================================
# SECTION 5: SAVE
# ==============================================================================
# ---- save-to-db (write to SQLite)

# ---- session-info (duration, artifact summary)
```

---

## Downstream Consumers

This pipeline produces data for:

1. **Forecasting repositories** (e.g., `caseload-forecast-demo`): consume `ds_event_count`, `ds_caseload`, `ds_caseload_event` via `99-export.R` outputs or direct DB access
2. **Analysis scripts** in this repository (`./analysis/`): consume any table from any of the three databases for EDA and exploration
3. **Reports** in this repository: consume analysis-ready tables for documentation and visualization

---

## Canonical Reference

- **Table specifications**: [`./analysis/sim-1/universe-guide.md`](../analysis/sim-1/universe-guide.md)
- **Project glossary**: [`./ai/project/glossary.md`](../ai/project/glossary.md)
- **Ferry/Ellis philosophy**: [`./manipulation/README.md`](README.md)
