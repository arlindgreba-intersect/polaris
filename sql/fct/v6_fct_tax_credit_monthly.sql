-- =============================================================================
-- Polaris V6 — fct_finance.tax_credit_monthly
-- One row per technology per calendar month
-- ITC fires as a NEGATIVE cost (benefit) in the single month of substantial_completion_date
-- Solar/Wind/BESS receive ITC (net_itc_usd from silver, sign-flipped to negative)
-- Gas/DTC receive zero ITC
-- Source: mart_finance.v6_silver_itc_inputs joined to fct_finance.project_timeline_monthly
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.tax_credit_monthly` AS
WITH
latest_itc AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  ORDER BY pushed_at DESC LIMIT 1
),
itc AS (
  SELECT
    technology,
    net_itc_usd,
    substantial_completion_date,
    run_id
  FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  WHERE run_id = (SELECT run_id FROM latest_itc)
),
timeline AS (
  SELECT
    calendar_month_end,
    technology,
    run_id
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
  COALESCE(i.run_id, t.run_id) AS run_id
FROM timeline t
LEFT JOIN itc i ON i.technology = t.technology
ORDER BY t.technology, t.calendar_month_end;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Lifetime ITC per technology + months that fire
SELECT
  technology,
  ROUND(SUM(itc_benefit_usd), 2)   AS lifetime_itc,
  COUNTIF(itc_benefit_usd <> 0)    AS months_with_itc
FROM `sandbox-lakehouse.fct_finance.tax_credit_monthly`
GROUP BY technology
ORDER BY technology;
-- Expected: Solar/Wind/BESS each fire once with negative value matching silver.net_itc_usd;
--           Gas/DTC zero.

-- 2. Tie-out: |sum(itc_benefit_usd)| must equal silver.net_itc_usd per technology
WITH
fct_itc AS (
  SELECT technology, ABS(SUM(itc_benefit_usd)) AS fct_lifetime_itc
  FROM `sandbox-lakehouse.fct_finance.tax_credit_monthly`
  GROUP BY technology
),
silver_itc AS (
  SELECT technology, net_itc_usd
  FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs`
    ORDER BY pushed_at DESC LIMIT 1
  )
)
SELECT
  COALESCE(f.technology, s.technology) AS technology,
  ROUND(s.net_itc_usd, 2)              AS silver_net_itc_usd,
  ROUND(f.fct_lifetime_itc, 2)         AS fct_lifetime_itc_abs,
  ROUND(COALESCE(f.fct_lifetime_itc, 0) - COALESCE(s.net_itc_usd, 0), 2) AS diff
FROM fct_itc f
FULL OUTER JOIN silver_itc s USING(technology)
ORDER BY technology;
-- Expected: diff = 0 for all 5 technologies.