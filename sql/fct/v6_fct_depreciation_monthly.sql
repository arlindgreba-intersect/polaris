-- =============================================================================
-- Polaris V6 - fct_finance.depreciation_monthly
-- Append-only. run_id overridden with canonical timeline run_id.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.depreciation_monthly` (
  calendar_month_end                    DATE,
  technology                            STRING,
  depreciation_tax_shield_monthly_usd   FLOAT64,
  macrs_year_num                        INT64,
  run_id                                STRING,
  pushed_at                             TIMESTAMP,
  run_label                             STRING,
  created_at                            TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.depreciation_monthly`
(calendar_month_end, technology, depreciation_tax_shield_monthly_usd, macrs_year_num,
 run_id, pushed_at, run_label, created_at, run_type)
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
  SELECT technology, five_yr_macrs_basis_usd, twenty_yr_macrs_basis_usd, effective_tax_rate
  FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  WHERE run_id = (SELECT run_id FROM latest_itc)
),
timeline AS (
  SELECT calendar_month_end, technology, operating_month_num
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
)
SELECT
  t.calendar_month_end,
  t.technology,
  CASE
    WHEN t.technology IN ('Solar','Wind','BESS') AND t.operating_month_num BETWEEN 1 AND 60
      THEN (COALESCE(i.five_yr_macrs_basis_usd, 0) * COALESCE(i.effective_tax_rate, 0.21)) / 60.0
    WHEN t.technology IN ('Gas','DTC') AND t.operating_month_num BETWEEN 1 AND 240
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
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM timeline t
LEFT JOIN itc i ON i.technology = t.technology
CROSS JOIN canonical c;