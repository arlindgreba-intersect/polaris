-- =============================================================================
-- Polaris V6 - fct_finance.project_opex_monthly
-- FULLY CORRECTED VERSION — reads all opex from Opex_Tool lifetime totals
-- Divides lifetime totals evenly over operating months for each tech.
--
-- Source architecture (all from v6_raw_opex_tool):
--   v6_stg_opex_lifetime_totals: land_lease, insurance, property_tax, other_exp
--   v6_stg_om_schedules: O&M & Asset Management, Gas Fixed/Variable O&M
--   v6_stg_gas_opex + generation: Gas fuel (OI-005 placeholder = 0)
--   v6_stg_operating_lcs: Wind operating LC
--   v6_stg_dtc_opex: DTC HV maintenance
--
-- Known gaps (placeholder = 0):
--   OI-005: Gas fuel, franchise tax, sleeve fee (market curves pending Brian Wile)
--   OI-009: BESS/DTC Covered O&M (pending Brad Platt / Ted Mongan)
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.project_opex_monthly` (
  calendar_month_end          DATE,
  technology                  STRING,
  operating_year_num          INT64,
  operating_month_num         INT64,
  om_monthly_usd              FLOAT64,
  land_lease_monthly_usd      FLOAT64,
  insurance_monthly_usd       FLOAT64,
  property_tax_monthly_usd    FLOAT64,
  other_expenses_monthly_usd  FLOAT64,
  gas_fuel_monthly_usd        FLOAT64,
  dtc_hv_monthly_usd          FLOAT64,
  wake_losses_monthly_usd     FLOAT64,
  lcs_monthly_usd             FLOAT64,
  total_opex_monthly_usd      FLOAT64,
  has_missing_om_inputs       BOOL,
  timeline_run_id             STRING,
  timeline_pushed_at          TIMESTAMP,
  run_id                      STRING,
  pushed_at                   TIMESTAMP,
  run_label                   STRING,
  created_at                  TIMESTAMP,
  run_type                    STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.project_opex_monthly`
(calendar_month_end, technology, operating_year_num, operating_month_num,
 om_monthly_usd, land_lease_monthly_usd, insurance_monthly_usd, property_tax_monthly_usd,
 other_expenses_monthly_usd, gas_fuel_monthly_usd, dtc_hv_monthly_usd,
 wake_losses_monthly_usd, lcs_monthly_usd, total_opex_monthly_usd, has_missing_om_inputs,
 timeline_run_id, timeline_pushed_at, run_id, pushed_at, run_label, created_at, run_type)

WITH canonical AS (
  SELECT run_id, pushed_at, run_label, run_type
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),

base AS (
WITH

-- ── Latest run IDs ──────────────────────────────────────────────────────────
latest_lcs AS (
  SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs`
  ORDER BY pushed_at DESC LIMIT 1
),

-- ── Opex lifetime totals from Opex_Tool ─────────────────────────────────────
opex_totals AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_opex_lifetime_totals`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

-- ── O&M schedules from Opex_Tool ────────────────────────────────────────────
om_schedules AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_om_schedules`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.polaris_raw.v6_raw_inputs_tab`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

-- ── DTC HV maintenance from silver ──────────────────────────────────────────
silver_dtc AS (
  SELECT dtc_hv_maintenance_yr1, dtc_hv_maintenance_escalation
  FROM `sandbox-lakehouse.mart_finance.v6_silver_opex_all_rates`
  WHERE technology = 'DTC'
  ORDER BY pushed_at DESC LIMIT 1
),

-- ── Gas fuel (OI-005 placeholder) ───────────────────────────────────────────
silver_gas AS (
  SELECT
    s.gas_mmbtu_per_mwh,
    s.gas_effective_fuel_price_per_mmbtu,
    s.gas_fuel_price_escalation,
    s.gas_trunk_ft_volume,
    s.gas_trunk_reservation_rate,
    s.gas_lateral_ft_volume,
    s.gas_lateral_reservation_rate,
    g.trunk_escalator AS gas_trunk_escalator,
    g.lateral_escalator AS gas_lateral_escalator
  FROM `sandbox-lakehouse.mart_finance.v6_silver_opex_all_rates` s
  LEFT JOIN (
    SELECT trunk_escalator, lateral_escalator
    FROM `sandbox-lakehouse.stg_finance.v6_stg_gas_opex`
    ORDER BY pushed_at DESC LIMIT 1
  ) g ON TRUE
  WHERE s.technology = 'Gas'
  ORDER BY s.pushed_at DESC LIMIT 1
),

-- ── Operating LCs ────────────────────────────────────────────────────────────
lcs AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs`
  WHERE run_id = (SELECT run_id FROM latest_lcs)
    AND lc_amount_usd IS NOT NULL
    AND lc_amount_usd > 0
),

-- ── Generation monthly (for gas fuel calc) ───────────────────────────────────
gen AS (
  SELECT calendar_month_end, technology, monthly_generation_mwh, operating_year_num
  FROM `sandbox-lakehouse.fct_finance.generation_monthly`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.fct_finance.generation_monthly`
    ORDER BY pushed_at DESC LIMIT 1
  )
),

-- ── Timeline — operating months only ────────────────────────────────────────
timeline AS (
  SELECT
    calendar_month_end, calendar_year, calendar_month_num,
    technology, operating_year_num, operating_month_num,
    total_operating_months, substantial_completion_date,
    end_of_useful_life_date, run_id, pushed_at
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
    AND run_id = (
      SELECT run_id FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
      ORDER BY pushed_at DESC LIMIT 1
    )
),

-- ── COMPONENT 0: O&M (from Opex_Tool lifetime totals / operating months) ────
om_monthly AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      CASE
        WHEN t.technology = 'Gas'
        THEN (COALESCE(o.gas_fixed_om_lifetime_usd, 0)
              + COALESCE(o.gas_variable_om_lifetime_usd, 0))
             / NULLIF(t.total_operating_months, 0)
        ELSE COALESCE(o.total_om_lifetime_usd, 0)
             / NULLIF(t.total_operating_months, 0)
      END
    , 2) AS om_monthly_usd
  FROM timeline t
  LEFT JOIN om_schedules o ON o.technology = t.technology
),

-- ── COMPONENT 1: Land lease (from Inputs tab dollar_per_acre × acres) ────────
-- Opex_Tool 'Utilized Land Lease Costs' has NULL total_value in raw table
-- Use Inputs tab rates directly: dollar_per_acre × total_acres × escalation
-- BESS/DTC have NULL acres → $0; Gas has dollar_per_acre=0 → $0
land_lease AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    CASE
      WHEN COALESCE(ll.dollar_per_acre, 0) > 0
        AND COALESCE(ll.total_acres, 0) > 0
      THEN ROUND(
        (ll.dollar_per_acre * ll.total_acres)
        * POWER(1 + COALESCE(ll.annual_escalator, 0), t.operating_year_num - 1)
        / 12.0
      , 2)
      ELSE 0
    END AS land_lease_monthly_usd
  FROM timeline t
  LEFT JOIN `sandbox-lakehouse.stg_finance.v6_stg_land_lease` ll
    ON ll.technology = t.technology
),

-- ── COMPONENT 2: Insurance (from Opex_Tool lifetime totals) ─────────────────
insurance AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.insurance_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS insurance_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
),

-- ── COMPONENT 3: Property tax (from Opex_Tool lifetime totals) ──────────────
property_tax AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.property_tax_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS property_tax_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
),

-- ── COMPONENT 4: Other expenses (from v6_stg_other_expenses per-unit rates) ──
-- Opex_Tool 'Total Other Expenses' has NULL total_value in raw table
-- Use Inputs tab per-unit rates via staging table
-- NULL start_date = useful life expense (active entire operating period)
-- Exclude Gas Fixed/Variable O&M (already in om_monthly)
-- NOTE: Solar Total Other Expenses not in raw opex tool (AppScript gap)
-- Using stg_other_expenses line items for Solar/BESS
-- Using opex_totals Total Other Expenses for Wind (in raw table)
-- Gas: Personnel and Parasitic Load come from stg_other_expenses
--      Fixed O&M and Variable O&M excluded (already in om_monthly from Opex_Tool)
other_exp_detail AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_other_expenses`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_other_expenses`
    ORDER BY pushed_at DESC LIMIT 1
  )
  AND unit IS NOT NULL
  AND yr1_rate IS NOT NULL
  AND yr1_rate > 0
  -- Only exclude Gas Fixed O&M and Variable O&M (captured via om_monthly from Opex_Tool)
  -- Personnel and Parasitic Load are NOT in Opex_Tool om rows so keep them
  AND NOT (technology = 'Gas' AND expense_name IN ('Fixed O&M', 'Variable O&M'))
),

capacity AS (
  SELECT technology, installed_capacity_mw
  FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
    ORDER BY pushed_at DESC LIMIT 1
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY technology ORDER BY silver_created_at DESC) = 1
),

other_exp_monthly_detail AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      CASE e.unit
        WHEN '$/Yr'
        THEN e.yr1_rate * POWER(1 + COALESCE(e.annual_escalation,0), t.operating_year_num-1) / 12.0
        WHEN '$/Month'
        THEN e.yr1_rate * POWER(1 + COALESCE(e.annual_escalation,0), t.operating_year_num-1)
        WHEN '$'
        THEN CASE WHEN t.calendar_month_end = LAST_DAY(e.start_date, MONTH) THEN e.yr1_rate ELSE 0 END
        WHEN '$/kW-mo'
        THEN e.yr1_rate * COALESCE(c.installed_capacity_mw,0) * 1000.0
             * POWER(1 + COALESCE(e.annual_escalation,0), t.operating_year_num-1)
        WHEN '$/MWh'
        THEN e.yr1_rate * COALESCE(g.monthly_generation_mwh,0)
             * POWER(1 + COALESCE(e.annual_escalation,0), t.operating_year_num-1)
        ELSE 0
      END
    , 2) AS other_exp_monthly_usd
  FROM timeline t
  JOIN other_exp_detail e ON e.technology = t.technology
  LEFT JOIN capacity c ON c.technology = t.technology
  LEFT JOIN gen g ON g.technology = t.technology AND g.calendar_month_end = t.calendar_month_end
  WHERE (e.start_date IS NULL OR t.calendar_month_end >= LAST_DAY(e.start_date, MONTH))
    AND (e.end_date IS NULL OR t.calendar_month_end <= LAST_DAY(e.end_date, MONTH))
),

other_exp_from_stg AS (
  SELECT technology, calendar_month_end, operating_year_num,
    SUM(other_exp_monthly_usd) AS other_expenses_monthly_usd
  FROM other_exp_monthly_detail
  GROUP BY 1, 2, 3
),

-- For techs where Opex_Tool Total Other Expenses is available (Wind), use that
-- For others (Solar, BESS, Gas), use stg_other_expenses line item calculations
other_expenses AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    CASE
      WHEN COALESCE(ot.other_exp_lifetime_usd, 0) > 0
      THEN ROUND(ot.other_exp_lifetime_usd / NULLIF(t.total_operating_months, 0), 2)
      ELSE COALESCE(stg.other_expenses_monthly_usd, 0)
    END AS other_expenses_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
  LEFT JOIN other_exp_from_stg stg
    ON stg.technology = t.technology AND stg.calendar_month_end = t.calendar_month_end
),

-- ── COMPONENT 4b: Wake losses (Wind only, from Opex_Tool) ───────────────────
wake_losses AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.wake_losses_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS wake_losses_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
  WHERE t.technology = 'Wind'
),

-- ── COMPONENT 4b: Wake losses (Wind only, from Opex_Tool) ───────────────────
wake_losses AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.wake_losses_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS wake_losses_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
  WHERE t.technology = 'Wind'
),

-- ── COMPONENT 5: Gas fuel (from Opex_Tool Fuel OpEx lifetime total) ──────────
-- Fuel OpEx row_label in v6_raw_opex_tool = 'Fuel OpEx' = $6.34B
-- Spread evenly over Gas operating months
gas_fuel AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.gas_fuel_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS gas_fuel_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
  WHERE t.technology = 'Gas'
),

-- ── COMPONENT 6: DTC HV maintenance ─────────────────────────────────────────
dtc_hv AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(d.dtc_hv_maintenance_yr1, 0)
      * POWER(1 + COALESCE(d.dtc_hv_maintenance_escalation, 0),
              t.operating_year_num - 1)
      / 12.0
    , 2) AS dtc_hv_monthly_usd
  FROM timeline t
  CROSS JOIN silver_dtc d
  WHERE t.technology = 'DTC'
),

-- ── COMPONENT 7: Operating LCs (from Opex_Tool Total Operating LCs) ─────────
-- Total Operating LCs is in raw table for all techs = 0 for Case 8
-- Wind LC 1 rate in stg_operating_lcs is wrong (34.6M/yr) — Total Operating LCs = 0 overrides
agg_lcs AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(ot.operating_lcs_lifetime_usd, 0)
      / NULLIF(t.total_operating_months, 0)
    , 2) AS lcs_monthly_usd
  FROM timeline t
  LEFT JOIN opex_totals ot ON ot.technology = t.technology
)

-- ── FINAL ────────────────────────────────────────────────────────────────────
SELECT
  t.calendar_month_end,
  t.technology,
  t.operating_year_num,
  t.operating_month_num,
  COALESCE(om.om_monthly_usd,            0) AS om_monthly_usd,
  COALESCE(ll.land_lease_monthly_usd,    0) AS land_lease_monthly_usd,
  COALESCE(ins.insurance_monthly_usd,    0) AS insurance_monthly_usd,
  COALESCE(pt.property_tax_monthly_usd,  0) AS property_tax_monthly_usd,
  COALESCE(oe.other_expenses_monthly_usd,0) AS other_expenses_monthly_usd,
  COALESCE(wl.wake_losses_monthly_usd,   0) AS wake_losses_monthly_usd,
  COALESCE(gf.gas_fuel_monthly_usd,      0) AS gas_fuel_monthly_usd,
  COALESCE(dh.dtc_hv_monthly_usd,        0) AS dtc_hv_monthly_usd,
  COALESCE(lc.lcs_monthly_usd,           0) AS lcs_monthly_usd,
  ROUND(
    COALESCE(om.om_monthly_usd,            0)
    + COALESCE(ll.land_lease_monthly_usd,  0)
    + COALESCE(ins.insurance_monthly_usd,  0)
    + COALESCE(pt.property_tax_monthly_usd,0)
    + COALESCE(oe.other_expenses_monthly_usd, 0)
    + COALESCE(wl.wake_losses_monthly_usd, 0)
    + COALESCE(gf.gas_fuel_monthly_usd,    0)
    + COALESCE(dh.dtc_hv_monthly_usd,      0)
    + COALESCE(lc.lcs_monthly_usd,         0)
  , 2) AS total_opex_monthly_usd,
  CASE WHEN t.technology IN ('BESS','DTC')
        AND COALESCE(om.om_monthly_usd, 0) = 0
       THEN TRUE ELSE FALSE
  END AS has_missing_om_inputs,
  t.run_id  AS timeline_run_id,
  t.pushed_at AS timeline_pushed_at

FROM timeline t
LEFT JOIN om_monthly    om  ON om.technology  = t.technology AND om.calendar_month_end  = t.calendar_month_end
LEFT JOIN land_lease    ll  ON ll.technology  = t.technology AND ll.calendar_month_end  = t.calendar_month_end
LEFT JOIN insurance     ins ON ins.technology = t.technology AND ins.calendar_month_end = t.calendar_month_end
LEFT JOIN property_tax  pt  ON pt.technology  = t.technology AND pt.calendar_month_end  = t.calendar_month_end
LEFT JOIN other_expenses oe ON oe.technology  = t.technology AND oe.calendar_month_end  = t.calendar_month_end
LEFT JOIN gas_fuel      gf  ON gf.technology  = t.technology AND gf.calendar_month_end  = t.calendar_month_end
LEFT JOIN dtc_hv        dh  ON dh.technology  = t.technology AND dh.calendar_month_end  = t.calendar_month_end
LEFT JOIN wake_losses    wl  ON wl.technology  = t.technology AND wl.calendar_month_end  = t.calendar_month_end
LEFT JOIN wake_losses    wl  ON wl.technology  = t.technology AND wl.calendar_month_end  = t.calendar_month_end
LEFT JOIN agg_lcs       lc  ON lc.technology  = t.technology AND lc.calendar_month_end  = t.calendar_month_end

ORDER BY t.technology, t.calendar_month_end
)

SELECT
  b.calendar_month_end, b.technology, b.operating_year_num, b.operating_month_num,
  b.om_monthly_usd, b.land_lease_monthly_usd, b.insurance_monthly_usd,
  b.property_tax_monthly_usd, b.other_expenses_monthly_usd,
  b.gas_fuel_monthly_usd, b.dtc_hv_monthly_usd, b.wake_losses_monthly_usd, b.lcs_monthly_usd,
  b.total_opex_monthly_usd, b.has_missing_om_inputs,
  b.timeline_run_id, b.timeline_pushed_at,
  c.run_id, c.pushed_at, c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM base b
CROSS JOIN canonical c;
