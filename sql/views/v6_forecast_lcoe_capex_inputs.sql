-- =============================================================================
-- v6_forecast_lcoe_capex_inputs
-- Polaris V6 - Forecast Views Layer
-- Source: stg_finance.v6_stg_forecast_inputs
--
-- PURPOSE:
-- Highest-level forecast aggregation — the shape Winston pastes into the LCOE
-- Google Sheet CAPEX tool. One row per
--   (run_id, technology, major_category, forecast_date)
-- with summed monthly_spend_usd plus an is_pre_cod_opex flag.
--
-- CAPEX vs OPEX (per Jim Domencich):
--   "The only opex in this tool is pre-COD opex; everything else is capex."
--   By that definition, every row in v6_stg_forecast_inputs is either capex or
--   pre-COD opex. The 14.xx (Operations) acct_codes ARE the pre-COD opex —
--   their presence in the forecast tool is what classifies them. Operating-
--   period O&M lives elsewhere (v6_stg_om_schedules / fct_finance.project_opex_monthly).
--
-- MAJOR CATEGORIES (acct_code prefix integer -> major_category, is_pre_cod_opex):
--    1,2,3,4,9 -> Development         | is_pre_cod_opex = FALSE  (capex)
--   10         -> Engineering          | FALSE
--   11,15,16,18,22 -> Equipment & Procurement | FALSE
--   7,13       -> Construction         | FALSE
--   5,6        -> Soft Costs - Finance | FALSE
--   14         -> Pre-COD Opex         | is_pre_cod_opex = TRUE
--
-- USE WHEN:
--   - You need the rolled-up CAPEX line items that get pasted into the LCOE
--     Google Sheet CAPEX tool
--   - You need a clean capex vs. pre-COD-opex split for FP&A reporting
-- =============================================================================

CREATE OR REPLACE VIEW `sandbox-lakehouse.stg_finance.v6_forecast_lcoe_capex_inputs` AS

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
  CASE
    WHEN acct_prefix IN (1, 2, 3, 4, 9)                 THEN 'Development'
    WHEN acct_prefix = 10                               THEN 'Engineering'
    WHEN acct_prefix IN (11, 15, 16, 18, 22)            THEN 'Equipment & Procurement'
    WHEN acct_prefix IN (7, 13)                         THEN 'Construction'
    WHEN acct_prefix IN (5, 6)                          THEN 'Soft Costs - Finance'
    WHEN acct_prefix = 14                               THEN 'Pre-COD Opex'
    ELSE 'UNCLASSIFIED'
  END                                AS major_category,
  (acct_prefix = 14)                 AS is_pre_cod_opex,
  SUM(monthly_spend_usd)             AS monthly_spend_usd
FROM bucketed
GROUP BY
  run_id, run_label, run_type, project_id,
  technology, forecast_date, major_category, is_pre_cod_opex;
