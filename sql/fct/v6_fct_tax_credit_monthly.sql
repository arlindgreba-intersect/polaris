-- =============================================================================
-- Polaris V6 - fct_finance.tax_credit_monthly
-- Append-only. run_id overridden with canonical timeline run_id (was previously
-- COALESCE'd from silver_itc_inputs / timeline).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.tax_credit_monthly` (
  calendar_month_end  DATE,
  technology          STRING,
  itc_benefit_usd     FLOAT64,
  run_id              STRING,
  pushed_at           TIMESTAMP,
  run_label           STRING,
  created_at          TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.tax_credit_monthly`
(calendar_month_end, technology, itc_benefit_usd, run_id, pushed_at, run_label, created_at, run_type)
WITH
canonical AS (
  SELECT run_id, pushed_at, run_label, run_type
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_itc AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  ORDER BY pushed_at DESC LIMIT 1
),
itc AS (
  SELECT technology, net_itc_usd, substantial_completion_date
  FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  WHERE run_id = (SELECT run_id FROM latest_itc)
),
timeline AS (
  SELECT calendar_month_end, technology
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
)
SELECT
  t.calendar_month_end,
  t.technology,
  CASE
    WHEN t.technology IN ('Solar','Wind','BESS')
     AND t.calendar_month_end = LAST_DAY(i.substantial_completion_date, MONTH)
      THEN -1.0 * COALESCE(i.net_itc_usd, 0)
    ELSE 0.0
  END AS itc_benefit_usd,
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM timeline t
LEFT JOIN itc i ON i.technology = t.technology
CROSS JOIN canonical c;