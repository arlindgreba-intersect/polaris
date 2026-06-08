v6 silver consolidated query
-- =============================================================================
-- Polaris — Roman III LCOE Model V6
-- Consolidated Silver Layer SQL — v2 (correct datasets: stg_finance → mart_finance)
-- File: v6_silver_consolidated.sql
-- =============================================================================
-- Silver sits between staging and fct. It joins and normalizes staging tables
-- into clean, calc-ready datasets — one row per technology (or per tech/month,
-- per tech/component, etc.) with all inputs a downstream fct model needs.
--
-- Sources: stg_finance.v6_stg_* tables
-- Targets: mart_finance.v6_silver_* tables
--
-- BUILD ORDER (run 1 → 6 in sequence):
--   1. v6_silver_project_inputs        — master wide inputs, 1 row per tech
--   2. v6_silver_capex_components      — $/W components + total + contingency
--   3. v6_silver_opex_all_rates        — all opex rate inputs unified per tech
--   4. v6_silver_generation_profile    — seasonality × Y1 gen × degradation
--   5. v6_silver_itc_inputs            — ITC/PTC/MACRS joined per tech
--   6. v6_silver_operating_lcs         — LC schedule cleaned and ready
--
-- BLOCKED (needs dim_month + OI-001 resolved):
--   v6_silver_timeline_monthly         — monthly is_development/is_construction/
--                                        is_operation flags per tech
--
-- OPEN ISSUES flagged with -- ⚠️ OI-XXX
-- =============================================================================


-- =============================================================================
-- HELPER: latest run_id per staging table
-- Every silver CTE filters to the most recent push automatically.
-- =============================================================================


-- =============================================================================
-- 1. v6_silver_project_inputs
--    Master wide inputs table — one row per technology.
--    Joins: timeline + capacity + lcoe_controls + financing_fees + contingency + degradation
--    This is the primary lookup table for all downstream fct models.
--    ⚠️ OI-001:  Gas/BESS/DTC construction_start = 2027-03-31 (pending Jason/Jim D)
--    ⚠️ OI-001b: DTC installed_capacity = 1095 MW (pending Jason/Jim D)
--    ⚠️ OI-001c: dev_start = 2024-01-31 (pending Jason/Jim D)
--    ⚠️ OI-010:  Wind installed_capacity = 643.86 MWac nameplate (net POI = 630)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_project_inputs` AS

WITH

ctl AS (SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_lcoe_model_controls`),

tl AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

cap AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_project_capacity`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

deg AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_degradation`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

fees AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_financing_fees`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

cont AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_contingency`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  -- Metadata
  tl.run_id,
  tl.snapshot_id,
  tl.model_name,
  tl.pushed_at,
  tl.run_label,
  tl.run_type,
  tl.technology,

  -- LCOE model controls (same for all techs — denormalized for easy joins)
  ctl.discount_rate,
  ctl.gas_bonus_dep_switch,
  ctl.solar_itc_ptc_switch,
  ctl.wind_itc_ptc_switch,
  ctl.gas_itc_ptc_switch,
  ctl.bess_itc_ptc_switch,
  ctl.solar_tech_switch,
  ctl.wind_tech_switch,
  ctl.gas_tech_switch,
  ctl.bess_tech_switch,
  ctl.dtc_tech_switch,

  -- Project dates
  -- ⚠️ OI-001:  Gas/BESS/DTC construction_start pending
  -- ⚠️ OI-001c: dev_start pending
  tl.dev_start_date,
  tl.construction_start_date,
  tl.substantial_completion_date,
  tl.end_of_useful_life_date,
  tl.placed_in_service_date,
  tl.useful_life_years,
  tl.tech_switch,

  -- Derived date fields (computed for convenience)
  DATE_DIFF(tl.substantial_completion_date, tl.construction_start_date, MONTH)
    AS construction_duration_months,
  DATE_DIFF(tl.end_of_useful_life_date, tl.substantial_completion_date, MONTH)
    AS operation_duration_months,
  EXTRACT(YEAR FROM tl.substantial_completion_date)
    AS sc_year,
  EXTRACT(YEAR FROM tl.construction_start_date)
    AS ntp_year,

  -- Capacities
  -- ⚠️ OI-001b: DTC = 1095 MW pending
  -- ⚠️ OI-010:  Wind nameplate = 643.86, net POI = 630
  cap.installed_capacity_mw,
  cap.capacity_at_poi_mw,
  cap.turbine_count,
  cap.y1_generation_mwh,
  cap.specific_production,
  cap.storage_duration_hrs,
  cap.dtc_reliability,
  cap.dtc_cfe_pct,

  -- Degradation
  deg.cumulative_degradation_at_ul,
  deg.first_year_bess_degradation,

  -- Derived: annual degradation rate (linear interpolation to end of useful life)
  CASE
    WHEN tl.useful_life_years > 0 AND deg.cumulative_degradation_at_ul IS NOT NULL
    THEN deg.cumulative_degradation_at_ul / tl.useful_life_years
    ELSE 0
  END AS annual_degradation_rate,

  -- Financing fees
  fees.underwriting_fee_usd,
  fees.transfer_transaction_cost_usd,
  fees.transfer_upfront_fee_pct,
  fees.transfer_itc_insurance_pct,

  -- Contingency
  cont.capex_contingency_date,
  cont.capex_contingency_usd,
  cont.opex_contingency_pct,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM tl
CROSS JOIN ctl
LEFT JOIN cap  ON tl.technology = cap.technology
LEFT JOIN deg  ON tl.technology = deg.technology
LEFT JOIN fees ON tl.technology = fees.technology
LEFT JOIN cont ON tl.technology = cont.technology;


-- =============================================================================
-- 2. v6_silver_capex_components
--    $/W unit costs + total CapEx + contingency per technology per component.
--    Ready for: project_capex_monthly fct model (unit_cost + adder) × capacity × 1,000,000
--    Also computes effective $/W including contingency adder.
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_capex_components` AS

WITH

capex AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_capex_unit_cost`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

cont AS (
  SELECT technology, capex_contingency_usd, capex_contingency_date
  FROM `sandbox-lakehouse.stg_finance.v6_stg_contingency`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

cap AS (
  SELECT technology, installed_capacity_mw, capacity_at_poi_mw
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_capacity`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  c.run_id,
  c.snapshot_id,
  c.model_name,
  c.pushed_at,
  c.run_label,
  c.run_type,
  c.technology,
  c.component,
  c.dollar_per_w,
  c.total_capex_usd,

  -- Contingency
  ct.capex_contingency_usd,
  ct.capex_contingency_date,

  -- Capacity for sanity check: total_capex_usd / (installed_capacity_mw * 1,000,000) = $/W
  cp.installed_capacity_mw,
  CASE
    WHEN cp.installed_capacity_mw > 0
    THEN ROUND(c.total_capex_usd / (cp.installed_capacity_mw * 1000000), 4)
    ELSE NULL
  END AS total_implied_dollar_per_w,

  -- Total capex including contingency
  COALESCE(c.total_capex_usd, 0) + COALESCE(ct.capex_contingency_usd, 0)
    AS total_capex_with_contingency_usd,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM capex c
LEFT JOIN cont ct ON c.technology = ct.technology
LEFT JOIN cap  cp ON c.technology = cp.technology;


-- =============================================================================
-- 3. v6_silver_opex_all_rates
--    All opex rate inputs in one wide table per technology.
--    Joins: opex_rates + insurance + property_tax + franchise_tax + land_lease
--           + gas_opex + dtc_opex (pivoted to columns)
--    Ready for: project_opex_monthly fct model.
--    ⚠️ OI-008: DTC insurance blank (Anoop)
--    ⚠️ OI-009: BESS/DTC covered O&M TBD (Brad Platt / Ted Mongan)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_opex_all_rates` AS

WITH

rates AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_opex_rates`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

ins AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_insurance`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

ptax AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_property_tax`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

ftax AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_franchise_tax`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

ll AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_land_lease`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

cont AS (
  SELECT technology, opex_contingency_pct
  FROM `sandbox-lakehouse.stg_finance.v6_stg_contingency`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

-- Gas opex (single row — no technology column, join via run_id)
gas_opex AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_gas_opex`
),

-- DTC opex — pivot line items to columns
dtc_opex AS (
  SELECT
    run_id, snapshot_id, model_name, pushed_at,
    MAX(CASE WHEN expense_name = 'HV Maintenance' THEN yr1_rate END)       AS dtc_hv_maintenance_yr1,
    MAX(CASE WHEN expense_name = 'HV Maintenance' THEN annual_escalation END) AS dtc_hv_maintenance_escalation,
    MAX(CASE WHEN expense_name = 'Insurance'      THEN yr1_rate END)       AS dtc_insurance_yr1,
    MAX(CASE WHEN expense_name = 'Insurance'      THEN annual_escalation END) AS dtc_insurance_escalation
  FROM `sandbox-lakehouse.stg_finance.v6_stg_dtc_opex`
  GROUP BY run_id, snapshot_id, model_name, pushed_at
)

SELECT
  r.run_id, r.snapshot_id, r.model_name, r.pushed_at,
  r.run_label, r.run_type,
  r.technology,

  -- Land lease
  ll.toggle_scheduled              AS land_lease_toggle,
  ll.dollar_per_acre               AS land_lease_dollar_per_acre,
  ll.total_acres                   AS land_lease_total_acres,
  ll.annual_escalator              AS land_lease_escalator,
  ROUND(ll.dollar_per_acre * ll.total_acres, 2)
                                   AS land_lease_yr1_total,

  -- Insurance
  -- ⚠️ OI-008: DTC values will be null until Anoop provides them
  ins.replacement_cost_usd         AS insurance_replacement_cost,
  ins.yr1_revenue_usd              AS insurance_yr1_revenue,
  ins.premium_rate                 AS insurance_premium_rate,
  ins.annual_premium_usd           AS insurance_annual_premium,

  -- Property tax
  ptax.cod_year,
  ptax.abatement_start_year,
  ptax.abatement_tenor_years,
  ptax.project_basis_at_sc_usd,
  ptax.total_millage_rate,
  ptax.millage_rate_abatement,
  ptax.annual_abatement_payment_usd,
  ptax.annual_ag_value_lost_usd,
  -- Full property tax before abatement
  ROUND(ptax.project_basis_at_sc_usd * ptax.total_millage_rate, 2)
                                   AS property_tax_full_annual,
  -- During abatement period
  ROUND(ptax.project_basis_at_sc_usd * ptax.millage_rate_abatement, 2)
                                   AS property_tax_abatement_annual,

  -- Franchise tax
  ftax.franchise_tax_pct_revenue,

  -- Sleeve fee
  r.sleeve_fee_dollar_per_mwh,

  -- Opex contingency
  cont.opex_contingency_pct,

  -- Gas-specific opex (only populated for Gas technology)
  CASE WHEN r.technology = 'Gas' THEN g.use_generic_fuel_price      ELSE NULL END AS gas_use_generic_fuel_price,
  CASE WHEN r.technology = 'Gas' THEN g.generic_fuel_price_per_mmbtu ELSE NULL END AS gas_generic_fuel_price,
  CASE WHEN r.technology = 'Gas' THEN g.fuel_price_escalation        ELSE NULL END AS gas_fuel_price_escalation,
  CASE WHEN r.technology = 'Gas' THEN g.mmbtu_per_mwh                ELSE NULL END AS gas_mmbtu_per_mwh,
  CASE WHEN r.technology = 'Gas' THEN g.fuel_adder                   ELSE NULL END AS gas_fuel_adder,
  CASE WHEN r.technology = 'Gas' THEN g.fuel_price_adder             ELSE NULL END AS gas_fuel_price_adder,
  CASE WHEN r.technology = 'Gas' THEN g.trunk_ft_volume_mmbtu_day    ELSE NULL END AS gas_trunk_ft_volume,
  CASE WHEN r.technology = 'Gas' THEN g.lateral_ft_volume_mmbtu_day  ELSE NULL END AS gas_lateral_ft_volume,
  CASE WHEN r.technology = 'Gas' THEN g.trunk_reservation_rate       ELSE NULL END AS gas_trunk_reservation_rate,
  CASE WHEN r.technology = 'Gas' THEN g.lateral_reservation_rate     ELSE NULL END AS gas_lateral_reservation_rate,
  -- Effective gas fuel cost = generic_price + adder + price_adder
  CASE WHEN r.technology = 'Gas'
    THEN ROUND(
      COALESCE(g.generic_fuel_price_per_mmbtu, 0) +
      COALESCE(g.fuel_adder, 0) +
      COALESCE(g.fuel_price_adder, 0), 4)
    ELSE NULL
  END AS gas_effective_fuel_price_per_mmbtu,

  -- DTC-specific opex (only populated for DTC technology)
  -- ⚠️ OI-009: DTC Covered O&M TBD (Ted Mongan)
  CASE WHEN r.technology = 'DTC' THEN d.dtc_hv_maintenance_yr1          ELSE NULL END AS dtc_hv_maintenance_yr1,
  CASE WHEN r.technology = 'DTC' THEN d.dtc_hv_maintenance_escalation    ELSE NULL END AS dtc_hv_maintenance_escalation,
  CASE WHEN r.technology = 'DTC' THEN d.dtc_insurance_yr1                ELSE NULL END AS dtc_insurance_yr1,
  CASE WHEN r.technology = 'DTC' THEN d.dtc_insurance_escalation         ELSE NULL END AS dtc_insurance_escalation,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM rates r
LEFT JOIN ins  ON r.technology = ins.technology
LEFT JOIN ptax ON r.technology = ptax.technology
LEFT JOIN ftax ON r.technology = ftax.technology
LEFT JOIN ll   ON r.technology = ll.technology
LEFT JOIN cont ON r.technology = cont.technology
CROSS JOIN gas_opex  g
CROSS JOIN dtc_opex  d;


-- =============================================================================
-- 4. v6_silver_generation_profile
--    Monthly generation profile per technology — seasonality factors combined
--    with Y1 generation and degradation curve.
--    One row per technology per month_number (1-12).
--    Ready for: generation_monthly fct model (multiply by operating_year_number)
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_generation_profile` AS

WITH

seas AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_generation_seasonality`
  WHERE technology IN ('Solar','Wind','Gas')
),

cap AS (
  SELECT technology, y1_generation_mwh, installed_capacity_mw
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_capacity`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

deg AS (
  SELECT technology, cumulative_degradation_at_ul, first_year_bess_degradation
  FROM `sandbox-lakehouse.stg_finance.v6_stg_degradation`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

tl AS (
  SELECT technology, useful_life_years
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  s.run_id, s.snapshot_id, s.model_name, s.pushed_at,
  s.run_label, s.run_type,
  s.technology,
  s.month_number,
  s.seasonality_factor,

  -- Y1 generation
  c.y1_generation_mwh                                        AS y1_generation_mwh,
  c.installed_capacity_mw,

  -- Y1 monthly generation (MWh) = Y1 annual × monthly seasonality factor
  ROUND(c.y1_generation_mwh * s.seasonality_factor, 2)       AS y1_monthly_generation_mwh,

  -- Degradation inputs
  d.cumulative_degradation_at_ul,
  t.useful_life_years,

  -- Annual degradation rate (linear)
  CASE
    WHEN t.useful_life_years > 0 AND d.cumulative_degradation_at_ul IS NOT NULL
    THEN ROUND(d.cumulative_degradation_at_ul / t.useful_life_years, 8)
    ELSE 0
  END AS annual_degradation_rate,

  -- Generation in operating year N (formula used in fct model):
  -- gen_yr_N = y1_monthly × (1 - annual_deg_rate × (N - 1))
  -- Stored as a template — actual year loop happens in fct_generation_monthly
  -- Preview: year 1, year 10, year 20 spot checks
  ROUND(c.y1_generation_mwh * s.seasonality_factor * 1.0, 2) AS gen_yr1_mwh,
  ROUND(c.y1_generation_mwh * s.seasonality_factor *
    GREATEST(0, 1 - (
      CASE WHEN t.useful_life_years > 0 AND d.cumulative_degradation_at_ul IS NOT NULL
           THEN d.cumulative_degradation_at_ul / t.useful_life_years ELSE 0 END
    ) * 9), 2)                                                AS gen_yr10_mwh,
  ROUND(c.y1_generation_mwh * s.seasonality_factor *
    GREATEST(0, 1 - (
      CASE WHEN t.useful_life_years > 0 AND d.cumulative_degradation_at_ul IS NOT NULL
           THEN d.cumulative_degradation_at_ul / t.useful_life_years ELSE 0 END
    ) * 19), 2)                                               AS gen_yr20_mwh,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM seas s
LEFT JOIN cap c ON s.technology = c.technology
LEFT JOIN deg d ON s.technology = d.technology
LEFT JOIN tl  t ON s.technology = t.technology;


-- =============================================================================
-- 5. v6_silver_itc_inputs
--    ITC / PTC / MACRS inputs joined and ready for tax credit monthly calc.
--    One row per technology with all tax-related inputs pre-joined.
--    Computes: effective ITC rate after transfer, net ITC basis, MACRS split.
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_itc_inputs` AS

WITH

tax AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_tax_attributes`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

capex AS (
  SELECT
    technology,
    MAX(total_capex_usd)      AS total_capex_usd,
    MAX(total_capex_with_contingency_usd) AS total_capex_with_contingency_usd
  FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
  GROUP BY technology
),

-- CORRECTED (OI-fix): include underwriting fee + transfer transaction cost in ITC basis
-- Matches Pro Forma "Project Costs" cell which adds these fees to CAPEX_Tool total
fees AS (
  SELECT
    technology,
    COALESCE(underwriting_fee_usd, 0)            AS underwriting_fee_usd,
    COALESCE(transfer_transaction_cost_usd, 0)   AS transfer_transaction_cost_usd
  FROM `sandbox-lakehouse.stg_finance.v6_stg_financing_fees`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
),

tl AS (
  SELECT technology, placed_in_service_date, substantial_completion_date
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  t.run_id, t.snapshot_id, t.model_name, t.pushed_at,
  t.run_label, t.run_type,
  t.technology,

  -- ITC inputs
  t.itc_eligibility_pct,
  t.itc_rate,
  t.effective_tax_rate,
  t.itc_ptc_transferred,
  t.itc_ptc_transfer_price,

  -- CORRECTED: ITC basis = CapEx + underwriting fee + transfer cost (per Pro Forma Project Costs)
  -- Gas and DTC have 0% ITC rate so fees don't affect them; Solar/BESS/Wind fees = $3M each
  ROUND(
    COALESCE(c.total_capex_usd, 0)
    + COALESCE(f.underwriting_fee_usd, 0)
    + COALESCE(f.transfer_transaction_cost_usd, 0),
    2
  ) AS itc_basis_usd,

  -- Gross ITC = (CapEx + fees) × ITC eligibility % × ITC rate
  ROUND(
    (COALESCE(c.total_capex_usd, 0)
     + COALESCE(f.underwriting_fee_usd, 0)
     + COALESCE(f.transfer_transaction_cost_usd, 0))
    * COALESCE(t.itc_eligibility_pct, 0) * COALESCE(t.itc_rate, 0),
    2
  ) AS gross_itc_usd,

  -- Net ITC = (CapEx + fees) × eligibility × rate × transfer price
  ROUND(
    (COALESCE(c.total_capex_usd, 0)
     + COALESCE(f.underwriting_fee_usd, 0)
     + COALESCE(f.transfer_transaction_cost_usd, 0))
    * COALESCE(t.itc_eligibility_pct, 0) * COALESCE(t.itc_rate, 0) *
    CASE WHEN COALESCE(t.itc_ptc_transferred, 0) = 1
         THEN COALESCE(t.itc_ptc_transfer_price, 1)
         ELSE 1
    END,
    2
  ) AS net_itc_usd,

  -- MACRS basis
  t.bonus_dep_switch,
  t.five_yr_macrs_basis,
  t.twenty_yr_macrs_basis,

  -- CORRECTED: Depreciable basis = (CapEx + fees) × (1 - ITC rate × 0.5) per IRC 50(c)
  ROUND(
    (COALESCE(c.total_capex_usd, 0)
     + COALESCE(f.underwriting_fee_usd, 0)
     + COALESCE(f.transfer_transaction_cost_usd, 0)) *
    (1 - COALESCE(t.itc_rate, 0) * 0.5),
    2
  ) AS depreciable_basis_usd,

  -- CORRECTED: 5yr MACRS depreciable amount (basis includes fees)
  ROUND(
    (COALESCE(c.total_capex_usd, 0)
     + COALESCE(f.underwriting_fee_usd, 0)
     + COALESCE(f.transfer_transaction_cost_usd, 0)) *
    (1 - COALESCE(t.itc_rate, 0) * 0.5) *
    COALESCE(t.five_yr_macrs_basis, 0),
    2
  ) AS five_yr_macrs_basis_usd,

  -- CORRECTED: 20yr MACRS depreciable amount (basis includes fees)
  ROUND(
    (COALESCE(c.total_capex_usd, 0)
     + COALESCE(f.underwriting_fee_usd, 0)
     + COALESCE(f.transfer_transaction_cost_usd, 0)) *
    (1 - COALESCE(t.itc_rate, 0) * 0.5) *
    COALESCE(t.twenty_yr_macrs_basis, 0),
    2
  ) AS twenty_yr_macrs_basis_usd,

  -- PTC inputs (Wind only)
  t.ptc_end_date,
  t.ptc_index_year,
  t.ptc_cpi,
  t.ptc_base_rate,
  t.ptc_eligibility,
  t.ptc_per_mwh,
  t.ptc_transfer_price,

  -- PIS and SC dates (for depreciation timing)
  tl.placed_in_service_date,
  tl.substantial_completion_date,

  -- Total capex reference
  c.total_capex_usd,
  c.total_capex_with_contingency_usd,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM tax t
LEFT JOIN capex c ON t.technology = c.technology
LEFT JOIN tl    ON t.technology = tl.technology;


-- =============================================================================
-- 6. v6_silver_operating_lcs
--    Operating LC schedule — cleaned and ready.
--    Filters to only populated LCs (lc_amount_usd IS NOT NULL and > 0).
--    Wind LC #1 = $34,625,360 (2039-09-30 to 2059-09-30) is the only live entry.
-- =============================================================================
CREATE OR REPLACE TABLE `sandbox-lakehouse.mart_finance.v6_silver_operating_lcs` AS

WITH

lcs AS (
  SELECT * FROM `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
    AND lc_amount_usd IS NOT NULL
    AND lc_amount_usd > 0
),

tl AS (
  SELECT technology, substantial_completion_date
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  WHERE technology IN ('Solar','Wind','Gas','BESS','DTC')
)

SELECT
  l.run_id, l.snapshot_id, l.model_name, l.pushed_at,
  l.run_label, l.run_type,
  l.technology,
  l.line_item_num,
  l.lc_label,
  l.start_period,
  l.end_period,
  l.escalation,
  l.lc_amount_usd,
  l.lc_rate,

  -- Duration in months
  DATE_DIFF(l.end_period, l.start_period, MONTH) + 1  AS lc_duration_months,

  -- Annual LC cost (if rate-based: lc_amount × lc_rate, else lc_amount directly)
  CASE
    WHEN l.lc_rate IS NOT NULL AND l.lc_rate > 0
    THEN ROUND(l.lc_amount_usd * l.lc_rate, 2)
    ELSE l.lc_amount_usd
  END AS annual_lc_cost_usd,

  -- SC date for reference (LC timing relative to COD)
  tl.substantial_completion_date,
  DATE_DIFF(l.start_period, tl.substantial_completion_date, MONTH)
    AS months_after_sc_start,

  CURRENT_TIMESTAMP() AS created_at,
  CURRENT_TIMESTAMP() AS silver_created_at

FROM lcs l
LEFT JOIN tl ON l.technology = tl.technology;


-- =============================================================================
-- END v6_silver_consolidated.sql
-- =============================================================================
-- NOT YET BUILT — blocked:
--   v6_silver_timeline_monthly    — needs dim_month + OI-001 (construction dates)
--                                   resolved. Will produce is_development /
--                                   is_construction / is_operation flags per
--                                   tech per calendar month — the backbone of
--                                   all fct models.
--
-- NEXT after OIs resolved:
--   v6_dim_month                  — time spine anchored to Solar Dev Start
--   v6_silver_timeline_monthly    — flags + operating_year_number per tech/month
--   v6_fct_generation_monthly     — v6_silver_generation_profile × timeline
--   v6_fct_capex_monthly          — v6_silver_capex_components × S-curve
--   v6_fct_opex_monthly           — v6_silver_opex_all_rates × timeline
--   v6_fct_tax_credit_monthly     — v6_silver_itc_inputs × capex monthly
--   v6_fct_depreciation_monthly   — depreciable_basis × MACRS schedule
--   v6_fct_lcoe_component_annual  — PV discounting rollup
--   v6_mart_lcoe_facility_summary — RLR output table
-- =============================================================================