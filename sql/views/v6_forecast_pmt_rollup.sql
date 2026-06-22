-- =============================================================================
-- v6_forecast_pmt_rollup
-- Polaris V6 - Forecast Views Layer
-- Source: stg_finance.v6_stg_forecast_inputs
--
-- PURPOSE:
-- Mid-level forecast aggregation. One row per
--   (run_id, technology, pmt_bucket, forecast_date)
-- with summed monthly_spend_usd. Buckets are derived from the integer prefix of
-- acct_code (e.g. "1.30 - Title Discovery/Resolution" -> prefix 1 -> Land & Title).
--
-- BUCKETING (acct_code prefix integer -> pmt_bucket):
--    1 -> Land & Title
--    2 -> Legal
--    3 -> Permitting & Environmental
--    4 -> Interconnection
--    5 -> Deposits & Marketing
--    6 -> Finance & Credit
--    7 -> EPC - Other
--    9 -> DSA & G&A
--   10 -> Engineering
--   11 -> Equipment              (Modules, Transformers, Batteries, Turbines, Breakers, Water)
--   13 -> Construction
--   14 -> Operations             (pre-COD opex per Jim D.)
--   15 -> Solar EPC              (PV Procurement, PV HV, PV Transmission)
--   16 -> BESS EPC
--   18 -> Wind EPC
--   22 -> Gas EPC                (Generator, BOS, Emissions Controls, Commissioning)
--
-- USE WHEN:
--   - Building a PMT-style summary that aggregates related cost codes
--   - Comparing tech-mix at a category level across runs
-- =============================================================================

CREATE OR REPLACE VIEW `sandbox-lakehouse.stg_finance.v6_forecast_pmt_rollup` AS

WITH bucketed AS (
  SELECT
    run_id,
    run_label,
    run_type,
    project_id,
    technology,
    forecast_date,
    monthly_spend_usd,
    CAST(REGEXP_EXTRACT(acct_code, r'^(\d+)\.') AS INT64) AS acct_prefix
  FROM `sandbox-lakehouse.stg_finance.v6_stg_forecast_inputs`
)

SELECT
  run_id,
  run_label,
  run_type,
  project_id,
  technology,
  forecast_date,
  CASE acct_prefix
    WHEN  1 THEN 'Land & Title'
    WHEN  2 THEN 'Legal'
    WHEN  3 THEN 'Permitting & Environmental'
    WHEN  4 THEN 'Interconnection'
    WHEN  5 THEN 'Deposits & Marketing'
    WHEN  6 THEN 'Finance & Credit'
    WHEN  7 THEN 'EPC - Other'
    WHEN  9 THEN 'DSA & G&A'
    WHEN 10 THEN 'Engineering'
    WHEN 11 THEN 'Equipment'
    WHEN 13 THEN 'Construction'
    WHEN 14 THEN 'Operations'
    WHEN 15 THEN 'Solar EPC'
    WHEN 16 THEN 'BESS EPC'
    WHEN 18 THEN 'Wind EPC'
    WHEN 22 THEN 'Gas EPC'
    ELSE        'UNCLASSIFIED'
  END AS pmt_bucket,
  acct_prefix,
  SUM(monthly_spend_usd) AS monthly_spend_usd
FROM bucketed
GROUP BY
  run_id, run_label, run_type, project_id,
  technology, forecast_date, acct_prefix;
