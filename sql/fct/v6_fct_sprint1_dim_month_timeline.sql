-- =============================================================================
-- Polaris V6 — fct Layer Sprint 1
-- dim_time.dim_month + fct_finance.project_timeline_monthly
-- =============================================================================
-- Source values confirmed from Copy - Roman III LCOE Model V6 - Case 4:
--   Dev Start (all techs):  2024-01-31
--   Solar Const Start:      2028-03-31  SC: 2029-09-30  EoUL: 2064-09-30
--   Wind  Const Start:      2028-04-30  SC: 2029-10-31  EoUL: 2059-10-31
--   Gas   Const Start:      2027-03-31  SC: 2029-03-31  EoUL: 2049-03-31
--   BESS  Const Start:      2027-03-31  SC: 2029-03-31  EoUL: 2049-03-31
--   DTC   Const Start:      2027-11-30  SC: 2029-03-31  EoUL: 2049-03-31
--   Discount rate: 4.35% (not used — V6 is undiscounted, confirmed from User Guide)
-- =============================================================================


-- =============================================================================
-- STEP 1: dim_time.dim_month
-- 576-row monthly calendar anchored to Solar Dev Start (2024-01-31)
-- Runs from 2024-01-31 through 2071-12-31 (covers all tech useful lives)
-- Every fct model joins to this on calendar_month_end
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.dim_time.dim_month` AS

WITH spine AS (
  -- Generate one row per month, each date = true last day of that month
  -- Uses LAST_DAY() to guarantee correct end-of-month regardless of Feb/30/31
  SELECT
    LAST_DAY(month_start, MONTH) AS calendar_month_end
  FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE '2024-01-01',
      DATE '2071-12-01',
      INTERVAL 1 MONTH
    )
  ) AS month_start
)

SELECT
  -- Primary key
  calendar_month_end,

  -- Calendar fields
  EXTRACT(YEAR  FROM calendar_month_end)  AS calendar_year,
  EXTRACT(MONTH FROM calendar_month_end)  AS calendar_month_num,
  FORMAT_DATE('%b', calendar_month_end)   AS calendar_month_abbr,
  FORMAT_DATE('%Y-%m', calendar_month_end) AS year_month,

  -- Row number from start of calendar (1 = Jan 2024)
  ROW_NUMBER() OVER (ORDER BY calendar_month_end) AS month_seq,

  -- Months elapsed since Solar Dev Start (2024-01-31 = month 0)
  DATE_DIFF(
    calendar_month_end,
    DATE '2024-01-31',
    MONTH
  ) AS months_since_dev_start,

  -- Fiscal half-year flag (useful for liquidity reporting)
  CASE
    WHEN EXTRACT(MONTH FROM calendar_month_end) <= 6 THEN 'H1'
    ELSE 'H2'
  END AS fiscal_half,

  -- Calendar quarter
  CONCAT('Q', CAST(CEIL(EXTRACT(MONTH FROM calendar_month_end) / 3.0) AS INT64))
    AS calendar_quarter

FROM spine
ORDER BY calendar_month_end;


-- =============================================================================
-- STEP 2: fct_finance.project_timeline_monthly
-- One row per technology per calendar month
-- Flags: is_development, is_construction, is_operation
-- Also: operating_year_number, construction_month_number
-- Reads from: dim_time.dim_month + stg_finance.v6_stg_project_timeline
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.project_timeline_monthly` AS

WITH

-- Pull latest pushed timeline inputs
timeline AS (
  SELECT
    technology,
    dev_start_date,
    construction_start_date,
    substantial_completion_date,
    end_of_useful_life_date,
    useful_life_years,
    run_id,
    pushed_at
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

-- Cross join every tech against every month in the calendar
crossed AS (
  SELECT
    d.calendar_month_end,
    d.calendar_year,
    d.calendar_month_num,
    d.year_month,
    d.month_seq,
    d.months_since_dev_start,
    d.calendar_quarter,
    t.technology,
    t.dev_start_date,
    t.construction_start_date,
    t.substantial_completion_date,
    t.end_of_useful_life_date,
    t.useful_life_years,
    t.run_id,
    t.pushed_at
  FROM `sandbox-lakehouse.dim_time.dim_month` d
  CROSS JOIN timeline t
)

SELECT
  -- Identity
  calendar_month_end,
  calendar_year,
  calendar_month_num,
  year_month,
  calendar_quarter,
  month_seq,
  technology,

  -- Project phase flags
  -- Development: from dev_start up to (but not including) construction_start
  CASE
    WHEN calendar_month_end >= dev_start_date
     AND calendar_month_end <  construction_start_date
    THEN TRUE ELSE FALSE
  END AS is_development,

  -- Construction: from construction_start up to (but not including) SC date
  CASE
    WHEN calendar_month_end >= construction_start_date
     AND calendar_month_end <  substantial_completion_date
    THEN TRUE ELSE FALSE
  END AS is_construction,

  -- Operation: from SC date through end of useful life (inclusive)
  CASE
    WHEN calendar_month_end >= substantial_completion_date
     AND calendar_month_end <= end_of_useful_life_date
    THEN TRUE ELSE FALSE
  END AS is_operation,

  -- Construction month number (1 = first month of construction)
  CASE
    WHEN calendar_month_end >= construction_start_date
     AND calendar_month_end <  substantial_completion_date
    THEN DATE_DIFF(calendar_month_end, construction_start_date, MONTH) + 1
    ELSE NULL
  END AS construction_month_num,

  -- Operating year number (1 = first 12 months after SC)
  -- Used for degradation: gen_yr_N = gen_yr1 × (1 - ann_deg_rate × (N-1))
  CASE
    WHEN calendar_month_end >= substantial_completion_date
     AND calendar_month_end <= end_of_useful_life_date
    THEN CAST(
      CEIL(
        (DATE_DIFF(calendar_month_end, substantial_completion_date, MONTH) + 1) / 12.0
      ) AS INT64
    )
    ELSE NULL
  END AS operating_year_num,

  -- Operating month number within the operating period (1 = first month after SC)
  CASE
    WHEN calendar_month_end >= substantial_completion_date
     AND calendar_month_end <= end_of_useful_life_date
    THEN DATE_DIFF(calendar_month_end, substantial_completion_date, MONTH) + 1
    ELSE NULL
  END AS operating_month_num,

  -- Total operating months for this tech (for reference)
  DATE_DIFF(end_of_useful_life_date, substantial_completion_date, MONTH) + 1
    AS total_operating_months,

  -- Source date fields (for traceability)
  dev_start_date,
  construction_start_date,
  substantial_completion_date,
  end_of_useful_life_date,
  useful_life_years,

  -- Audit
  run_id,
  pushed_at

FROM crossed

-- Only keep months where something is happening for this tech
-- (drops months before dev_start and after end_of_useful_life)
WHERE calendar_month_end >= dev_start_date
  AND calendar_month_end <= end_of_useful_life_date

ORDER BY technology, calendar_month_end;


-- =============================================================================
-- VALIDATION QUERIES — run after building both tables
-- =============================================================================

-- 1. dim_month: confirm row count and date range
SELECT
  COUNT(*)        AS total_months,
  MIN(calendar_month_end) AS first_month,
  MAX(calendar_month_end) AS last_month,
  COUNT(DISTINCT calendar_year) AS years_covered
FROM `sandbox-lakehouse.dim_time.dim_month`;
-- Expected: 576 rows, 2024-01-31 to 2071-12-31, 48 years

-- 2. project_timeline_monthly: confirm phase counts per tech
SELECT
  technology,
  COUNTIF(is_development) AS dev_months,
  COUNTIF(is_construction) AS const_months,
  COUNTIF(is_operation) AS op_months,
  COUNT(*) AS total_months,
  MIN(CASE WHEN is_construction THEN calendar_month_end END) AS first_const_month,
  MIN(CASE WHEN is_operation THEN calendar_month_end END) AS first_op_month,
  MAX(CASE WHEN is_operation THEN calendar_month_end END) AS last_op_month
FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
GROUP BY technology
ORDER BY technology;
-- Expected per tech:
--   Solar:  dev=50mo, const=19mo, op=420mo  (35yr)
--   Wind:   dev=52mo, const=18mo, op=360mo  (30yr)
--   Gas:    dev=38mo, const=24mo, op=240mo  (20yr)
--   BESS:   dev=38mo, const=24mo, op=240mo  (20yr)
--   DTC:    dev=46mo, const=16mo, op=240mo  (20yr)

-- 3. Spot check Solar operating year numbers
SELECT
  calendar_month_end,
  operating_year_num,
  operating_month_num,
  is_operation
FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
WHERE technology = 'Solar'
  AND calendar_month_end BETWEEN DATE '2029-09-30' AND DATE '2031-09-30'
ORDER BY calendar_month_end;
-- Expected: op_year_num goes 1,1,...,1 (12x), then 2,2,...,2 (12x) etc.
-- First op month = 2029-09-30, last = 2064-09-30

-- 4. Confirm no gaps — every month should be in exactly one phase
SELECT
  technology,
  COUNTIF(
    CAST(is_development AS INT64) +
    CAST(is_construction AS INT64) +
    CAST(is_operation AS INT64) != 1
  ) AS months_in_wrong_phase_count
FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
GROUP BY technology;
-- Expected: all zeros — every month is in exactly one phase