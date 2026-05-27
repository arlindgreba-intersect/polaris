-- =============================================================================
-- Polaris V6 — fct_finance.depreciation_monthly
-- One row per technology per calendar month during operating life
-- 5-yr MACRS (Solar/Wind/BESS): five_yr_macrs_basis_usd × effective_tax_rate spread
--   evenly over the first 60 operating months (60 rows per tech)
-- 20-yr MACRS (Gas/DTC): twenty_yr_macrs_basis_usd × effective_tax_rate spread
--   evenly over the first 240 operating months (240 rows per tech)
-- Source: mart_finance.v6_silver_itc_inputs joined to fct_finance.project_timeline_monthly
--         (filtered to is_operation = TRUE)
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.depreciation_monthly` AS
WITH
latest_itc AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  ORDER BY pushed_at DESC LIMIT 1
),
itc AS (
  SELECT
    technology,
    five_yr_macrs_basis_usd,
    twenty_yr_macrs_basis_usd,
    effective_tax_rate,
    run_id
  FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  WHERE run_id = (SELECT run_id FROM latest_itc)
),
timeline AS (
  SELECT
    calendar_month_end,
    technology,
    operating_month_num,
    run_id
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
)
SELECT
  t.calendar_month_end,
  t.technology,
  CASE
    WHEN t.technology IN ('Solar','Wind','BESS')
     AND t.operating_month_num BETWEEN 1 AND 60
      THEN (COALESCE(i.five_yr_macrs_basis_usd, 0) * COALESCE(i.effective_tax_rate, 0.21)) / 60.0
    WHEN t.technology IN ('Gas','DTC')
     AND t.operating_month_num BETWEEN 1 AND 240
      THEN (COALESCE(i.twenty_yr_macrs_basis_usd, 0) * COALESCE(i.effective_tax_rate, 0.21)) / 240.0
    ELSE 0.0
  END AS depreciation_tax_shield_monthly_usd,
  CASE
    WHEN t.technology IN ('Solar','Wind','BESS') AND t.operating_month_num BETWEEN 1 AND 60
      THEN CAST(CEIL(t.operating_month_num / 12.0) AS INT64)
    WHEN t.technology IN ('Gas','DTC') AND t.operating_month_num BETWEEN 1 AND 240
      THEN CAST(CEIL(t.operating_month_num / 12.0) AS INT64)
    ELSE NULL
  END AS macrs_year_num,
  COALESCE(i.run_id, t.run_id) AS run_id
FROM timeline t
LEFT JOIN itc i ON i.technology = t.technology
ORDER BY t.technology, t.calendar_month_end;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Lifetime depreciation tax shield, macrs_year_num coverage, and month count
SELECT
  technology,
  ROUND(SUM(depreciation_tax_shield_monthly_usd), 2) AS lifetime_dep_shield,
  COUNT(DISTINCT macrs_year_num)                    AS macrs_years,
  COUNTIF(depreciation_tax_shield_monthly_usd > 0)  AS months_with_dep
FROM `sandbox-lakehouse.fct_finance.depreciation_monthly`
GROUP BY technology
ORDER BY technology;
-- Expected:
--   Solar/Wind/BESS: 60 months, 5 macrs_year_num values
--   Gas/DTC: 240 months, 20 macrs_year_num values