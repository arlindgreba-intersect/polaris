-- =============================================================================
-- Polaris V6 - fct_finance.project_timeline_monthly
-- Append-only pattern with canonical run_id / run_label / pushed_at / created_at.
-- dim_time.dim_month is owned by v6_dim_tables_v2.sql (must exist before this runs).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.project_timeline_monthly` (
  calendar_month_end           DATE,
  calendar_year                INT64,
  calendar_month_num           INT64,
  year_month                   STRING,
  calendar_quarter             STRING,
  month_seq                    INT64,
  technology                   STRING,
  is_development               BOOL,
  is_construction              BOOL,
  is_operation                 BOOL,
  construction_month_num       INT64,
  operating_year_num           INT64,
  operating_month_num          INT64,
  total_operating_months       INT64,
  dev_start_date               DATE,
  construction_start_date      DATE,
  substantial_completion_date  DATE,
  end_of_useful_life_date      DATE,
  useful_life_years            FLOAT64,
  run_id                       STRING,
  pushed_at                    TIMESTAMP,
  run_label                    STRING,
  created_at                   TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.project_timeline_monthly`
(calendar_month_end, calendar_year, calendar_month_num, year_month, calendar_quarter,
 month_seq, technology, is_development, is_construction, is_operation,
 construction_month_num, operating_year_num, operating_month_num, total_operating_months,
 dev_start_date, construction_start_date, substantial_completion_date, end_of_useful_life_date,
 useful_life_years, run_id, pushed_at, run_label, created_at, run_type)
WITH
canonical AS (
  SELECT run_id, pushed_at, run_label, run_type
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
timeline AS (
  SELECT
    technology, dev_start_date, construction_start_date,
    substantial_completion_date, end_of_useful_life_date, useful_life_years,
    run_id, pushed_at
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE run_id = (SELECT run_id FROM canonical)
),
crossed AS (
  SELECT d.*, t.dev_start_date, t.construction_start_date,
         t.substantial_completion_date, t.end_of_useful_life_date,
         t.useful_life_years, t.technology
  FROM `sandbox-lakehouse.dim_time.dim_month` d
  CROSS JOIN timeline t
)
SELECT
  cr.calendar_month_end, cr.calendar_year, cr.calendar_month_num, cr.year_month,
  cr.calendar_quarter, cr.month_seq, cr.technology,
  CASE WHEN cr.calendar_month_end >= cr.dev_start_date
        AND cr.calendar_month_end <  cr.construction_start_date
       THEN TRUE ELSE FALSE END AS is_development,
  CASE WHEN cr.calendar_month_end >= cr.construction_start_date
        AND cr.calendar_month_end <  cr.substantial_completion_date
       THEN TRUE ELSE FALSE END AS is_construction,
  CASE WHEN cr.calendar_month_end >= cr.substantial_completion_date
        AND cr.calendar_month_end <= cr.end_of_useful_life_date
       THEN TRUE ELSE FALSE END AS is_operation,
  CASE WHEN cr.calendar_month_end >= cr.construction_start_date
        AND cr.calendar_month_end <  cr.substantial_completion_date
       THEN DATE_DIFF(cr.calendar_month_end, cr.construction_start_date, MONTH) + 1
       ELSE NULL END AS construction_month_num,
  CASE WHEN cr.calendar_month_end >= cr.substantial_completion_date
        AND cr.calendar_month_end <= cr.end_of_useful_life_date
       THEN CAST(CEIL((DATE_DIFF(cr.calendar_month_end, cr.substantial_completion_date, MONTH) + 1) / 12.0) AS INT64)
       ELSE NULL END AS operating_year_num,
  CASE WHEN cr.calendar_month_end >= cr.substantial_completion_date
        AND cr.calendar_month_end <= cr.end_of_useful_life_date
       THEN DATE_DIFF(cr.calendar_month_end, cr.substantial_completion_date, MONTH) + 1
       ELSE NULL END AS operating_month_num,
  DATE_DIFF(cr.end_of_useful_life_date, cr.substantial_completion_date, MONTH) + 1 AS total_operating_months,
  cr.dev_start_date, cr.construction_start_date,
  cr.substantial_completion_date, cr.end_of_useful_life_date,
  cr.useful_life_years,
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM crossed cr
CROSS JOIN canonical c
WHERE cr.calendar_month_end >= cr.dev_start_date
  AND cr.calendar_month_end <= cr.end_of_useful_life_date;