-- =============================================================================
-- Polaris V6 - fct_finance.depreciation_monthly
-- CORRECTED v2 — 2026-06-07
--
-- FIXES vs original:
--   1. Replaced straight-line with actual MACRS year-by-year schedule
--   2. Both MACRS classes (5-yr and 20-yr) blended per technology
--      Solar/Wind/BESS: 5-yr schedule only (20-yr basis = 0 for these techs)
--      Gas/DTC: 20-yr schedule only (5-yr basis = 0 for these techs)
--      If a tech ever has both, the two amounts are summed.
--   3. MACRS percentages hardcoded from Inputs tab R88-R116 (Case 8 workbook)
--      These are the same for all cases — they are IRS MACRS schedules.
--
-- MACRS SCHEDULES (from Inputs tab R87-R116):
--   5-yr schedule (Solar, Wind, BESS) — col E (Solar):
--     Yr1: 6.667%  Yr2: 37.333%  Yr3: 22.4%  Yr4: 13.44%  Yr5: 13.44%  Yr6: 6.72%
--   20-yr schedule (Gas, DTC) — col E (Solar):
--     Yr1: 1.25%   Yr2: 7.406%  Yr3: 6.851%  Yr4: 6.337%  Yr5: 5.862%
--     Yr6: 5.422%  Yr7: 5.015%  Yr8: 4.639%  Yr9: 4.577%  Yr10-20: 4.577%
--     Yr21: 2.289% (half-year convention)
--
-- Append-only. run_id from canonical timeline.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.depreciation_monthly` (
  calendar_month_end                    DATE,
  technology                            STRING,
  depreciation_tax_shield_monthly_usd   FLOAT64,
  macrs_year_num                        INT64,
  macrs_class                           STRING,
  run_id                                STRING,
  pushed_at                             TIMESTAMP,
  run_label                             STRING,
  created_at                            TIMESTAMP,
  run_type                              STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.depreciation_monthly`
(calendar_month_end, technology, depreciation_tax_shield_monthly_usd, macrs_year_num,
 macrs_class, run_id, pushed_at, run_label, created_at, run_type)

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
  SELECT calendar_month_end, technology, operating_month_num,
         CAST(CEIL(operating_month_num / 12.0) AS INT64) AS macrs_year_num
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
    AND run_id = (
      SELECT run_id FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
      ORDER BY pushed_at DESC LIMIT 1
    )
),

-- MACRS 5-yr schedule (IRS GDS, half-year convention)
-- Applies to Solar, Wind, BESS
macrs_5yr AS (
  SELECT yr, pct FROM UNNEST([
    STRUCT(1  AS yr, 0.06666666667 AS pct),
    STRUCT(2,        0.3733333333),
    STRUCT(3,        0.224),
    STRUCT(4,        0.1344),
    STRUCT(5,        0.1344),
    STRUCT(6,        0.0672)
  ])
),

-- MACRS 20-yr schedule (IRS GDS, half-year convention)
-- Applies to Gas, DTC
macrs_20yr AS (
  SELECT yr, pct FROM UNNEST([
    STRUCT(1  AS yr, 0.0125        AS pct),
    STRUCT(2,        0.0740625),
    STRUCT(3,        0.0685078125),
    STRUCT(4,        0.06336972656),
    STRUCT(5,        0.05861699707),
    STRUCT(6,        0.05422072229),
    STRUCT(7,        0.05015416812),
    STRUCT(8,        0.04639260551),
    STRUCT(9,        0.04577403744),
    STRUCT(10,       0.04577403744),
    STRUCT(11,       0.04577403744),
    STRUCT(12,       0.04577403744),
    STRUCT(13,       0.04577403744),
    STRUCT(14,       0.04577403744),
    STRUCT(15,       0.04577403744),
    STRUCT(16,       0.04577403744),
    STRUCT(17,       0.04577403744),
    STRUCT(18,       0.04577403744),
    STRUCT(19,       0.04577403744),
    STRUCT(20,       0.04577403744),
    STRUCT(21,       0.02288701872)   -- half-year convention yr 21
  ])
),

-- 5-yr depreciation rows for Solar/Wind/BESS
dep_5yr AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.macrs_year_num,
    '5-yr' AS macrs_class,
    -- Monthly shield = annual_basis × MACRS_pct × tax_rate / 12
    ROUND(
      COALESCE(i.five_yr_macrs_basis_usd, 0)
      * COALESCE(m.pct, 0)
      * COALESCE(i.effective_tax_rate, 0.21)
      / 12.0,
      4
    ) AS depreciation_tax_shield_monthly_usd
  FROM timeline t
  LEFT JOIN itc i ON i.technology = t.technology
  LEFT JOIN macrs_5yr m ON m.yr = t.macrs_year_num
  WHERE t.technology IN ('Solar','Wind','BESS')
    AND t.macrs_year_num BETWEEN 1 AND 6
),

-- 20-yr depreciation rows for Gas/DTC
dep_20yr AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.macrs_year_num,
    '20-yr' AS macrs_class,
    ROUND(
      COALESCE(i.twenty_yr_macrs_basis_usd, 0)
      * COALESCE(m.pct, 0)
      * COALESCE(i.effective_tax_rate, 0.21)
      / 12.0,
      4
    ) AS depreciation_tax_shield_monthly_usd
  FROM timeline t
  LEFT JOIN itc i ON i.technology = t.technology
  LEFT JOIN macrs_20yr m ON m.yr = t.macrs_year_num
  WHERE t.technology IN ('Gas','DTC')
    AND t.macrs_year_num BETWEEN 1 AND 21
),

-- Zero rows for periods outside the MACRS window (still in operation, no depreciation)
dep_zero AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.macrs_year_num,
    CASE WHEN t.technology IN ('Solar','Wind','BESS') THEN '5-yr' ELSE '20-yr' END AS macrs_class,
    0.0 AS depreciation_tax_shield_monthly_usd
  FROM timeline t
  WHERE (
    t.technology IN ('Solar','Wind','BESS') AND t.macrs_year_num > 6
  ) OR (
    t.technology IN ('Gas','DTC') AND t.macrs_year_num > 21
  )
),

all_dep AS (
  SELECT * FROM dep_5yr
  UNION ALL
  SELECT * FROM dep_20yr
  UNION ALL
  SELECT * FROM dep_zero
)

SELECT
  d.calendar_month_end,
  d.technology,
  d.depreciation_tax_shield_monthly_usd,
  d.macrs_year_num,
  d.macrs_class,
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM all_dep d
CROSS JOIN canonical c;
