# Forecast → fct Mapping Notes

**Status:** Draft — pending Alexa review before any fct table modifications
**Source:** `sandbox-lakehouse.stg_finance.v6_stg_forecast_inputs`
**Reference run:** `run-20260618-175421-TEST_5-ad0b1844`
**Validated against:** `Downloads/Copy of Forecast_Tool_Roman_III_Version 1 (3).xlsx`

This document records my best assessment of how forecast-tool line items should flow into the existing LCOE fct layer. **No fct tables have been modified.** Mapping decisions need Alexa's confirmation, especially for ambiguous capex/opex split cases.

---

## 1. Existing fct schemas (for reference)

### `fct_finance.project_capex_monthly`
| column | type |
|---|---|
| calendar_month_end | DATE |
| technology | STRING |
| monthly_capex_usd | FLOAT64 |
| component_count | INT64 |
| run_id, pushed_at, run_label, created_at, run_type | metadata |

**Granularity:** one row per (technology, calendar_month_end). Spend is fully aggregated — no acct_code / line-item detail preserved.

### `fct_finance.project_opex_monthly`
| column | type | notes |
|---|---|---|
| calendar_month_end | DATE | |
| technology | STRING | |
| operating_year_num, operating_month_num | INT64 | post-COD operating clock |
| land_lease_monthly_usd | FLOAT64 | sourced from Opex_Tool, not forecast |
| insurance_monthly_usd | FLOAT64 | sourced from Opex_Tool — see ambiguity below |
| property_tax_monthly_usd | FLOAT64 | sourced from Opex_Tool, not forecast |
| other_expenses_monthly_usd | FLOAT64 | Opex_Tool |
| gas_fuel_monthly_usd | FLOAT64 | Opex_Tool |
| dtc_hv_monthly_usd | FLOAT64 | Opex_Tool |
| lcs_monthly_usd | FLOAT64 | Opex_Tool |
| om_monthly_usd | FLOAT64 | from v6_stg_om_schedules — **likely forecast contribution lands here** |
| wake_losses_monthly_usd | FLOAT64 | Opex_Tool |
| sleeve_fee_monthly_usd | FLOAT64 | Opex_Tool / OI-005 |
| franchise_tax_monthly_usd | FLOAT64 | Opex_Tool / OI-005 |
| total_opex_monthly_usd | FLOAT64 | derived sum |
| has_missing_om_inputs | BOOL | |
| timeline_run_id, timeline_pushed_at | metadata | |

**Granularity:** one row per (technology, calendar_month_end). Component-level breakout already exists.

---

## 2. Classification by `acct_code` prefix

| acct_code prefix | Description | Assessment | Notes |
|---|---|---|---|
| 1.xx | Land / Title | **CAPEX** | Pre-COD development cost |
| 2.xx | Legal | **CAPEX** | Pre-COD development cost |
| 3.xx | Permitting / Environmental | **CAPEX** | Pre-COD development cost |
| 4.xx | Interconnection (consultants, fees, deposits) | **CAPEX** | Pre-COD development cost |
| 5.xx | Origination / Deposits / Marketing | **CAPEX** | Pre-COD development cost. Deposits (5.40 Module, 5.43 Turbine, 5.48 Breaker, 5.49 GSU) are capitalizable equipment progress payments. |
| 6.xx | Finance — Credit, Loan Interest, Transaction Costs | **AMBIGUOUS — likely CAPEX during construction** | Construction-period financing typically capitalized into capex; need to confirm whether 6.21/6.22/6.23/6.25/6.51/6.55 are construction-period only or extend into operations. |
| 7.xx | Engineering / EPC — Other | **CAPEX** | EPC scope |
| 9.10 | Capitalized Development Services Fee | **CAPEX** | Name explicitly says capitalized |
| 9.99 | GA / Allocated Costs | **AMBIGUOUS** | Convention-dependent. Most projects capitalize pre-COD G&A as part of dev costs. |
| 10.xx | Engineering | **CAPEX** | EPC / design scope |
| 11.xx | Equipment — Batteries, Transformers, Turbines, HV Breakers, Modules | **CAPEX** | Hard assets |
| 13.10 | Construction Support | **CAPEX** | Construction-period |
| 13.20 | Insurance — Project Level Insurance | **AMBIGUOUS** | Construction-period coverage = capex; operating-period coverage = opex. Forecast file does not distinguish — need Alexa input on the convention. |
| 13.30 | Legal — Construction | **CAPEX** | |
| 13.40 | Construction Consultants (Non-Legal) | **CAPEX** | |
| 13.50 | Owner Construction | **CAPEX** | Note: two variants in source data — "Owner Construction" (n=5) and "Owner construction" (n=4) for Solar. Case-difference needs normalization downstream. |
| 13.90 | Other Construction (Non-EPC) | **CAPEX** | |
| 14.xx | O&M, Spare Parts, Telecom, Distribution Energy, NERC | **OPEX** | Operating-period O&M. Maps to `om_monthly_usd` in fct_opex. **Exception:** 14.00 "O&M Fee (Construction)" name suggests capex — see ambiguities. |
| 15.xx | PV Procurement, PV Transmission, PV High Voltage | **CAPEX** | |
| 16.xx | EPC: BESS LNTP, BESS Contingency | **CAPEX** | |
| 18.xx | Wind Procurement, Wind High Voltage | **CAPEX** | |
| 22.xx | EPC: Gas BOS, Generator, Emissions Controls, Commissioning Fees | **CAPEX** | Initial spare parts often capitalized with equipment |

---

## 3. Ambiguous acct_codes (need Alexa confirmation)

| acct_code | budget_item example | Why ambiguous | Default assumption |
|---|---|---|---|
| 6.20 | Allocated Credit Facility Costs | Construction or operations? | CAPEX (treat as construction-period unless told otherwise) |
| 6.21 | Corp Loan Interest | Construction period only or ongoing? | CAPEX during construction only |
| 6.22 | Corp Loan Financing Cost Amortization | Amortizes over what period? | CAPEX |
| 6.23 | Corp Loan LC Interest | Same as 6.21 | CAPEX during construction |
| 6.25 | Upfront Credit Facility Fees | One-time at financial close | CAPEX |
| 6.51 | Construction Debt Transaction Cost | Name says construction | CAPEX |
| 6.55 | Construction Debt Interest | Name says construction | CAPEX |
| 6.99 | Finance — Other | Catch-all, depends on what's in it | CAPEX (default), but flag for review |
| 6.60 | Proxima Upfront Fees & Transaction Costs Amortization | Amortization could continue post-COD | CAPEX (default) |
| 9.99 | GA / Allocated Costs | Capitalized or expensed? | CAPEX (Intersect convention TBD) |
| 13.20 | Insurance — Project Level Insurance | Construction vs operating split | Default CAPEX during construction phase, OPEX after COD — but forecast file isn't phase-tagged so SUM goes one way |
| 14.00 | O&M Fee (Construction) | Name says construction → capex? Or O&M = opex? | Name suggests CAPEX (construction-period O&M setup); inconsistent with 14.xx OPEX rule |
| 22.80 | Commissioning Fees / Spare Parts | Initial spare parts → capex; ongoing → opex | CAPEX (initial capitalization) |

**Recommendation:** Build the staging→fct join with an explicit `cost_classification` derived column (`'capex'`, `'opex'`, `'ambiguous'`) so we can isolate ambiguous flows for separate review without holding up the clean cases.

---

## 4. Join keys

### Forecast staging → `fct_finance.project_capex_monthly`
```sql
SELECT
  stg.technology,
  stg.forecast_date AS calendar_month_end,
  SUM(stg.monthly_spend_usd) AS monthly_capex_usd,
  COUNT(*) AS component_count
FROM stg_finance.v6_stg_forecast_inputs stg
WHERE stg.acct_code_classification = 'capex'  -- requires classification mapping
GROUP BY 1, 2;
```

**Join keys:** `(technology, forecast_date)` ↔ `(technology, calendar_month_end)`

**NOT joined on `run_id`** — the forecast tool has its own `run_id` (from Forecast Tool sheet pushes); the LCOE fct tables use a different `run_id` (from inputs_tab/capex_tool/opex_tool pushes). These are independent pipelines pushing to the same warehouse. The forecast-into-fct integration needs an explicit decision about whether the forecast run replaces, augments, or runs in parallel to the existing capex_tool data.

### Forecast staging → `fct_finance.project_opex_monthly.om_monthly_usd`
```sql
SELECT
  technology,
  forecast_date AS calendar_month_end,
  SUM(monthly_spend_usd) AS om_monthly_usd_from_forecast
FROM stg_finance.v6_stg_forecast_inputs
WHERE cat = 'OPR' OR acct_code LIKE '14.%'
GROUP BY 1, 2;
```

The forecast tool's only clear opex contribution is to `om_monthly_usd`. All other opex columns (land lease, insurance, property tax, etc.) continue to come from `v6_stg_opex_lifetime_totals` / `v6_stg_om_schedules`. Verify with Alexa whether forecast O&M should replace or add to the existing `om_monthly_usd` source.

---

## 5. Columns present in fct but missing from forecast staging

### Missing from forecast → fct_capex_monthly
- `component_count` — can be derived as `COUNT(*)` during the join aggregation.
- `monthly_capex_usd` — derived as `SUM(monthly_spend_usd)` during aggregation.

No structural gaps for capex.

### Missing from forecast → fct_opex_monthly
The fct opex table has 11 component columns. The forecast tool only sources data for 1–2 of them (O&M, possibly Insurance). The other 9 columns must continue to be populated from their existing sources:

| fct column | Existing source (do not change) | Forecast contribution? |
|---|---|---|
| land_lease_monthly_usd | Opex_Tool / `v6_stg_opex_lifetime_totals` | No — not in forecast |
| insurance_monthly_usd | Opex_Tool | **Possibly** — if 13.20 is operating-period |
| property_tax_monthly_usd | Opex_Tool | No |
| other_expenses_monthly_usd | Opex_Tool | No |
| gas_fuel_monthly_usd | Opex_Tool | No |
| dtc_hv_monthly_usd | Opex_Tool | No |
| lcs_monthly_usd | Opex_Tool | No |
| om_monthly_usd | `v6_stg_om_schedules` | **Yes** — primary forecast contribution |
| wake_losses_monthly_usd | Opex_Tool | No |
| sleeve_fee_monthly_usd | Opex_Tool (OI-005 placeholder) | No |
| franchise_tax_monthly_usd | Opex_Tool (OI-005 placeholder) | No |

### Missing from forecast that fct downstream may need
- `operating_year_num`, `operating_month_num` — these are derived from COD date per technology, not from the forecast itself. Compute during join using `dim_time` or project_timeline join keyed on `(technology, forecast_date)`.

### Missing from fct that forecast carries (decision: keep or drop on aggregation?)
Forecast staging carries useful detail that's *lost* on aggregation to fct:
- `cat`, `acct_code`, `budget_item`, `vendor`, `cost_type`, `source_row`

If Alexa wants these for traceability into the LCOE outputs, we may need either:
- A new fct table like `fct_finance.project_capex_lineitem_monthly` preserving forecast detail, OR
- A view layer that joins fct back to staging for drill-down without changing fct aggregates.

---

## 6. Open questions for Alexa

1. **Run ID strategy:** Should a forecast push automatically refresh the fct_capex_monthly numbers, or should fct still source from `v6_raw_capex_tool` and only consume forecast on explicit demand? (Concretely: does pushing the forecast tool change LCOE outputs without a separate LCOE pipeline run?)
2. **Ambiguous classifications:** Confirm capex vs opex for the 13 acct_codes flagged in §3.
3. **6.xx finance treatment:** Are 6.xx items all construction-period, or do some extend into operations?
4. **13.20 insurance split:** Is there a phase-tag in the forecast tool we should be using, or do we assume 100% one bucket?
5. **9.99 G&A:** Capitalized or expensed per Intersect convention?
6. **14.00 O&M Fee (Construction):** Capex (name suggests construction-period setup) or opex?
7. **Line-item traceability:** Do we need a drill-down view from fct back to forecast source rows? If yes, what shape?
8. **Case-difference normalization:** Solar has both "Owner Construction" and "Owner construction" as acct_code 13.50 — single source row error, or intentional? Should staging UPPER-cap them?
