# Polaris — Roman III LCOE Model V6 Pipeline

## Structure
- `apps_script/` — Google Apps Script ingestion scripts (push Excel tabs to BQ)
- `sql/staging/` — Staging layer SQL (stg_finance dataset)
- `sql/silver/` — Silver layer SQL (mart_finance dataset)
- `sql/fct/` — fct layer SQL (fct_finance dataset) — UNDER CONSTRUCTION

## BQ Datasets
- `polaris_raw` — raw ingestion tables
- `stg_finance` — staging/normalized tables
- `mart_finance` — silver + mart output tables
- `fct_finance` — calculation fact models (in progress)
- `dim_time` — monthly calendar

## Status
Raw + Staging + Silver: complete and validated
fct layer: dim_month + project_timeline_monthly done, generation_monthly next