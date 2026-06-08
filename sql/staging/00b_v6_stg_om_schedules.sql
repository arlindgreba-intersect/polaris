-- =============================================================================
-- NEW: v6_stg_om_schedules
-- Polaris V6 - Staging Layer
-- Source: v6_raw_opex_tool (pushed by AppScript v6_pushOpexTool)
--
-- WHY THIS EXISTS:
-- O&M & Asset Management costs (Covered O&M, Non-Covered O&M, Asset Management,
-- Major Maintenance) are calculated in the Opex_Tool, NOT entered in the Inputs tab.
-- They are NOT in v6_raw_inputs_tab. They live in v6_raw_opex_tool as rows with:
--   row_label = 'Covered O&M' / 'Non-Covered O&M' / 'Asset Management' etc.
--   row_type  = 'calculated'
--   total_value = lifetime total USD (col F in Opex_Tool)
--   period_* cols = actual monthly values with escalation built in
--
-- This staging table extracts the O&M total by tech so the fct opex model
-- can spread it over the operating timeline.
--
-- Row locations in Opex_Tool (confirmed from Case 8 workbook):
--   Solar:  Covered R52, Non-Covered R53, Asset Mgmt R54, Major Maint R55, Total R56
--   Wind:   Covered R129, Non-Covered R130, Asset Mgmt R131, Major Maint R132, Total R133
--   BESS:   Covered R203, Non-Covered R204, Asset Mgmt R205, Major Maint R206, Total R207
--   Gas:    Generator Fixed O&M R272, Generator Variable O&M R273, Total captured via total_value
--   DTC:    No O&M rows (OI-009 pending Ted Mongan)
--
-- OPEN ISSUES:
--   OI-009: BESS Covered O&M = 0 (pending Brad Platt)
--   OI-009: DTC Covered O&M = 0 (pending Ted Mongan)
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_om_schedules` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_opex_tool`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
    ORDER BY pushed_at DESC LIMIT 1
  )
  AND row_type = 'calculated'
  AND row_label IN (
    'Covered O&M',
    'Non-Covered O&M',
    'Asset Management',
    'Major Maintenance',
    'O&M & Asset Management',
    'Generator Fixed O&M',
    'Generator Variable O&M'
  )
  AND technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  run_id,
  pushed_at,
  run_label,
  run_type,
  technology,

  -- O&M components — lifetime totals from Opex_Tool col F (total_value)
  MAX(CASE WHEN row_label = 'Covered O&M'              THEN SAFE_CAST(total_value AS FLOAT64) END) AS covered_om_lifetime_usd,
  MAX(CASE WHEN row_label = 'Non-Covered O&M'          THEN SAFE_CAST(total_value AS FLOAT64) END) AS non_covered_om_lifetime_usd,
  MAX(CASE WHEN row_label = 'Asset Management'         THEN SAFE_CAST(total_value AS FLOAT64) END) AS asset_mgmt_lifetime_usd,
  MAX(CASE WHEN row_label = 'Major Maintenance'        THEN SAFE_CAST(total_value AS FLOAT64) END) AS major_maintenance_lifetime_usd,
  MAX(CASE WHEN row_label = 'O&M & Asset Management'   THEN SAFE_CAST(total_value AS FLOAT64) END) AS total_om_lifetime_usd,
  -- Gas-specific O&M (Fixed + Variable replaces Covered/Non-Covered for Gas)
  MAX(CASE WHEN row_label = 'Generator Fixed O&M'      THEN SAFE_CAST(total_value AS FLOAT64) END) AS gas_fixed_om_lifetime_usd,
  MAX(CASE WHEN row_label = 'Generator Variable O&M'   THEN SAFE_CAST(total_value AS FLOAT64) END) AS gas_variable_om_lifetime_usd,

  CURRENT_TIMESTAMP() AS stg_created_at

FROM src
GROUP BY run_id, pushed_at, run_label, run_type, technology;

