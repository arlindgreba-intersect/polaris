-- =============================================================================
-- Polaris V6 - fct_finance.lcoe_facility_summary
-- Final CC/RR RLR output - feeds Looker. Append-only with canonical audit fields.
-- Facility numerator = SUM of tech numerators + Gas lifetime fuel (User Guide).
-- Facility denominator = DTC kW-mo (1095 MW * 1000 * 20 yr * 12).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.lcoe_facility_summary` (
  technology              STRING,
  lcoe_usd_per_unit       FLOAT64,
  lcoe_denominator_unit   STRING,
  total_capex_usd         FLOAT64,
  total_opex_usd          FLOAT64,
  total_itc_usd           FLOAT64,
  total_dep_shield_usd    FLOAT64,
  total_revenue_usd       FLOAT64,
  lcoe_numerator_usd      FLOAT64,
  lcoe_denominator        FLOAT64,
  run_label               STRING,
  run_type                STRING,
  created_at              TIMESTAMP,
  run_id                  STRING,
  pushed_at               TIMESTAMP
);

INSERT INTO `sandbox-lakehouse.fct_finance.lcoe_facility_summary`
(technology, lcoe_usd_per_unit, lcoe_denominator_unit, total_capex_usd, total_opex_usd,
 total_itc_usd, total_dep_shield_usd, total_revenue_usd, lcoe_numerator_usd, lcoe_denominator,
 run_label, run_type, created_at, run_id, pushed_at)
WITH
canonical AS (
  SELECT run_id, pushed_at
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
lca AS (
  SELECT * FROM `sandbox-lakehouse.fct_finance.lcoe_component_annual`
),
dtc_denom AS (
  SELECT lcoe_denominator AS dtc_denom_kwmo
  FROM lca WHERE technology = 'DTC'
),
gas_fuel AS (
  SELECT SUM(gas_fuel_monthly_usd) AS gas_lifetime_fuel_usd
  FROM `sandbox-lakehouse.fct_finance.project_opex_monthly`
  WHERE technology = 'Gas'
),
totals AS (
  SELECT
    SUM(total_capex_usd)      AS sum_capex,
    SUM(total_opex_usd)       AS sum_opex,
    SUM(total_itc_usd)        AS sum_itc,
    SUM(total_dep_shield_usd) AS sum_dep,
    SUM(total_revenue_usd)    AS sum_revenue,
    SUM(lcoe_numerator_usd)   AS sum_numerator
  FROM lca
)
SELECT
  lca.technology,
  ROUND(lca.lcoe_usd_per_unit, 4)         AS lcoe_usd_per_unit,
  lca.lcoe_denominator_unit,
  ROUND(lca.total_capex_usd, 2)           AS total_capex_usd,
  ROUND(lca.total_opex_usd, 2)            AS total_opex_usd,
  ROUND(lca.total_itc_usd, 2)             AS total_itc_usd,
  ROUND(lca.total_dep_shield_usd, 2)      AS total_dep_shield_usd,
  ROUND(lca.total_revenue_usd, 2)         AS total_revenue_usd,
  ROUND(lca.lcoe_numerator_usd, 2)        AS lcoe_numerator_usd,
  ROUND(lca.lcoe_denominator, 2)          AS lcoe_denominator,
  'Monthly_Haul_04_2026' AS run_label,
  'current_forecast' AS run_type,
  CURRENT_TIMESTAMP()    AS created_at,
  c.run_id,
  c.pushed_at
FROM lca
CROSS JOIN canonical c

UNION ALL

SELECT
  'Facility'                                                                       AS technology,
  ROUND(SAFE_DIVIDE(t.sum_numerator + gf.gas_lifetime_fuel_usd, d.dtc_denom_kwmo), 4) AS lcoe_usd_per_unit,
  'kW-mo'                                                                          AS lcoe_denominator_unit,
  ROUND(t.sum_capex, 2)                                                            AS total_capex_usd,
  ROUND(t.sum_opex + gf.gas_lifetime_fuel_usd, 2)                                  AS total_opex_usd,
  ROUND(t.sum_itc, 2)                                                              AS total_itc_usd,
  ROUND(t.sum_dep, 2)                                                              AS total_dep_shield_usd,
  ROUND(t.sum_revenue, 2)                                                          AS total_revenue_usd,
  ROUND(t.sum_numerator + gf.gas_lifetime_fuel_usd, 2)                             AS lcoe_numerator_usd,
  ROUND(d.dtc_denom_kwmo, 2)                                                       AS lcoe_denominator,
  'Monthly_Haul_04_2026' AS run_label,
  'current_forecast' AS run_type,
  CURRENT_TIMESTAMP()    AS created_at,
  c.run_id,
  c.pushed_at
FROM totals t
CROSS JOIN dtc_denom d
CROSS JOIN gas_fuel gf
CROSS JOIN canonical c;