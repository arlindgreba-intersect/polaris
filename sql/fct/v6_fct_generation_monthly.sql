-- =============================================================================
-- Polaris V6 — fct_finance.generation_monthly
-- Monthly generation per technology over the full operating life
-- LCOE denominator for Solar and Wind ($/MWh)
-- Gas generation used for fuel cost calculation only
-- BESS and DTC have no MWh generation denominator
-- =============================================================================
-- Source: v6_silver_generation_profile already has y1_monthly_generation_mwh
--         (Y1 annual × monthly seasonality factor) pre-computed per month_number
-- Degradation: linear — gen_yr_N = y1_monthly × (1 - ann_deg_rate × (op_year - 1))
-- Methodology: NO time value of money (undiscounted per V6 User Guide)
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.generation_monthly` AS

WITH

-- Silver generation profile — one row per tech per month_number (1-12)
-- Already has y1_monthly_generation_mwh and annual_degradation_rate
gen AS (
  SELECT
    technology,
    month_number,
    y1_monthly_generation_mwh,
    annual_degradation_rate,
    y1_generation_mwh,
    useful_life_years,
    run_id,
    pushed_at
  FROM `sandbox-lakehouse.mart_finance.v6_silver_generation_profile`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_generation_profile`
    ORDER BY pushed_at DESC LIMIT 1
  )
  AND technology IN ('Solar', 'Wind', 'Gas')
),

-- Operating months from timeline
timeline AS (
  SELECT
    calendar_month_end,
    calendar_month_num,
    technology,
    operating_year_num,
    operating_month_num
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
    AND technology IN ('Solar', 'Wind', 'Gas')
)

SELECT
  t.calendar_month_end,
  t.technology,
  t.operating_year_num,
  t.operating_month_num,

  -- Degradation factor for this operating year
  -- Year 1 = 1.0, Year 2 = 1 - rate, Year N = 1 - rate × (N-1)
  GREATEST(
    0.0,
    1.0 - (g.annual_degradation_rate * (t.operating_year_num - 1))
  )                                                 AS degradation_factor,

  -- Y1 monthly generation (pre-computed in silver)
  g.y1_monthly_generation_mwh                       AS y1_monthly_generation_mwh,

  -- Actual monthly generation after degradation
  ROUND(
    g.y1_monthly_generation_mwh
    * GREATEST(0.0, 1.0 - (g.annual_degradation_rate * (t.operating_year_num - 1))),
    2
  )                                                 AS monthly_generation_mwh,

  -- Source inputs for traceability
  g.y1_generation_mwh,
  g.annual_degradation_rate,
  g.useful_life_years,

  -- Audit
  g.run_id                                          AS silver_run_id,
  g.pushed_at                                       AS silver_pushed_at

FROM timeline t
JOIN gen g
  ON  g.technology   = t.technology
  AND g.month_number = t.calendar_month_num

ORDER BY t.technology, t.calendar_month_end;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Row counts and degradation range per tech
SELECT
  technology,
  COUNT(*)                                          AS total_months,
  MIN(calendar_month_end)                           AS first_month,
  MAX(calendar_month_end)                           AS last_month,
  ROUND(MIN(degradation_factor), 6)                 AS min_deg_factor,
  ROUND(MAX(degradation_factor), 6)                 AS max_deg_factor
FROM `sandbox-lakehouse.fct_finance.generation_monthly`
GROUP BY technology
ORDER BY technology;
-- Expected:
--   Gas:   241 months, deg=1.0 throughout (0% degradation)
--   Solar: 421 months, max_deg=1.0 (yr1), min_deg≈0.9849 (yr35)
--   Wind:  361 months, deg=1.0 throughout (0% degradation)

-- 2. Solar Year 1 sum vs Y1 input
SELECT
  technology,
  operating_year_num,
  ROUND(SUM(monthly_generation_mwh), 0)             AS annual_total_mwh,
  MAX(y1_generation_mwh)                            AS y1_input_mwh,
  ROUND(SUM(monthly_generation_mwh)
        / MAX(y1_generation_mwh) * 100, 2)          AS pct_of_y1
FROM `sandbox-lakehouse.fct_finance.generation_monthly`
WHERE technology = 'Solar' AND operating_year_num = 1
GROUP BY technology, operating_year_num;
-- Expected: annual_total close to 1,840,153 MWh, pct_of_y1 ≈ 100%

-- 3. Solar Year 35 degradation check
SELECT
  technology,
  operating_year_num,
  ROUND(SUM(monthly_generation_mwh), 0)             AS annual_total_mwh,
  MAX(degradation_factor)                           AS deg_factor
FROM `sandbox-lakehouse.fct_finance.generation_monthly`
WHERE technology = 'Solar' AND operating_year_num = 35
GROUP BY technology, operating_year_num;
-- Expected: deg_factor = 1 - (0.01556/35 × 34) ≈ 0.9849

-- 4. Lifetime generation totals — LCOE denominators
SELECT
  technology,
  ROUND(SUM(monthly_generation_mwh), 0)             AS lifetime_generation_mwh,
  COUNT(DISTINCT operating_year_num)                AS operating_years
FROM `sandbox-lakehouse.fct_finance.generation_monthly`
GROUP BY technology
ORDER BY technology;
