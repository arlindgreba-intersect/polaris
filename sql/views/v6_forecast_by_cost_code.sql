-- =============================================================================
-- v6_forecast_by_cost_code
-- Polaris V6 - Forecast Views Layer
-- Source: stg_finance.v6_stg_forecast_inputs
--
-- PURPOSE:
-- Most-detailed forecast aggregation. One row per
--   (run_id, technology, acct_code, forecast_date)
-- with summed monthly_spend_usd. This is the lowest-level rollup that drops the
-- vendor / budget_item / source_row detail but keeps the full acct_code grain.
--
-- USE WHEN:
--   - You need to slice forecast spend by full account code (1.10, 2.99, 22.30…)
--   - You're building a custom Looker drill-down at acct_code grain
--   - You want to validate roll-ups in v6_forecast_pmt_rollup / lcoe_capex_inputs
--
-- ACCT_CODE GROUPING NOTE:
--   Grouping is by raw acct_code STRING. Two acct_code text values that differ
--   only by case (e.g. "13.50 - Owner Construction" vs "13.50 - Owner construction"
--   in the Solar tab) remain as separate rows here. That is intentional: this view
--   surfaces the source data exactly as ingested. The two higher-level views
--   collapse the duplicates via prefix-integer bucketing.
-- =============================================================================

CREATE OR REPLACE VIEW `sandbox-lakehouse.stg_finance.v6_forecast_by_cost_code` AS
SELECT
  run_id,
  run_label,
  run_type,
  project_id,
  technology,
  acct_code,
  forecast_date,
  SUM(monthly_spend_usd) AS monthly_spend_usd,
  COUNT(*)                AS source_line_count
FROM `sandbox-lakehouse.stg_finance.v6_stg_forecast_inputs`
GROUP BY
  run_id, run_label, run_type, project_id,
  technology, acct_code, forecast_date;
