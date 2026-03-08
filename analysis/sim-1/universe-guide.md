# Universe Guide: Social Services Simulation

## Purpose

This document establishes the ontological universe for a synthetic social services dataset representing a hypothetical Canadian province. It is written as a dual-register document: each concept is introduced in plain language — how it would be understood by a program manager, a researcher, a policy analyst — and then immediately grounded in a precise data structure. The two registers are inseparable. The narrative gives meaning; the specification gives form.

The goal is a simulation that is internally consistent, analytically useful, and structurally faithful to how administrative social services data actually works — not as idealized records, but as the paper trail of a live bureaucracy.

---

## 1. Time

Social services are administered in time, and in this system, time is monthly. A **pay period** is a month — not a day, not a fiscal quarter. Every record in every table is anchored to a pay period.

**Time Spine**

| Concept | Specification |
|---|---|
| `pay_period` | Date, normalized to YYYY-MM (first of month) |
| Granularity | Monthly |
| Range | Simulation-defined; e.g., 2015-01 to 2024-12 (120 months) |
| Role | Universal index; all downstream tables join to this spine |

The time spine is implicit — it is never materialized as a standalone table — but it governs all others. A record that falls outside the defined range does not exist in this universe.

---

## 2. People

The people served by this system are individuals. They are not abstractions. They have identifiers, they live in households, and their relationship to other household members — whether they are the one who applied for support or the partner recorded on the file — shapes both their eligibility and their payments.

**Person and Household Identifiers**

| Field | Type | Description |
|---|---|---|
| `person_id` | integer | Unique surrogate key per individual |
| `household_role` | factor | `Head of Household` \| `Spouse` |

`household_role` is a payment-level attribute: it is recorded on `ds_payment` and reflects the administrative role of the person within the household at the time of the payment. It is not inferred — it is the role as recorded on the file.

---

## 3. Programs

The province administers three distinct social service programs. Each defines a fundamentally different relationship between the individual and the state: one addresses immediate economic precarity, one provides long-term support for persons with disabilities, and one protects children and families in crisis.

**Client Type Taxonomy**

| `client_type` | Program Name | Character |
|---|---|---|
| `IA` | Income Assistance | Short- to medium-term economic support |
| `DS` | Disability Support | Long-term support for persons with disabilities |
| `CFS` | Child and Family Services | Child protection and family preservation |

**Invariant**: A person has exactly one `client_type` per `pay_period`. Program assignment determines which need codes apply.

**Need Code Taxonomy**

| `client_type` | `need_code` | Description |
|---|---|---|
| `IA` | `basic_living` | Core living allowance |
| `IA` | `shelter` | Housing cost supplement |
| `IA` | `utility_supplement` | Utility cost support |
| `DS` | `enhanced_living` | Enhanced monthly living support |
| `DS` | `mobility_support` | Mobility and assistive device funding |
| `DS` | `caregiver_supplement` | Support for caregiving relationships |
| `CFS` | `family_support` | In-home family preservation services |
| `CFS` | `foster_care` | Out-of-home foster placement support |
| `CFS` | `kinship_care` | Extended family placement support |

Need codes are compositional, not mutually exclusive. A person receiving Income Assistance may receive both `basic_living` and `shelter` in the same month — generating two payment rows.

---

## 4. Payments — The Only Simulated Table

Everything in this data system flows from money. A payment is the fundamental administrative event: the province issues support to a person, for a specified purpose, in a specified month. The payment record is the atomic unit of the entire system. It is the only table that is directly simulated; every other table is derived from it.

**`ds_payment`** — *Simulated*

| Field | Type | Description |
|---|---|---|
| `payment_id` | integer | Surrogate key; no semantic content |
| `person_id` | integer | Links to person |
| `pay_period` | date | Month of payment (YYYY-MM) |
| `client_type` | factor | `IA` \| `DS` \| `CFS` |
| `household_role` | factor | `Head of Household` \| `Spouse` |
| `need_code` | factor | Program-specific payment category |
| `payment_amount` | numeric | Dollar amount of payment |

**Invariants**

- One `client_type` per `person_id` per `pay_period` (no mid-month program switches)
- Multiple rows per `person_id` × `pay_period` are allowed (multiple need codes)
- `household_role` is constant per `person_id` within a `pay_period`

---

## 5. The Month-State — Was This Person Paid This Month?

Before we can define continuity, we need to know, for each person and each month: were they in the system? A person may have received three payments in a month — basic living, shelter, and utilities — but from an episode perspective, they were simply *present*. The month-state collapses the atomic payment rows into a single administrative fact per person-month.

**`ds_payment_month`** — *Derived from `ds_payment`*

| Field | Type | Description |
|---|---|---|
| `person_id` | integer | |
| `pay_period` | date | |
| `client_type` | factor | Consistent within month (enforced by invariant) |
| `household_role` | factor | Consistent within month |
| `n_need_codes` | integer | Count of distinct need codes received |
| `total_payment` | numeric | Sum of `payment_amount` for the month |

This table is a collapse of `ds_payment` to one row per `person_id` × `pay_period`. It is the immediate source for episode construction.

---

## 6. Episodes — The Lived Continuity of Service

An episode is an uninterrupted sequence of months during which a person receives support under the same program and in the same household role. It is not a legal or administrative category — it is an analytic construct derived from payment continuity. When a person's payments stop, or when their program changes, or when their household role changes, one episode ends and potentially another begins.

**`ds_episode`** — *Derived from `ds_payment_month`*

| Field | Type | Description |
|---|---|---|
| `person_id` | integer | |
| `episode_id` | integer | Unique per person (surrogate, no cross-person meaning) |
| `episode_start` | date | First `pay_period` of episode |
| `episode_end` | date | Last `pay_period` (NA if ongoing at simulation end) |
| `client_type` | factor | Constant within episode |
| `household_role` | factor | Constant within episode |
| `episode_length_months` | integer | Derived from start and end |

**Episode Boundary Rules**

A new episode begins when any of the following occur:

1. A payment gap — at least one `pay_period` with no payment
2. `client_type` changes between consecutive months
3. `household_role` changes between consecutive months

---

## 7. Events — The Recognition of Change

Events are the language in which a caseload speaks about itself over time. They are not directly observed; they are interpretations assigned at episode boundaries. An event marks the moment a client enters, re-enters, or exits the active caseload. They are the *flow* counterpart to the stock of active cases.

**`ds_event`** — *Derived from `ds_episode`*

| Field | Type | Description |
|---|---|---|
| `person_id` | integer | |
| `event_month` | date | `pay_period` in which the event is recorded |
| `event_type` | factor | `NEW` \| `RETURNED` \| `CLOSED` |
| `client_type` | factor | |
| `household_role` | factor | |
| `episode_id` | integer | Links back to `ds_episode` |

**Event Type Definitions**

| `event_type` | Condition |
|---|---|
| `NEW` | Episode start; this person has never had a prior episode |
| `RETURNED` | Episode start; this person had at least one prior episode |
| `CLOSED` | Episode end; the person leaves the active caseload |

Each episode generates at most two events: one at its start (`NEW` or `RETURNED`) and one at its end (`CLOSED`). An ongoing episode at simulation end generates only a start event.

---

## 8. Event Counts — The Forecastable Flow

For forecasting and analysis, we need not individual events but their aggregated counts by month. These counts are the direct inputs to event-based caseload forecasting models. They transform a person-level event log into a population-level time series.

**`ds_event_count`** — *Aggregated from `ds_event`*

| Field | Type | Description |
|---|---|---|
| `event_month` | date | |
| `event_type` | factor | `NEW` \| `RETURNED` \| `CLOSED` |
| `client_type` | factor | Optional stratification |
| `household_role` | factor | Optional stratification |
| `n_events` | integer | Count of events in this cell |

This table is the interface between the micro-level administrative record and the macro-level forecast. Its rows are the forecastable series.

---

## 9. Caseload — The Living Stock

Caseload is not simulated. It is derived. This is not a technical convenience — it is an ontological commitment. Caseload is the integral of the flow: it is what you get when you accumulate entries and subtract exits. Any model that treats caseload as independently observable must eventually reconcile its caseload trajectory with the events that produced it. In this system, we enforce that reconciliation by construction.

**`ds_caseload`** — *Derived from `ds_payment_month`*

| Field | Type | Description |
|---|---|---|
| `pay_period` | date | |
| `client_type` | factor | |
| `household_role` | factor | |
| `active_clients` | integer | Count of persons with payment in this month-cell |

**Stock–Flow Identity**

$$\text{Caseload}_t = \text{Caseload}_{t-1} + \text{NEW}_t + \text{RETURNED}_t - \text{CLOSED}_t$$

This identity must hold exactly. Any discrepancy is a data quality failure, not a modeling finding.

---

## 10. The Reconciliation Table

The reconciliation table is the analytical conscience of the system. It brings together the stock (caseload) and the flow (events) in a single view, enabling verification that the identity holds and exposing the structure of any discrepancy when it does not. In forecasting contexts, it is also the natural table for comparing event-implied caseload against directly-forecast caseload.

**`ds_caseload_event`** — *Reconciliation of `ds_caseload` and `ds_event_count`*

| Field | Type | Description |
|---|---|---|
| `pay_period` | date | |
| `client_type` | factor | |
| `household_role` | factor | |
| `active_clients` | integer | From `ds_caseload` |
| `NEW` | integer | From `ds_event_count` |
| `RETURNED` | integer | From `ds_event_count` |
| `CLOSED` | integer | From `ds_event_count` |
| `delta_caseload` | integer | `NEW + RETURNED - CLOSED` |
| `implied_next_caseload` | integer | `active_clients + delta_caseload` |

When `implied_next_caseload` at time $t$ equals `active_clients` at time $t+1$, the identity holds. Divergence surfaces either a simulation inconsistency or the boundary conditions of a stratified analysis.

---

## Appendix: Data Object Creation Order

All eight data objects in the order they must be created:

| Order | Object | Type | Source | Unit of Observation |
|---|---|---|---|---|
| 0 | Time spine | Implicit | — | `pay_period` (month) |
| 1 | `ds_payment` | **Simulated** | Direct generation | payment × person × month |
| 2 | `ds_payment_month` | Derived | `ds_payment` | person × month |
| 3 | `ds_episode` | Derived | `ds_payment_month` | episode |
| 4 | `ds_event` | Derived | `ds_episode` | event |
| 5 | `ds_event_count` | Aggregated | `ds_event` | event type × month |
| 6 | `ds_caseload` | Derived | `ds_payment_month` | month × program |
| 7 | `ds_caseload_event` | Reconciliation | `ds_caseload` + `ds_event_count` | month × program |

**One table is simulated. Everything else is logic.**
