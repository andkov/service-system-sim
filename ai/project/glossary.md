# Glossary

Core terms for standardizing project communication.

---

## Foundational Concepts

- **pay period** - A period of time during which a client receives financial support. This is how LISA CCD system captures caseload data, typically at the level of months.

- **episode or service** - A distinct period of recieving funancial support, a SPELL or SPELL_BIT. We reserve the term "episode of service" to refer to periods of receiving financial support. Training and assessment are considered points in time and refered to as "events".

- **client type** - A classification of financial support a client received that month. In any given month of receiving financial support, a client can be assigned one and only one client type. Unqique code is recorded in the `client_type_code` field.

- **need code** - A specific 

- [Income Support Policy Manual](https://manuals.alberta.ca/income-and-employment-supports-policy-manual/) should be consulted for definitive current version.


### Client Type Code Taxonomy

```
Financial Support (pc0 = FS)
│
├── Income Support (pc1 = IS)
│   │
│   ├── Expected to Work (pc2 = ETW)
│   │   ├── 11: Self-Employed (ETW)
│   │   ├── 12: Employed Full-Time (ETW)
│   │   ├── 13: Employed Part-Time (ETW)
│   │   ├── 14: Available for Work/Training
│   │   ├── 15: Attending a Program (ETW)
│   │   ├── 17: Temp Unable to Work/Train - Health Problem
│   │   ├── 18: Temp Unable to Work/Train - Family Care
│   │   ├── 21: Available for work or training - receiving or awaiting EI benefits      †
│   │   ├── 22: Available for work or training - minimal interventions required         †
│   │   ├── 23: Available for work or training - moderate interventions required        †
│   │   ├── 24: Available for work or training - long term interventions required       †
│   │   ├── 25: Attending employment preparation of 2-12 months                        †
│   │   ├── 26: Awaiting full-time funding from Student Finance (SF)                   †
│   │   ├── 31: Unavailable for work/training - temporary disability/health problems   †
│   │   ├── 32: Unavailable for work/training - family care responsibilities            †
│   │   └── 33: Unlikely to access full-time employment - singles over 50              †
│   │
│   └── Barriers to Full Employment (pc2 = BFE)
│       ├── 42: Medical or Multiple Barriers
│       ├── 43: Severe Handicap
│       ├── 44: Self-Employed (BFE)
│       ├── 45: Employed Full-Time (BFE)
│       ├── 46: Employed Part-Time (BFE)
│       └── 47: Attending a Program (BFE)
│    
├── One Time Issues (pc1 = OTI)
│       ├── 81: Transient
│       └── 82: Resident
│
├── Assured Income for Severely Handicapped (pc1 = AISH)
│       ├── 91: Straight AISH - independent living
│       ├── 92: Modified AISH - living in a facility (Schedule 3 of AISH Regulations)
│       └── 93: AISH Client living in Government Owned and Operated Community Residence
│
└── Disability-Related Employment Supports (pc1 = DRES)
```

† Atavistic codes (21–33): present in historical data, rarely used today.

Consult [policy manual](https://manuals.alberta.ca/income-and-employment-supports-policy-manual/income-support-program/etw-and-bfe-policy-procedures/02-client-categories-types/general-policy/) for the definitive current version of the client type ontology.

## Episode Types

In this approach, we organize the history of relationships between people and service programs into *episodes of service*. This helps us think about and to organize data in terms of client timelines. 

Services can be of three broad types: financial assistance (FS), training (TR), and assessment (AS). 

### Episode Types

 We operationalize two types of  episodes of financial support:

  -**SPELL** – A non-interrupted period of financial support, separated from other SPELLs by two or more consecutive months of non-use of any financial support. Clients may change services during this time (i.e. change their client_type_code) or change their status in the household, but the SPELL remains continuous as long as there is no gap of two or more months in service use.  
  -**SPELL_BIT** – A non-interrupted period of financial support (i.e. service use of financial support program), separated from other SPELL_BITs by two or more consecutive months of non-use **OR** by a change in client type or household role. In other words, a change in client type or household role terminates the SPELL_BIT and triggers a new SPELL_BIT, even if there is no gap in service use.

SPELL_BITs make up SPELLs. In many cases, a SPELL consists of a single SPELL_BIT.  

Episodes of Financial Support have certain unique features:
  -The smallest unit of time one month
  -A FS episode begins on the first day of the month and ends on the last day of the month (as opposed  to training (TR) an assessment (AS) events which can take place any day of the month).
  -Client can receive only one type of support (`client_type_code`) at any given month.
  -Encoded as an integer in the field (`client_type_code`)
  -Mapped to a more coarse category in the program class taxonomy (`program_class0123`)
  -Benefits table of RDB (TC2_IS_BENEFITS)  captures data at the level of individual payments, while episodes of FS are constructed at the level of pay periods (months).

## Big Picture of Data Universe

We study the history of relationship between people and service programs. Their interaction is stored as data tables of the Research Data Base (RDB). Locally available at `data-private/derived/RDB.sqlite`, RDB tables organize engagements with selected programs of financial support.

### ROW = PAYMENT

The table of **BENEFITS** contains one record per payment a client received.  Only one type of assistance (client_type_code) can be received in a month, but a set of benefits (`NEED_CODE`) and amount for each payment may vary by persons and pay periods.

This is the fundamental data structure, all other data table about financial support will be derived from the table of BENEFITS. 

### ROW = EPISODE

The table of **SPELLS** tracks contiguous intervals of assistance. A spell is defined as uninterrupted (2 months+ ) reception of benefits of any kind. Client type, their role in the household, and benefit amount recieved each month may vary within a spell.

The table of **SPELL_BITS** breaks down spells into segments characterized by stable client type and household role (`CLIENT_TYPE_CODE`, `ROLE_TYPE`). The the gap of more than 1 month, or a change in either client type or household role marks the start of a new spell bit.

Financial assistance can come in four forms:

- **AISH** - Assured Income for the Severely Handicapped
- **IS** - Income Support (BFE or ETW)
    - **ETW** - Expected to Work (subtype of IS)
    - **BFE** - Barriers to Full Employment (subtype of IS)
- **OTI** - One Time Issues
- **DRES** - Disability-Related Employment Supports

### Additional tables (not included)

In addition to financial assistance, clients may recieve  a wide range of training programs and employment services to improve their attachement to the labour market. Records of clients' interaction with these services are to be captured in **ES_SERVICES** table.

To better guide clients through the space of programs and services, they are evaluated with assessment intsruments, capturing results in  **EA_EVENTS** table. 


## Data Pipeline Terminology

### Pattern
A reusable solution template for common data pipeline tasks. Patterns define the structure, philosophy, and constraints for a category of operations. Examples: Ferry Pattern, Ellis Pattern.

### Lane
A specific implementation instance of a pattern within a project. Lanes are numbered to indicate approximate execution order. Examples: `0-ferry-IS.R`, `1-ellis-customer.R`, `3-ferry-LMTA.R`.

### Ferry Pattern
Data transport pattern that moves data between storage locations with minimal/zero semantic transformation. Like a "cargo ship" - carries data intact. 
- **Allowed**: SQL filtering, SQL aggregation, column selection
- **Forbidden**: Column renaming, factor recoding, business logic
- **Input**: External databases, APIs, flat files
- **Output**: CACHE database (staging schema), parquet backup

### Ellis Pattern
Data transformation pattern that creates clean, analysis-ready datasets. Named after Ellis Island - the immigration processing center where arrivals are inspected, documented, and standardized before entry.
- **Required**: Name standardization, factor recoding, data type verification, missing data handling, derived variables
- **Includes**: Minimal EDA for validation (not extensive exploration)
- **Input**: CACHE staging (ferry output), flat files, parquet
- **Output**: CACHE database (project schema), WAREHOUSE archive, parquet files
- **Documentation**: Generates CACHE-manifest.md

---

## Storage Layers

### CACHE
Intermediate database storage - the last stop before analysis. Contains multiple schemas:
- **Staging schema** (`{project}_staging` or `_TEST`): Ferry deposits raw data here
- **Project schema** (`P{YYYYMMDD}`): Ellis writes analysis-ready data here
- Both Ferry and Ellis write to CACHE, but to different schemas with different purposes.

### WAREHOUSE
Long-term archival database storage. Only Ellis writes here after data pipelines are stabilized and verified. Used for reproducibility and historical preservation.

---

## Schema Naming Conventions

### `_TEST`
Reserved for pattern demonstrations and ad-hoc testing. Not for production project data.

### `P{YYYYMMDD}`
Project schema naming convention. Date represents project launch or data snapshot date.
Example: `P20250120` for a project launched January 20, 2025.

### `P{YYYYMMDD}_staging`
Optional staging schema within a project namespace for Ferry outputs before Ellis processing.

---

## General Terms

### Artifact
Any generated output (report, model, dataset) subject to version control.

### Seed
Fixed value used to initialize pseudo-random processes for reproducibility.

### Persona
A role-specific instruction set shaping AI assistant behavior.

### Memory Entry
A logged observation or decision stored in project memory files.

### CACHE-manifest
Documentation file (`./data-public/metadata/CACHE-manifest.md`) describing analysis-ready datasets produced by Ellis pattern. Includes data structure, transformations applied, factor taxonomies, and usage notes.

### INPUT-manifest
Documentation file (`./data-public/metadata/INPUT-manifest.md`) describing raw input data before Ferry/Ellis processing.

---
*Expand with domain-specific terminology as project evolves.*