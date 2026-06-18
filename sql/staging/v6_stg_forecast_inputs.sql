-- =============================================================================
-- v6_stg_forecast_inputs
-- Polaris V6 - Staging Layer
-- Source: polaris_raw.v6_raw_forecast_inputs
--
-- PURPOSE:
-- Unpivots the wide v6_raw_forecast_inputs table (130 monthly period_* columns
-- per row) into long format: one row per (technology, source_row, forecast_date).
-- This is the format the LCOE fct layer expects for joining forecast spend into
-- monthly capex/opex aggregates.
--
-- INPUT SHAPE (raw):
--   885 rows (Wind 370 + BESS 8 + Gas 109 + DTC 67 + Solar 331)
--   17 metadata cols + 130 period_* FLOAT64 cols (Sep-2020 -> Jun-2031)
--
-- OUTPUT SHAPE (staging):
--   ~tens of thousands of rows, one per non-zero monthly spend cell.
--   Filter: monthly_spend_usd IS NOT NULL AND monthly_spend_usd != 0.
--
-- RUN SELECTION:
--   Always reads the latest run_id from v6_raw_forecast_inputs (by pushed_at).
--   Re-run this script after every fresh push from the sheet.
--
-- CLUSTERING:
--   CLUSTER BY technology, forecast_date — BQ does not support partitioning on a
--   STRING column. Clustering by technology + forecast_date keeps fct joins
--   efficient (filter pushdown on technology=, forecast_date range) without
--   needing a derived partition key.
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_forecast_inputs`
CLUSTER BY technology, forecast_date
AS

WITH latest_run AS (
  SELECT run_id
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_forecast_inputs`
  ORDER BY pushed_at DESC
  LIMIT 1
),

src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_forecast_inputs`
  WHERE run_id = (SELECT run_id FROM latest_run)
),

unpivoted AS (
  SELECT
    run_id,
    run_label,
    run_type,
    project_id,
    technology,
    cat,
    acct_code,
    budget_item,
    vendor,
    cost_type,
    source_row,
    PARSE_DATE('%Y_%m_%d', REGEXP_REPLACE(period_col, '^period_', '')) AS forecast_date,
    monthly_spend_usd
  FROM src
  UNPIVOT INCLUDE NULLS (
    monthly_spend_usd FOR period_col IN (
      period_2020_09_30, period_2020_10_31, period_2020_11_30, period_2020_12_31,
      period_2021_01_31, period_2021_02_28, period_2021_03_31, period_2021_04_30,
      period_2021_05_31, period_2021_06_30, period_2021_07_31, period_2021_08_31,
      period_2021_09_30, period_2021_10_31, period_2021_11_30, period_2021_12_31,
      period_2022_01_31, period_2022_02_28, period_2022_03_31, period_2022_04_30,
      period_2022_05_31, period_2022_06_30, period_2022_07_31, period_2022_08_31,
      period_2022_09_30, period_2022_10_31, period_2022_11_30, period_2022_12_31,
      period_2023_01_31, period_2023_02_28, period_2023_03_31, period_2023_04_30,
      period_2023_05_31, period_2023_06_30, period_2023_07_31, period_2023_08_31,
      period_2023_09_30, period_2023_10_31, period_2023_11_30, period_2023_12_31,
      period_2024_01_31, period_2024_02_29, period_2024_03_31, period_2024_04_30,
      period_2024_05_31, period_2024_06_30, period_2024_07_31, period_2024_08_31,
      period_2024_09_30, period_2024_10_31, period_2024_11_30, period_2024_12_31,
      period_2025_01_31, period_2025_02_28, period_2025_03_31, period_2025_04_30,
      period_2025_05_31, period_2025_06_30, period_2025_07_31, period_2025_08_31,
      period_2025_09_30, period_2025_10_31, period_2025_11_30, period_2025_12_31,
      period_2026_01_31, period_2026_02_28, period_2026_03_31, period_2026_04_30,
      period_2026_05_31, period_2026_06_30, period_2026_07_31, period_2026_08_31,
      period_2026_09_30, period_2026_10_31, period_2026_11_30, period_2026_12_31,
      period_2027_01_31, period_2027_02_28, period_2027_03_31, period_2027_04_30,
      period_2027_05_31, period_2027_06_30, period_2027_07_31, period_2027_08_31,
      period_2027_09_30, period_2027_10_31, period_2027_11_30, period_2027_12_31,
      period_2028_01_31, period_2028_02_29, period_2028_03_31, period_2028_04_30,
      period_2028_05_31, period_2028_06_30, period_2028_07_31, period_2028_08_31,
      period_2028_09_30, period_2028_10_31, period_2028_11_30, period_2028_12_31,
      period_2029_01_31, period_2029_02_28, period_2029_03_31, period_2029_04_30,
      period_2029_05_31, period_2029_06_30, period_2029_07_31, period_2029_08_31,
      period_2029_09_30, period_2029_10_31, period_2029_11_30, period_2029_12_31,
      period_2030_01_31, period_2030_02_28, period_2030_03_31, period_2030_04_30,
      period_2030_05_31, period_2030_06_30, period_2030_07_31, period_2030_08_31,
      period_2030_09_30, period_2030_10_31, period_2030_11_30, period_2030_12_31,
      period_2031_01_31, period_2031_02_28, period_2031_03_31, period_2031_04_30,
      period_2031_05_31, period_2031_06_30
    )
  )
)

SELECT
  run_id,
  run_label,
  run_type,
  project_id,
  technology,
  cat,
  acct_code,
  budget_item,
  vendor,
  cost_type,
  source_row,
  forecast_date,
  monthly_spend_usd
FROM unpivoted
WHERE monthly_spend_usd IS NOT NULL
  AND monthly_spend_usd != 0;
