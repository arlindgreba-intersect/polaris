-- =============================================================================
-- Polaris V6 — Dimension Tables v2
-- dim_time.dim_year       (NEW — annual spine for pro forma analysis)
-- dim_time.dim_month_v2   (UPDATED — flexible start/end from stg_project_timeline)
-- =============================================================================
-- dim_month v2 reads start/end dates dynamically from staging:
--   start = MIN(dev_start_date) across all techs in latest run
--   end   = MAX(end_of_useful_life_date) across all techs in latest run
-- This means any scenario (different construction start, longer useful life)
-- automatically rebuilds the calendar correctly on next run.
-- =============================================================================


-- =============================================================================
-- PART 1: dim_time.dim_year
-- Annual spine for pro forma data (v6_raw_lcoe_calcs has year-level rows)
-- Covers same range as dim_month — driven by same dynamic dates
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.dim_time.dim_year` AS

WITH

-- Dynamic date range from latest staging run
date_bounds AS (
  SELECT
    MIN(dev_start_date)          AS calendar_start,
    MAX(end_of_useful_life_date) AS calendar_end
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

-- Generate one row per year from first dev_start year to last EoUL year
spine AS (
  SELECT
    yr AS calendar_year
  FROM UNNEST(
    GENERATE_ARRAY(
      EXTRACT(YEAR FROM (SELECT calendar_start FROM date_bounds)),
      EXTRACT(YEAR FROM (SELECT calendar_end   FROM date_bounds))
    )
  ) AS yr
)

SELECT
  calendar_year,

  -- Year start and end dates
  DATE(calendar_year, 1, 1)                         AS year_start_date,
  DATE(calendar_year, 12, 31)                       AS year_end_date,

  -- Row number from first year (1 = first dev year)
  ROW_NUMBER() OVER (ORDER BY calendar_year)        AS year_seq,

  -- Years since first dev start
  calendar_year
    - EXTRACT(YEAR FROM (SELECT calendar_start FROM date_bounds))
                                                    AS years_since_dev_start,

  -- Decade grouping (useful for long-horizon pro forma views)
  CAST(FLOOR(calendar_year / 10) * 10 AS INT64)     AS decade,

  -- Source date range used to build this table (for auditability)
  (SELECT calendar_start FROM date_bounds)          AS built_from_start_date,
  (SELECT calendar_end   FROM date_bounds)          AS built_from_end_date,
  CURRENT_TIMESTAMP()                               AS dim_created_at

FROM spine
ORDER BY calendar_year;


-- =============================================================================
-- PART 2: dim_time.dim_month (v2 — flexible dates)
-- Replaces hardcoded DATE '2024-01-31' and DATE '2071-12-31'
-- Start = LAST_DAY of month containing MIN(dev_start_date)
-- End   = LAST_DAY of month containing MAX(end_of_useful_life_date)
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.dim_time.dim_month` AS

WITH

-- Dynamic date range
date_bounds AS (
  SELECT
    LAST_DAY(MIN(dev_start_date), MONTH)          AS calendar_start,
    LAST_DAY(MAX(end_of_useful_life_date), MONTH) AS calendar_end
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

spine AS (
  SELECT
    LAST_DAY(month_start, MONTH) AS calendar_month_end
  FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE_TRUNC((SELECT calendar_start FROM date_bounds), MONTH),
      DATE_TRUNC((SELECT calendar_end   FROM date_bounds), MONTH),
      INTERVAL 1 MONTH
    )
  ) AS month_start
)

SELECT
  calendar_month_end,
  EXTRACT(YEAR  FROM calendar_month_end)            AS calendar_year,
  EXTRACT(MONTH FROM calendar_month_end)            AS calendar_month_num,
  FORMAT_DATE('%b', calendar_month_end)             AS calendar_month_abbr,
  FORMAT_DATE('%Y-%m', calendar_month_end)          AS year_month,
  ROW_NUMBER() OVER (ORDER BY calendar_month_end)   AS month_seq,
  DATE_DIFF(
    calendar_month_end,
    (SELECT calendar_start FROM date_bounds),
    MONTH
  )                                                 AS months_since_dev_start,
  CASE
    WHEN EXTRACT(MONTH FROM calendar_month_end) <= 6 THEN 'H1'
    ELSE 'H2'
  END                                               AS fiscal_half,
  CONCAT('Q', CAST(
    CEIL(EXTRACT(MONTH FROM calendar_month_end) / 3.0) AS INT64
  ))                                                AS calendar_quarter,

  -- Audit — what dates drove this calendar build
  (SELECT calendar_start FROM date_bounds)          AS built_from_start_date,
  (SELECT calendar_end   FROM date_bounds)          AS built_from_end_date,
  CURRENT_TIMESTAMP()                               AS dim_created_at

FROM spine
ORDER BY calendar_month_end;


-- =============================================================================
-- VALIDATION
-- =============================================================================

-- 1. dim_year: confirm row count, range, year_seq
SELECT
  COUNT(*)                                          AS total_years,
  MIN(calendar_year)                                AS first_year,
  MAX(calendar_year)                                AS last_year,
  MIN(built_from_start_date)                        AS driven_by_start,
  MIN(built_from_end_date)                          AS driven_by_end
FROM `sandbox-lakehouse.dim_time.dim_year`;
-- Expected: 48 years, 2024-2071, driven_by_start=2024-01-31, driven_by_end=2064-09-30

-- 2. dim_month v2: confirm row count and date range unchanged from v1
SELECT
  COUNT(*)                                          AS total_months,
  MIN(calendar_month_end)                           AS first_month,
  MAX(calendar_month_end)                           AS last_month,
  MIN(built_from_start_date)                        AS driven_by_start,
  MIN(built_from_end_date)                          AS driven_by_end
FROM `sandbox-lakehouse.dim_time.dim_month`;
-- Expected: 576 rows, 2024-01-31 to 2071-12-31 (same as v1 — confirms dynamic = hardcoded for this run)

-- 3. dim_year: confirm joins cleanly to v6_raw_lcoe_calcs
--    (Pre-filters latest run in a CTE — BigQuery does not allow a subquery
--     with a table reference inside a JOIN predicate.)
WITH latest_lcoe AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_lcoe_calcs`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_lcoe_calcs`
    ORDER BY pushed_at DESC LIMIT 1
  )
)
SELECT
  d.calendar_year,
  d.year_seq,
  COUNT(l.technology) AS lcoe_rows
FROM `sandbox-lakehouse.dim_time.dim_year` d
LEFT JOIN latest_lcoe l
  ON l.year = d.calendar_year
GROUP BY 1, 2
ORDER BY 1
LIMIT 10;
-- Expected: years 2024-2033, each with lcoe_rows > 0 for active tech years
