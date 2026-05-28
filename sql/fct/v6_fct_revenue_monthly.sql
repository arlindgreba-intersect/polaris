-- =============================================================================
-- Polaris V6 - fct_finance.revenue_monthly
-- Append-only. All revenue_usd = 0 (PLACEHOLDER - OI-005 pending Brian Wile).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.revenue_monthly` (
  calendar_month_end   DATE,
  technology           STRING,
  operating_year_num   INT64,
  revenue_usd          FLOAT64,
  is_placeholder       BOOL,
  placeholder_reason   STRING,
  run_id               STRING,
  pushed_at            TIMESTAMP,
  run_label            STRING,
  created_at           TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.revenue_monthly`
(calendar_month_end, technology, operating_year_num, revenue_usd, is_placeholder,
 placeholder_reason, run_id, pushed_at, run_label, created_at, run_type)
WITH
canonical AS (
  SELECT run_id, pushed_at
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
)
SELECT
  t.calendar_month_end,
  t.technology,
  t.operating_year_num,
  0.0  AS revenue_usd,
  TRUE AS is_placeholder,
  'OI-005: ExcelBridge market curves pending Brian Wile' AS placeholder_reason,
  c.run_id,
  c.pushed_at,
  'Monthly_Haul_04_2026' AS run_label,
  CURRENT_TIMESTAMP() AS created_at,
  'current_forecast' AS run_type
FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly` t
CROSS JOIN canonical c
WHERE t.is_operation = TRUE;