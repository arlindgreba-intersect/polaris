-- =============================================================================
-- NEW: v6_stg_opex_lifetime_totals
-- Polaris V6 - Staging Layer
-- Source: v6_raw_opex_tool
--
-- WHY THIS EXISTS:
-- The Opex_Tool calculates all opex components using internal schedules
-- (Percent Good depreciation for property tax, escalation curves for land lease,
-- premium basis for insurance, etc.). Rather than recreating these formulas
-- in SQL, we read the authoritative lifetime totals directly from col F.
--
-- This replaces rate-based calculations for:
--   - Land Lease (was: dollar_per_acre × acres × escalation — wrong due to toggle)
--   - Insurance (was: annual_premium × POWER(1+rate) — rate is not an escalator)
--   - Property Tax (was: basis × millage — wrong, uses Percent Good method)
--   - Other Expenses (was: yr1_rate × unit conversion — missing for some techs)
--   - O&M (already in v6_stg_om_schedules — kept separate)
--
-- Row locations in Opex_Tool (confirmed Case 8):
--   Solar:  Land Lease R49, Insurance R61, Prop Tax R71, Other Exp R115
--   Wind:   Land Lease R123, Insurance R138, Prop Tax R148, Other Exp R192
--   BESS:   Insurance R213, Prop Tax R223, Other Exp R267
--   Gas:    Insurance R285, Prop Tax R306 (O&M via om_schedules, fuel via OI-005)
--   DTC:    Prop Tax R338
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_opex_lifetime_totals` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_opex_tool`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
    ORDER BY pushed_at DESC LIMIT 1
  )
  AND row_type IN ('calculated', 'schedule_input', 'total')
  AND row_label IN (
    'Utilized Land Lease Costs',
    'Insurance',
    'Property Taxes',
    'Total Other Expenses',
    'Total Operating LCs',
    'Fuel OpEx',
    'Inputted Wake Losses'
  )
  AND technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  run_id,
  pushed_at,
  run_label,
  run_type,
  technology,
  MAX(CASE WHEN row_label = 'Utilized Land Lease Costs' THEN SAFE_CAST(total_value AS FLOAT64) END) AS land_lease_lifetime_usd,
  MAX(CASE WHEN row_label = 'Insurance'                 THEN SAFE_CAST(total_value AS FLOAT64) END) AS insurance_lifetime_usd,
  MAX(CASE WHEN row_label = 'Property Taxes'            THEN SAFE_CAST(total_value AS FLOAT64) END) AS property_tax_lifetime_usd,
  MAX(CASE WHEN row_label = 'Total Other Expenses'      THEN SAFE_CAST(total_value AS FLOAT64) END) AS other_exp_lifetime_usd,
  MAX(CASE WHEN row_label = 'Fuel OpEx'                  THEN SAFE_CAST(total_value AS FLOAT64) END) AS gas_fuel_lifetime_usd,
  MAX(CASE WHEN row_label = 'Inputted Wake Losses'       THEN SAFE_CAST(total_value AS FLOAT64) END) AS wake_losses_lifetime_usd,
  MAX(CASE WHEN row_label = 'Total Operating LCs'        THEN SAFE_CAST(total_value AS FLOAT64) END) AS operating_lcs_lifetime_usd,
  CURRENT_TIMESTAMP() AS stg_created_at

FROM src
GROUP BY run_id, pushed_at, run_label, run_type, technology;

