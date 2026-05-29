-- =============================================================================
-- Polaris V6 - fct_finance.lcoe_component_annual
-- Append-only with canonical audit fields. Formula unchanged.
-- Solar/Wind denom: lifetime MWh from generation_monthly  ($/MWh)
-- Gas/BESS/DTC denom: installed_capacity_mw * 1000 * useful_life_years * 12  ($/kW-mo)
-- Gas LCOE excludes fuel (fuel is in Facility LCOE only per User Guide).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.lcoe_component_annual` (
  technology                  STRING,
  lcoe_numerator_usd          FLOAT64,
  lcoe_denominator            FLOAT64,
  lcoe_denominator_unit       STRING,
  lcoe_usd_per_unit           FLOAT64,
  total_capex_usd             FLOAT64,
  total_opex_usd              FLOAT64,
  total_itc_usd               FLOAT64,
  total_dep_shield_usd        FLOAT64,
  total_revenue_usd           FLOAT64,
  lifetime_generation_mwh     FLOAT64,
  run_id                      STRING,
  pushed_at                   TIMESTAMP,
  run_label                   STRING,
  created_at                  TIMESTAMP,
  run_type                     STRING
);

INSERT INTO `sandbox-lakehouse.fct_finance.lcoe_component_annual`
(technology, lcoe_numerator_usd, lcoe_denominator, lcoe_denominator_unit, lcoe_usd_per_unit,
 total_capex_usd, total_opex_usd, total_itc_usd, total_dep_shield_usd, total_revenue_usd,
 lifetime_generation_mwh, run_id, pushed_at, run_label, created_at, run_type)
WITH
canonical AS (
  SELECT run_id, pushed_at, run_label, run_type
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_capex_comp AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_proj_inputs AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_project_inputs`
  ORDER BY pushed_at DESC LIMIT 1
),
capacity AS (
  SELECT DISTINCT technology, installed_capacity_mw
  FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
  WHERE run_id = (SELECT run_id FROM latest_capex_comp)
),
life AS (
  SELECT DISTINCT technology, useful_life_years
  FROM `sandbox-lakehouse.mart_finance.v6_silver_project_inputs`
  WHERE run_id = (SELECT run_id FROM latest_proj_inputs)
),
capex AS (
  SELECT technology, SUM(monthly_capex_usd) AS total_capex_usd
  FROM `sandbox-lakehouse.fct_finance.project_capex_monthly`
  GROUP BY technology
),
opex AS (
  SELECT
    technology,
    SUM(total_opex_monthly_usd)            AS total_opex_all_usd,
    SUM(COALESCE(gas_fuel_monthly_usd, 0)) AS total_gas_fuel_usd
  FROM `sandbox-lakehouse.fct_finance.project_opex_monthly`
  GROUP BY technology
),
itc AS (
  SELECT technology, ABS(SUM(itc_benefit_usd)) AS total_itc_usd
  FROM `sandbox-lakehouse.fct_finance.tax_credit_monthly`
  GROUP BY technology
),
dep AS (
  SELECT technology, SUM(depreciation_tax_shield_monthly_usd) AS total_dep_shield_usd
  FROM `sandbox-lakehouse.fct_finance.depreciation_monthly`
  GROUP BY technology
),
rev AS (
  SELECT technology, SUM(revenue_usd) AS total_revenue_usd
  FROM `sandbox-lakehouse.fct_finance.revenue_monthly`
  GROUP BY technology
),
gen AS (
  SELECT technology, SUM(monthly_generation_mwh) AS lifetime_generation_mwh
  FROM `sandbox-lakehouse.fct_finance.generation_monthly`
  GROUP BY technology
),
techs AS (SELECT DISTINCT technology FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`),
calc AS (
  SELECT
    t.technology,
    COALESCE(cx.total_capex_usd, 0)        AS total_capex_usd,
    CASE
      WHEN t.technology = 'Gas'
        THEN COALESCE(ox.total_opex_all_usd, 0) - COALESCE(ox.total_gas_fuel_usd, 0)
      ELSE COALESCE(ox.total_opex_all_usd, 0)
    END                                     AS total_opex_usd,
    COALESCE(ic.total_itc_usd, 0)          AS total_itc_usd,
    COALESCE(dp.total_dep_shield_usd, 0)   AS total_dep_shield_usd,
    COALESCE(rv.total_revenue_usd, 0)      AS total_revenue_usd,
    COALESCE(g.lifetime_generation_mwh, 0) AS lifetime_generation_mwh,
    cap.installed_capacity_mw,
    lf.useful_life_years
  FROM techs t
  LEFT JOIN capex cx ON cx.technology = t.technology
  LEFT JOIN opex ox ON ox.technology = t.technology
  LEFT JOIN itc ic ON ic.technology = t.technology
  LEFT JOIN dep dp ON dp.technology = t.technology
  LEFT JOIN rev rv ON rv.technology = t.technology
  LEFT JOIN gen g ON g.technology = t.technology
  LEFT JOIN capacity cap ON cap.technology = t.technology
  LEFT JOIN life lf ON lf.technology = t.technology
)
SELECT
  ca.technology,
  ROUND(ca.total_capex_usd + ca.total_opex_usd - ca.total_itc_usd - ca.total_dep_shield_usd - ca.total_revenue_usd, 2) AS lcoe_numerator_usd,
  ROUND(
    CASE WHEN ca.technology IN ('Solar','Wind') THEN ca.lifetime_generation_mwh
         WHEN ca.technology IN ('BESS','Gas','DTC') THEN ca.installed_capacity_mw * 1000.0 * ca.useful_life_years * 12.0
    END, 2) AS lcoe_denominator,
  CASE WHEN ca.technology IN ('Solar','Wind') THEN 'MWh' ELSE 'kW-mo' END AS lcoe_denominator_unit,
  ROUND(SAFE_DIVIDE(
    ca.total_capex_usd + ca.total_opex_usd - ca.total_itc_usd - ca.total_dep_shield_usd - ca.total_revenue_usd,
    CASE WHEN ca.technology IN ('Solar','Wind') THEN ca.lifetime_generation_mwh
         WHEN ca.technology IN ('BESS','Gas','DTC') THEN ca.installed_capacity_mw * 1000.0 * ca.useful_life_years * 12.0 END
  ), 4) AS lcoe_usd_per_unit,
  ROUND(ca.total_capex_usd, 2)        AS total_capex_usd,
  ROUND(ca.total_opex_usd, 2)         AS total_opex_usd,
  ROUND(ca.total_itc_usd, 2)          AS total_itc_usd,
  ROUND(ca.total_dep_shield_usd, 2)   AS total_dep_shield_usd,
  ROUND(ca.total_revenue_usd, 2)      AS total_revenue_usd,
  ROUND(ca.lifetime_generation_mwh, 2) AS lifetime_generation_mwh,
  c.run_id,
  c.pushed_at,
  c.run_label,
  CURRENT_TIMESTAMP() AS created_at,
  c.run_type
FROM calc ca
CROSS JOIN canonical c;