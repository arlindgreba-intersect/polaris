Master V6 Staging query
-- =============================================================================
-- Polaris — Roman III LCOE Model V6
-- Consolidated Staging SQL — v4 (correct dataset: stg_finance)
-- =============================================================================
-- Section names actually written by Apps Script to v6_raw_inputs_tab:
--   'LCOE Drivers'                  R3-R10
--   'Dates'                         R13-R21
--   'Capacities & Performance'      R23-R47  (seasonality R34-R45, deg R46-R47)
--   'Tax Attributes'                R49-R97  (ITC eligibility R50-R67)
--   'Underwriting & Financing Fees' R99-R103
--   'CAPEX'                         R109-R152  NOTE: contingency R124-R127 also
--                                              landed here due to config offset
--   'OPEX'                          R154-R215 (land lease, insurance, prop tax,
--                                              franchise tax, sleeve fee, op LCs)
--   'Other Expenses'                R216-R336
--   'Gas-Specific OPEX'             R338-R356
--   'DTC-Specific OPEX'             R358-R368
--
-- KEY FIELD MAPPINGS in v6_raw_capex_tool:
--   row_label    = col C  (null on Total CAPEX rows — text is in col B)
--   dollar_per_unit = col D  (holds Total CAPEX $ on total rows)
--   row_type     = 'total' on Total CAPEX rows
--
-- BUILD ORDER: run 1 → 18 in sequence.
-- OPEN ISSUES flagged with -- ⚠️ OI-XXX
-- =============================================================================


-- =============================================================================
-- 1. v6_stg_lcoe_model_controls
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_lcoe_model_controls` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
    ORDER BY pushed_at DESC LIMIT 1
  )
),
pivoted AS (
  SELECT
    MAX(CASE WHEN input_name = 'Discount Rate'                                          THEN value_num END) AS discount_rate,
    MAX(CASE WHEN input_name = 'Monetization Switch (ITC=0, PTC=1)' AND technology = 'Solar' THEN value_num END) AS solar_itc_ptc_switch,
    MAX(CASE WHEN input_name = 'Monetization Switch (ITC=0, PTC=1)' AND technology = 'Wind'  THEN value_num END) AS wind_itc_ptc_switch,
    MAX(CASE WHEN input_name = 'Monetization Switch (ITC=0, PTC=1)' AND technology = 'Gas'   THEN value_num END) AS gas_itc_ptc_switch,
    MAX(CASE WHEN input_name = 'Monetization Switch (ITC=0, PTC=1)' AND technology = 'BESS'  THEN value_num END) AS bess_itc_ptc_switch,
    MAX(CASE WHEN input_name = '100% Bonus Depreciation'             AND technology = 'Gas'   THEN value_num END) AS gas_bonus_dep_switch,
    MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'     AND technology = 'Solar' THEN value_num END) AS solar_tech_switch,
    MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'     AND technology = 'Wind'  THEN value_num END) AS wind_tech_switch,
    MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'     AND technology = 'Gas'   THEN value_num END) AS gas_tech_switch,
    MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'     AND technology = 'BESS'  THEN value_num END) AS bess_tech_switch,
    MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'     AND technology = 'DTC'   THEN value_num END) AS dtc_tech_switch,
    MAX(pushed_at)   AS pushed_at,
    MAX(run_id)      AS run_id,
    MAX(run_label)   AS run_label,
    MAX(run_type)    AS run_type,
    MAX(snapshot_id) AS snapshot_id,
    MAX(model_name)  AS model_name
  FROM src
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type,
  discount_rate,
  solar_tech_switch, wind_tech_switch, gas_tech_switch, bess_tech_switch, dtc_tech_switch,
  solar_itc_ptc_switch, wind_itc_ptc_switch, gas_itc_ptc_switch, bess_itc_ptc_switch,
  gas_bonus_dep_switch,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM pivoted;


-- =============================================================================
-- 2. v6_stg_project_timeline
--    ⚠️ OI-001:  Gas/BESS/DTC Const Start = 2027-03-31 (Inputs) vs 2026-09-30 (Registry)
--    ⚠️ OI-001c: Dev Start = 2024-01-31 (Inputs) vs 2023-01-31 (Sign Off Sheet)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_project_timeline` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Dates'
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Development Start Date'           THEN DATE(value_date) END) AS dev_start_date,
  MAX(CASE WHEN input_name = 'Construction Start Date'          THEN DATE(value_date) END) AS construction_start_date,
  MAX(CASE WHEN input_name = 'Substantial Completion'           THEN DATE(value_date) END) AS substantial_completion_date,
  MAX(CASE WHEN input_name = 'End of Useful Life'               THEN DATE(value_date) END) AS end_of_useful_life_date,
  MAX(CASE WHEN input_name = 'Placed in Service Date'           THEN DATE(value_date) END) AS placed_in_service_date,
  MAX(CASE WHEN input_name = 'Useful Life in Years'             THEN value_num        END) AS useful_life_years,
  MAX(CASE WHEN input_name = 'Technology Switch (1=On; 0=Off)'  THEN value_num        END) AS tech_switch,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 3. v6_stg_project_capacity
--    ⚠️ OI-001b: DTC = 1095 MW (Inputs) vs 840 MW (Registry)
--    ⚠️ OI-010:  Wind nameplate = 643.86; net POI = 630. Both captured.
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_project_capacity` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Capacities & Performance'
  AND source_row BETWEEN 24 AND 31
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Installed Capacity'        THEN value_num END) AS installed_capacity_mw,
  MAX(CASE WHEN input_name = 'Capacity at POI'           THEN value_num END) AS capacity_at_poi_mw,
  MAX(CASE WHEN input_name = 'Number of Turbines'        THEN value_num END) AS turbine_count,
  MAX(CASE WHEN input_name = 'Y1 Generation'             THEN value_num END) AS y1_generation_mwh,
  MAX(CASE WHEN input_name = 'Specific Production'       THEN value_num END) AS specific_production,
  MAX(CASE WHEN input_name = 'Storage Duration'          THEN value_num END) AS storage_duration_hrs,
  MAX(CASE WHEN input_name = 'DTC Reliability'           THEN value_num END) AS dtc_reliability,
  MAX(CASE WHEN input_name = 'DTC Carbon-free Energy %'  THEN value_num END) AS dtc_cfe_pct,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 4. v6_stg_generation_seasonality
--    R34-R45 inside 'Capacities & Performance'. input_name = month number (1-12).
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_generation_seasonality` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Capacities & Performance'
  AND source_row BETWEEN 34 AND 45
  AND value_num IS NOT NULL
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  CAST(input_name AS INT64) AS month_number,
  value_num                  AS seasonality_factor,
  CURRENT_TIMESTAMP()        AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas')
  AND SAFE_CAST(input_name AS INT64) BETWEEN 1 AND 12;


-- =============================================================================
-- 5. v6_stg_degradation
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_degradation` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND input_name IN ('Cumulative Deg. at UL', 'First Year BESS Deg.')
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Cumulative Deg. at UL'  THEN value_num END) AS cumulative_degradation_at_ul,
  MAX(CASE WHEN input_name = 'First Year BESS Deg.'   THEN value_num END) AS first_year_bess_degradation,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 6. v6_stg_tax_attributes
--    'Tax Attributes' R49-R97 includes ITC eligibility rows R50-R67
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_tax_attributes` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Tax Attributes'
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'ITC Eligibility %'                    THEN value_num  END) AS itc_eligibility_pct,
  MAX(CASE WHEN input_name = 'ITC Rate'                             THEN value_num  END) AS itc_rate,
  MAX(CASE WHEN input_name = 'Effective Tax Rate'                   THEN value_num  END) AS effective_tax_rate,
  MAX(CASE WHEN input_name = 'ITCs or PTCs Transferred'             THEN value_num  END) AS itc_ptc_transferred,
  MAX(CASE WHEN input_name = 'ITC or PTC Transfer Price'            THEN value_num  END) AS itc_ptc_transfer_price,
  MAX(CASE WHEN input_name = '100% Bonus Depreciation'              THEN value_num  END) AS bonus_dep_switch,
  MAX(CASE WHEN input_name = '5-Yr MACRS Basis'                     THEN value_num  END) AS five_yr_macrs_basis,
  MAX(CASE WHEN input_name = '20-Yr MACRS Basis'                    THEN value_num  END) AS twenty_yr_macrs_basis,
  MAX(CASE WHEN input_name = 'PTC End Date'                         THEN value_date END) AS ptc_end_date,
  MAX(CASE WHEN input_name = 'PTC Index Year'                       THEN value_num  END) AS ptc_index_year,
  MAX(CASE WHEN input_name = 'CPI'                                  THEN value_num  END) AS ptc_cpi,
  MAX(CASE WHEN input_name = 'PTC Base Rate'                        THEN value_num  END) AS ptc_base_rate,
  MAX(CASE WHEN input_name = 'PTC Eligibility'                      THEN value_num  END) AS ptc_eligibility,
  MAX(CASE WHEN input_name = 'PTC / MWh Generation'                 THEN value_num  END) AS ptc_per_mwh,
  MAX(CASE WHEN input_name = 'PTC Transfer Price'                   THEN value_num  END) AS ptc_transfer_price,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 7. v6_stg_financing_fees
--    'Underwriting & Financing Fees' R99-R103
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_financing_fees` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Underwriting & Financing Fees'
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Underwriting Fee'                        THEN value_num END) AS underwriting_fee_usd,
  MAX(CASE WHEN input_name = 'Transfer Transaction Cost (incl. Legal)' THEN value_num END) AS transfer_transaction_cost_usd,
  MAX(CASE WHEN input_name = 'Transfer Upfront Fee'                    THEN value_num END) AS transfer_upfront_fee_pct,
  MAX(CASE WHEN input_name = 'Transfer ITC Insurance'                  THEN value_num END) AS transfer_itc_insurance_pct,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 8. v6_stg_contingency
--    NOTE: Contingency rows R124-R127 landed in section='CAPEX' due to Apps Script
--    section boundary config (Contingency config was R105-R107 but actual rows
--    are R124-R127 in V6). Filter by source_row instead.
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_contingency` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND source_row BETWEEN 124 AND 127
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Date of CAPEX Contingency Adder' THEN value_date END) AS capex_contingency_date,
  MAX(CASE WHEN input_name = 'CAPEX Contingency Amount'        THEN value_num  END) AS capex_contingency_usd,
  MAX(CASE WHEN input_name = 'Opex Contingency'                THEN value_num  END) AS opex_contingency_pct,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 9. v6_stg_capex_unit_cost
--    $/W components from Inputs tab R133-R152
--    Total CapEx from v6_raw_capex_tool: row_type='total', value in dollar_per_unit
--    (row_label is NULL on Total CAPEX rows — text was in col B which maps to adder_value)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_capex_unit_cost` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'CAPEX'
  AND source_row BETWEEN 133 AND 152
  AND value_num IS NOT NULL
  AND input_name NOT IN ('$/W Baseline Input in CAPEX Tool','Latest Actuals Date','Placeholders','CAPEX')
),

capex_totals AS (
  -- CORRECTED: match run_id from v6_raw_inputs_tab to ensure same push
  -- is used across both raw tables. Prevents silver fan-out from mixed runs.
  SELECT
    technology,
    SAFE_CAST(total_usd AS FLOAT64) AS total_capex_usd
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_capex_tool`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_capex_tool` ORDER BY pushed_at DESC LIMIT 1)
    AND row_type = 'total'
    AND technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.technology,
  s.input_name        AS component,
  s.value_num         AS dollar_per_w,
  ct.total_capex_usd,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src s
LEFT JOIN capex_totals ct ON s.technology = ct.technology
WHERE s.technology IN ('Solar','Wind','Gas','BESS','DTC');


-- =============================================================================
-- 10. v6_stg_opex_rates
--     'OPEX' section: land lease, franchise tax, sleeve fee
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_opex_rates` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'OPEX'
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Toggle (Scheduled=1; Calculated=0)'                   THEN value_num END) AS land_lease_toggle,
  MAX(CASE WHEN input_name = 'Average $ / Acre'                                     THEN value_num END) AS land_lease_dollar_per_acre,
  MAX(CASE WHEN input_name = 'Total Acres'                                           THEN value_num END) AS land_lease_total_acres,
  MAX(CASE WHEN input_name = 'Annual Escalator' AND source_row BETWEEN 157 AND 161  THEN value_num END) AS land_lease_escalator,
  MAX(CASE WHEN input_name = '% of Revenue'                                         THEN value_num END) AS franchise_tax_pct_revenue,
  MAX(CASE WHEN input_name = '$/MWh'                                                THEN value_num END) AS sleeve_fee_dollar_per_mwh,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 11. v6_stg_insurance
--     'OPEX' section source_row 163-166
--     ⚠️ OI-008: DTC insurance blank (Anoop)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_insurance` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'OPEX'
  AND source_row BETWEEN 163 AND 166
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Replacement Cost'                        THEN value_num END) AS replacement_cost_usd,
  MAX(CASE WHEN input_name = 'Estimated Yr1 Revenues'                  THEN value_num END) AS yr1_revenue_usd,
  MAX(CASE WHEN input_name = 'Premium Per Replacement Cost + Revenues' THEN value_num END) AS premium_rate,
  MAX(CASE WHEN input_name = 'Annual Premium'                          THEN value_num END) AS annual_premium_usd,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 12. v6_stg_property_tax
--     'OPEX' section source_row 169-176
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_property_tax` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'OPEX'
  AND source_row BETWEEN 169 AND 176
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'COD Year'                        THEN value_num END) AS cod_year,
  MAX(CASE WHEN input_name = 'Abatement Start Year (Accruals)' THEN value_num END) AS abatement_start_year,
  MAX(CASE WHEN input_name = 'Abatement Tenor (Years)'         THEN value_num END) AS abatement_tenor_years,
  MAX(CASE WHEN input_name = 'Project Basis at SC'             THEN value_num END) AS project_basis_at_sc_usd,
  MAX(CASE WHEN input_name = 'Total Millage Rate'              THEN value_num END) AS total_millage_rate,
  MAX(CASE WHEN input_name = 'Millage Rate during Abatement'   THEN value_num END) AS millage_rate_abatement,
  MAX(CASE WHEN input_name = 'Annual Abatement Payment'        THEN value_num END) AS annual_abatement_payment_usd,
  MAX(CASE WHEN input_name = 'Annual AG Value Lost Payment'    THEN value_num END) AS annual_ag_value_lost_usd,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 13. v6_stg_franchise_tax
--     'OPEX' section source_row 179
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_franchise_tax` AS

SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  value_num           AS franchise_tax_pct_revenue,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
AND section = 'OPEX'
AND source_row = 179
AND technology IN ('Solar','Wind','Gas','BESS','DTC');


-- =============================================================================
-- 14. v6_stg_land_lease
--     'OPEX' section source_row 157-161
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_land_lease` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'OPEX'
  AND source_row BETWEEN 157 AND 161
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology,
  MAX(CASE WHEN input_name = 'Toggle (Scheduled=1; Calculated=0)' THEN value_num END) AS toggle_scheduled,
  MAX(CASE WHEN input_name = 'Average $ / Acre'                   THEN value_num END) AS dollar_per_acre,
  MAX(CASE WHEN input_name = 'Total Acres'                        THEN value_num END) AS total_acres,
  MAX(CASE WHEN input_name = 'Annual Escalator'                   THEN value_num END) AS annual_escalator,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type, technology;


-- =============================================================================
-- 15. v6_stg_other_expenses
--     'Other Expenses' R216-R336, line items 1-21
--     row_type for header rows may not be 'line_item_header' — use input_name match instead
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_other_expenses` AS

WITH src_raw AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Other Expenses'
),

-- Fill line_item_num down from header rows to data rows within each tech block
src AS (
  SELECT *,
    LAST_VALUE(line_item_num IGNORE NULLS) OVER (
      PARTITION BY technology ORDER BY source_row
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS filled_item_num
  FROM src_raw
),

expense_names AS (
  SELECT technology, filled_item_num AS line_item_num,
    value_raw AS expense_name,
    CASE WHEN input_name = 'Useful Life Expense' THEN 'useful_life'
         WHEN input_name = 'Fixed-term Expense'  THEN 'fixed_term'
         ELSE 'other' END AS expense_type
  FROM src
  WHERE input_name IN ('Useful Life Expense','Fixed-term Expense','Expense')
    AND filled_item_num IS NOT NULL
)

SELECT
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.technology, s.filled_item_num AS line_item_num,
  en.expense_name, en.expense_type,
  MAX(CASE WHEN s.input_name = 'Year 1 Rate'               THEN s.value_num  END) AS yr1_rate,
  MAX(CASE WHEN s.input_name = 'Unit'                      THEN s.value_raw  END) AS unit,
  MAX(CASE WHEN s.input_name = 'Annual Escalation'         THEN s.value_num  END) AS annual_escalation,
  MAX(CASE WHEN s.input_name = 'Hardcode Override = 0'     THEN s.value_num  END) AS hardcode_override,
  MAX(CASE WHEN s.input_name = 'Start Date'                THEN s.value_date END) AS start_date,
  MAX(CASE WHEN s.input_name = 'End Date'                  THEN s.value_date END) AS end_date,
  MAX(CASE WHEN s.input_name = 'Fixed Amount=1; Monthly=0' THEN s.value_num  END) AS fixed_amount_flag,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src s
LEFT JOIN expense_names en
  ON s.technology = en.technology
  AND s.filled_item_num = en.line_item_num
WHERE s.technology IN ('Solar','Wind','Gas','BESS','DTC')
  AND s.filled_item_num IS NOT NULL
  AND s.input_name NOT IN ('Useful Life Expense','Fixed-term Expense','Expense')
GROUP BY
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.technology, s.filled_item_num, en.expense_name, en.expense_type;


-- =============================================================================
-- 16. v6_stg_gas_opex
--     'Gas-Specific OPEX' R338-R356
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_gas_opex` AS

WITH src AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'Gas-Specific OPEX'
  AND technology = 'Gas'
  AND value_num IS NOT NULL
)
SELECT
  run_id, snapshot_id, model_name, pushed_at, run_label, run_type,
  MAX(CASE WHEN input_name = 'Use Generic Fuel Price (No=0, Yes=1)'         THEN value_num END) AS use_generic_fuel_price,
  MAX(CASE WHEN input_name = 'Generic Fuel Price / MMBTU'                   THEN value_num END) AS generic_fuel_price_per_mmbtu,
  MAX(CASE WHEN input_name = 'Generic Fuel Price / MMBTU Annual Escalation' THEN value_num END) AS fuel_price_escalation,
  MAX(CASE WHEN input_name = 'MMBTU per MWh'                                THEN value_num END) AS mmbtu_per_mwh,
  MAX(CASE WHEN input_name = 'Fuel Adder'                                   THEN value_num END) AS fuel_adder,
  MAX(CASE WHEN input_name = 'Fuel Price Adder (Commodity + ACA)'           THEN value_num END) AS fuel_price_adder,
  MAX(CASE WHEN input_name = 'Trunk Line FT Volume - MMBTU/Day'             THEN value_num END) AS trunk_ft_volume_mmbtu_day,
  MAX(CASE WHEN input_name = 'Lateral FT Volume - MMBTU/Day'                THEN value_num END) AS lateral_ft_volume_mmbtu_day,
  MAX(CASE WHEN input_name = 'Trunk Line Reservation $/MMBTU/Day'           THEN value_num END) AS trunk_reservation_rate,
  MAX(CASE WHEN input_name = 'Lateral Reservation $/MMBTU/Day'              THEN value_num END) AS lateral_reservation_rate,
  MAX(CASE WHEN input_name = 'Trunk Line Escalator (%)'                     THEN value_num END) AS trunk_escalator,
  MAX(CASE WHEN input_name = 'Lateral Escalator (%)'                        THEN value_num END) AS lateral_escalator,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src
GROUP BY run_id, snapshot_id, model_name, pushed_at, run_label, run_type;


-- =============================================================================
-- 17. v6_stg_dtc_opex
--     'DTC-Specific OPEX' R358-R368
--     expense_name resolved via MIN(source_row) per line_item block
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_dtc_opex` AS

WITH src_raw AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'DTC-Specific OPEX'
  AND technology = 'DTC'
),

-- Fill line_item_num down from header row to data rows
src AS (
  SELECT *,
    LAST_VALUE(line_item_num IGNORE NULLS) OVER (
      ORDER BY source_row
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS filled_item_num
  FROM src_raw
),

expense_names AS (
  SELECT filled_item_num AS line_item_num, value_raw AS expense_name
  FROM src
  WHERE input_name = 'Expense'
    AND filled_item_num IS NOT NULL
)

SELECT
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.filled_item_num                                              AS line_item_num,
  en.expense_name,
  MAX(CASE WHEN s.input_name = 'Year 1 Rate'           THEN s.value_num END) AS yr1_rate,
  MAX(CASE WHEN s.input_name = 'Unit'                  THEN s.value_raw END) AS unit,
  MAX(CASE WHEN s.input_name = 'Annual Escalation'     THEN s.value_num END) AS annual_escalation,
  MAX(CASE WHEN s.input_name = 'Hardcode Override = 0' THEN s.value_num END) AS hardcode_override,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src s
LEFT JOIN expense_names en ON s.filled_item_num = en.line_item_num
WHERE s.filled_item_num IS NOT NULL
  AND s.input_name NOT IN ('Expense')
GROUP BY s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type, s.filled_item_num, en.expense_name;


-- =============================================================================
-- 18. v6_stg_operating_lcs
--     'OPEX' section R184-R214, up to 5 LC slots per technology
--     lc_names join: uses input_name LIKE 'Operating LC%' without row_type filter
--     Wind LC #1 = $34,625,360 (2039-09-30 to 2059-09-30) is the only live value
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs` AS

WITH src_raw AS (
  SELECT *
  FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
  WHERE run_id = (SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab` ORDER BY pushed_at DESC LIMIT 1)
  AND section = 'OPEX'
  AND source_row BETWEEN 184 AND 214
),

-- Fill line_item_num down from LC header rows to data rows
src AS (
  SELECT *,
    LAST_VALUE(line_item_num IGNORE NULLS) OVER (
      PARTITION BY technology ORDER BY source_row
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS filled_item_num
  FROM src_raw
),

lc_names AS (
  SELECT technology, filled_item_num AS line_item_num, value_raw AS lc_label
  FROM src
  WHERE input_name LIKE 'Operating LC%'
    AND filled_item_num IS NOT NULL
)

SELECT
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.technology, s.filled_item_num AS line_item_num,
  ln.lc_label,
  MAX(CASE WHEN s.input_name = 'Start Period'  THEN s.value_date END) AS start_period,
  MAX(CASE WHEN s.input_name = 'End Period'    THEN s.value_date END) AS end_period,
  MAX(CASE WHEN s.input_name = 'Escalation'   THEN s.value_num  END) AS escalation,
  MAX(CASE WHEN s.input_name = 'LC Amount'    THEN s.value_num  END) AS lc_amount_usd,
  MAX(CASE WHEN s.input_name = 'LC Rate'      THEN s.value_num  END) AS lc_rate,
  CURRENT_TIMESTAMP() AS stg_created_at
FROM src s
LEFT JOIN lc_names ln
  ON s.technology       = ln.technology
  AND s.filled_item_num = ln.line_item_num
WHERE s.technology IN ('Solar','Wind','Gas','BESS','DTC')
  AND s.filled_item_num IS NOT NULL
  AND s.input_name NOT LIKE 'Operating LC%'
GROUP BY
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at, s.run_label, s.run_type,
  s.technology, s.filled_item_num, ln.lc_label;


-- =============================================================================
-- END v6_staging_consolidated.sql v3
-- =============================================================================
-- NOT YET BUILT (blocked or needs additional source ingestion):
--   v6_dim_month             — needs OI-001c (Dev Start) resolved
--   v6_stg_depreciation      — needs Schedules tab ingested (POL-R14)
--   v6_stg_opex_schedule     — needs Schedules tab ingested
--   v6_fct_project_timeline  — needs dim_month + OI-001 resolved
--   v6_fct_generation        — needs project_timeline_monthly
--   v6_fct_capex_monthly     — needs timeline + Jim D S-curve sign-off
--   v6_fct_opex_monthly      — needs timeline + OI-009
--   v6_fct_revenue_monthly   — OI-005 full blocker
--   v6_fct_lcoe_component    — needs all fct models above
--   v6_mart_lcoe_summary     — needs lcoe_component
-- =============================================================================