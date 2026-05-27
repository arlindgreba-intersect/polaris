-- =============================================================================
-- Polaris V6 — fct_finance.revenue_monthly
-- One row per technology per operating month
-- All revenue values = 0.0 (PLACEHOLDER — OI-005 market curves not yet delivered
--   by Brian Wile; ExcelBridge integration pending)
-- Technologies: Solar, Wind, Gas, BESS, DTC (all 5)
-- Source: fct_finance.project_timeline_monthly filtered to is_operation = TRUE
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.revenue_monthly` AS
SELECT
  t.calendar_month_end,
  t.technology,
  t.operating_year_num,
  0.0  AS revenue_usd,
  TRUE AS is_placeholder,
  'OI-005: ExcelBridge market curves pending Brian Wile' AS placeholder_reason,
  t.run_id
FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly` t
WHERE t.is_operation = TRUE
ORDER BY t.technology, t.calendar_month_end;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Row counts + date range + revenue sum per tech (must be 0)
SELECT
  technology,
  COUNT(*)                            AS row_count,
  MIN(calendar_month_end)             AS min_month,
  MAX(calendar_month_end)             AS max_month,
  SUM(revenue_usd)                    AS sum_revenue_usd,
  COUNT(DISTINCT placeholder_reason)  AS distinct_reasons
FROM `sandbox-lakehouse.fct_finance.revenue_monthly`
GROUP BY technology
ORDER BY technology;
-- Expected: row counts match operating-life-in-months per tech;
--   sum_revenue_usd = 0 (placeholder); distinct_reasons = 1.