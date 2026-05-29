-- =============================================================================
-- Polaris V6 - fct_finance.generation_monthly
-- Append-only with canonical run_id / run_label / pushed_at / created_at.
-- Preserves silver_run_id / silver_pushed_at for source-lineage traceability.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.generation_monthly` (
  calendar_month_end           DATE,
  technology                   STRING,
  operating_year_num           INT64,
  operating_month_num          INT64,
  degradation_factor           FLOAT64,
  y1_monthly_generation_mwh    FLOAT64,
  monthly_generation_mwh       FLOAT64,
  y1_generation_mwh            FLOAT64,
  annual_degradation_rate      FLOAT64,
  useful_life_years            FLOAT64,
  silver_run_id                STRING,
  silver_pushed_at             TIMESTAMP,
  run_id                       STRING,
  pushed_at                    TIMESTAMP,
  run_label                    STRING,
  created_at                   TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.generation_monthly`
(calendar_month_end, technology, operating_year_num, operating_month_num,
 degradation_factor, y1_monthly_generation_mwh, monthly_generation_mwh,
 y1_generation_mwh, annual_degradation_rate, useful_life_years,
 silver_run_id, silver_pushed_at, run_id, pushed_at, run_label, created_at, run_type)
WITH
canonical AS (
  SELECT run_id, pushed_at, run_label, run_type
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_silver AS (
  SELECT run_id, pushed_at
  FROM `sandbox-lakehouse.mart_finance.v6_silver_project_inputs`
  ORDER BY pushed_at DESC LIMIT 1
),
silver AS (
  SELECT technology, y1_generation_mwh, annual_degradation_rate, useful_life_years,
         run_id AS silver_run_id, pushed_at AS silver_pushed_at
  FROM `sandbox-lakehouse.mart_finance.v6_silver_project_inputs`
  WHERE run_id = (SELECT run_id FROM latest_silver)
    AND technology IN ('Solar','Wind','Gas')
),
ops AS (
  SELECT calendar_month_end, technology, operating_year_num, operating_month_num
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
    AND technology IN ('Solar','Wind','Gas')
)
SELECT
  o.calendar_month_end,
  o.technology,
  o.operating_year_num,
  o.operating_month_num,
  POWER(1 - COALESCE(s.annual_degradation_rate, 0), o.operating_year_num - 1)   AS degradation_factor,
  s.y1_generation_mwh / 12.0                                                     AS y1_monthly_generation_mwh,
  (s.y1_generation_mwh / 12.0)
    * POWER(1 - COALESCE(s.annual_degradation_rate, 0), o.operating_year_num - 1) AS monthly_generation_mwh,
  s.y1_generation_mwh,
  s.annual_degradation_rate,
  s.useful_life_years,
  s.silver_run_id,
  s.silver_pushed_at,
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM ops o
LEFT JOIN silver s ON s.technology = o.technology
CROSS JOIN canonical c;