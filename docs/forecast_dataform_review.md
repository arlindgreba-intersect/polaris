# Forecast Dataform Pipeline Review

**Date:** 2026-06-24
**Reviewer:** Arlind Greba
**Dataform repo:** `sandbox-lakehouse/us-south1/polaris-forecast-pipeline`
**Workspace:** `polaris-forecast-pipeline`
**Repo HEAD reviewed:** `04a53b8` (`FMA-107: add basic LCOE pipeline health check`)

## TL;DR

Alexa built a complete **parallel forecast-driven LCOE pipeline** in a new
`fcst_finance` dataset. Nine `.sqlx` files in total:

- **Three** are renamed/refactored versions of the views I built on 2026-06-22
  (now incremental tables, sourcing from raw directly, not from my staging
  table). Repo SQL is out of sync.
- **Six new files** (`fcst_01` through `fcst_06`) recompute capex, opex,
  ITC, depreciation, generation, and LCOE on a forecast-capex basis. These
  do not exist in the repo at all.

Every `fcst_finance.*` table carries **two run_ids** — `forecast_run_id` (from
the forecast workbook push) and `lcoe_run_id` (from the latest current_forecast
canonical LCOE run). Opex and generation are copied forward from the canonical
LCOE run unchanged; only capex, ITC, and depreciation are recomputed on the
forecast basis.

## 1. Inventory of Forecast Dataform Definitions

| # | File | Type | Target | Description |
|---|---|---|---|---|
| 1 | `fcst_01_capex_monthly.sqlx` | incremental, partition+cluster | `fcst_finance.fcst_capex_monthly` | Monthly forecast capex by tech × major_category. Sources `stg_finance.v6_forecast_lcoe_capex_inputs`. One row per `(forecast_run_id, technology, major_category, forecast_date)`. |
| 2 | `fcst_02_opex_summary.sqlx` | incremental, clustered | `fcst_finance.fcst_opex_summary` | Lifetime opex totals per tech from the **canonical** LCOE run (not recomputed from forecast). Tagged with `forecast_run_id` so all fcst_finance tables share one Looker join key. |
| 3 | `fcst_03_tax_credit_summary.sqlx` | incremental, clustered | `fcst_finance.fcst_tax_credit_summary` | ITC + MACRS basis recomputed on **forecast** capex (excluding pre-COD opex via `is_pre_cod_opex` flag). Eligibility rates pulled from canonical `v6_silver_itc_inputs`. |
| 4 | `fcst_04_depreciation_summary.sqlx` | incremental, clustered, depends on `fcst_tax_credit_summary` | `fcst_finance.fcst_depreciation_summary` | Annual MACRS shield using `polaris_raw.v6_ref_macrs_schedule`. Year-21 half-year convention handled. |
| 5 | `fcst_05_generation_monthly.sqlx` | incremental, partition+cluster | `fcst_finance.fcst_generation_monthly` | Monthly generation copied from canonical `fct_finance.generation_monthly`, tagged with `forecast_run_id`. |
| 6 | `fcst_06_lcoe_summary.sqlx` | incremental, clustered, depends on tax/dep/opex/gen | `fcst_finance.fcst_lcoe_summary` | Final LCOE per tech + Facility roll-up using forecast capex/ITC/dep and canonical opex/generation. Mirrors `lcoe_component_annual` methodology. |
| 7 | `v6_forecast_by_cost_code.sqlx` | incremental, partition+cluster | `stg_finance.v6_forecast_by_cost_code` | Same shape as my 2026-06-22 view, but now an incremental table sourcing **directly from `polaris_raw.v6_raw_forecast_inputs`** via UNPIVOT. |
| 8 | `v6_forecast_pmt_rollup.sqlx` | incremental, partition+cluster | `stg_finance.v6_forecast_pmt_rollup` | Same target name as mine, but **5 buckets** instead of 16. |
| 9 | `v6_forecast_lcoe_capex_inputs.sqlx` | incremental, partition+cluster | `stg_finance.v6_forecast_lcoe_capex_inputs` | Same 6 major_category buckets I designed. |

## 2. Key Architectural Choices

### 2.1 New dataset: `fcst_finance`

Separate from `fct_finance`. Pattern: forecast outputs never overwrite canonical
LCOE outputs; they live in their own dataset and Looker can choose which to
read.

### 2.2 Dual run_id tracking

Every `fcst_finance.*` table carries:
- `forecast_run_id` — from the forecast workbook push
- `lcoe_run_id` — picked as the latest `current_forecast` `run_id` from
  `stg_finance.v6_stg_project_timeline` at the moment the forecast pipeline runs

This neatly addresses the "two run_ids" gap I flagged on FMA-127.

### 2.3 What gets recomputed vs copied

| Component | Recomputed on forecast basis | Copied from canonical run |
|---|---|---|
| Capex | ✓ | |
| ITC / MACRS basis | ✓ | |
| Depreciation shield | ✓ | |
| Opex (all components) | | ✓ |
| Generation | | ✓ |

This is consistent with the forecast-tool design: capex changes drive new
ITC/dep, but opex and generation are still anchored to the canonical model.

### 2.4 Incremental dedup pattern

Every file uses the standard Dataform pattern:
```
${when(incremental(), `AND run_id NOT IN (SELECT DISTINCT forecast_run_id FROM ${self()})`)}
```
Same shape as the LCOE pipeline incremental files I reviewed yesterday.

### 2.5 Source change for the three "view" objects

| Object | Before (my version, 2026-06-22) | After (Alexa's Dataform, 2026-06-23+) |
|---|---|---|
| `v6_forecast_by_cost_code` | VIEW selecting from `stg_finance.v6_stg_forecast_inputs` (long format) | incremental TABLE, UNPIVOT directly from `polaris_raw.v6_raw_forecast_inputs` |
| `v6_forecast_pmt_rollup` | VIEW from staging long, 16 prefix buckets | incremental TABLE, UNPIVOT from raw, **5** milestone buckets |
| `v6_forecast_lcoe_capex_inputs` | VIEW from staging long, 6 major_category buckets | incremental TABLE, UNPIVOT from raw, same 6 buckets |

Practical effect: `stg_finance.v6_stg_forecast_inputs` (the long-format staging
table I built) **is no longer referenced** by any of the three aggregation
objects. It's now an orphaned table.

## 3. Bucket Definition Differences

### `v6_forecast_pmt_rollup` — significant semantic shift

| acct_prefix | My version (repo) | Alexa's version (Dataform) |
|---|---|---|
| 1 | Land & Title | Soft Costs & Development |
| 2 | Legal | Soft Costs & Development |
| 3 | Permitting & Environmental | Soft Costs & Development |
| 4 | Interconnection | Soft Costs & Development |
| 5 | Deposits & Marketing | Soft Costs & Development |
| 6 | Finance & Credit | Soft Costs & Development |
| 7 | EPC - Other | Construction Progress |
| 9 | DSA & G&A | Soft Costs & Development |
| 10 | Engineering | Engineering & Design |
| 11 | Equipment | Equipment Procurement |
| 13 | Construction | Construction Progress |
| 14 | Operations | Pre-COD Operational Opex |
| 15 | Solar EPC | Equipment Procurement |
| 16 | BESS EPC | Equipment Procurement |
| 18 | Wind EPC | Equipment Procurement |
| 22 | Gas EPC | Equipment Procurement |

Alexa's version collapses what I had as 16 buckets into 5. **For any downstream
analysis comparing the two, the bucket dimension is not directly compatible.**

### `v6_forecast_lcoe_capex_inputs` — identical buckets

Same 6 major_categories (Development, Engineering, Equipment & Procurement,
Construction, Soft Costs - Finance, Pre-COD Opex). `is_pre_cod_opex` flag
preserved.

### `v6_forecast_by_cost_code` — same shape

`(run_id, technology, acct_code, forecast_date) → monthly_spend_usd + source_line_count`.
Identical contract.

## 4. ⚠ Truncated UNPIVOT range — likely bug or deliberate scope cut

All three `v6_forecast_*` UNPIVOT blocks in Dataform only list these period
columns:

```
period_2028_04_30 → period_2031_06_30   (39 months)
```

But the raw table `polaris_raw.v6_raw_forecast_inputs` has **130 period
columns** spanning `period_2020_09_30 → period_2031_06_30`. Anything before
April 2028 — including historicals, dev period, and early construction spend —
is **silently dropped** by these views.

| | Raw scope | Dataform UNPIVOT scope | Coverage |
|---|---|---|---|
| Start | 2020-09-30 | 2028-04-30 | first 91 months dropped |
| End | 2031-06-30 | 2031-06-30 | matches |
| Total months | 130 | 39 | 30% |

**Verdict to confirm with Alexa:** is this a deliberate scope cut to the
construction window only, or an unfinished UNPIVOT column list? Either way it
deviates from the "complete capex picture" definition we discussed for the
LCOE Capex tool inputs.

## 5. Repo vs Dataform Gap Analysis

| Object | Repo state | Dataform state | Diff |
|---|---|---|---|
| `sql/staging/v6_stg_forecast_inputs.sql` | INSERT INTO incremental append to `stg_finance.v6_stg_forecast_inputs` | Not referenced by any Dataform file | ORPHANED — Dataform sources directly from raw. Staging is dead code unless we want to keep a long-format reference table. |
| `sql/views/v6_forecast_by_cost_code.sql` | `CREATE OR REPLACE VIEW` from staging long | `incremental` TABLE, UNPIVOT from raw | Repo is stale. Truncated UNPIVOT range issue (see §4). |
| `sql/views/v6_forecast_pmt_rollup.sql` | VIEW, 16 acct_prefix buckets | incremental TABLE, **5** milestone buckets | Repo is stale AND semantically different. Pick a canonical bucket definition. |
| `sql/views/v6_forecast_lcoe_capex_inputs.sql` | VIEW, 6 major_categories | incremental TABLE, same 6 major_categories | Repo is stale but logic matches. |
| `sql/staging/forecast_fct_mapping_notes.md` | Mapping discussion doc | n/a | Some discussion items are now answered by Alexa's fcst_finance pipeline. Worth a refresh pass. |
| (no repo file) | — | `fcst_01_capex_monthly.sqlx` | Missing from repo |
| (no repo file) | — | `fcst_02_opex_summary.sqlx` | Missing from repo |
| (no repo file) | — | `fcst_03_tax_credit_summary.sqlx` | Missing from repo |
| (no repo file) | — | `fcst_04_depreciation_summary.sqlx` | Missing from repo |
| (no repo file) | — | `fcst_05_generation_monthly.sqlx` | Missing from repo |
| (no repo file) | — | `fcst_06_lcoe_summary.sqlx` | Missing from repo |

## 6. Recommended Next Steps

1. **Catch repo up to Dataform.** Add the 9 Dataform `.sqlx` files (or
   the relevant CREATE TABLE DDL with the same logic) to `sql/dataform/` so
   the repo is the source of truth for what runs in BQ. FMA-126 covers this.
2. **Confirm the truncated UNPIVOT range with Alexa.** If it's a deliberate
   construction-window cut, document it in the data dictionary; if it's a bug,
   extend the column list to all 130 months.
3. **Decide canonical PMT bucket definition.** Alexa's 5-bucket version is
   more abstract; mine is more granular. Both can coexist as separate columns
   if useful for Looker drill-downs.
4. **Decide fate of `stg_finance.v6_stg_forecast_inputs`.** It's an orphaned
   table not referenced by anything. Either retire it or document its role as
   a long-format reference.
5. **Investigate joining `fct_finance` and `fcst_finance` outputs in Looker**
   to compare canonical vs forecast LCOE side-by-side. Alexa's design already
   supports this via `lcoe_run_id` on every `fcst_finance.*` table.

## 7. Open Items Already Tracked in Jira

- **FMA-118** — Dataform pipeline migration (parent ticket for this work)
- **FMA-126** — Repo SQL out of sync with BQ (this review confirms scope; ready
  to start once we pick a sync strategy)
- **FMA-127** — Staging vs raw routing for forecast (this review shows Alexa
  has already chosen: raw → views directly, staging is orphaned)
