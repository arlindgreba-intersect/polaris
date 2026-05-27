-- =============================================================================
-- Polaris V6 — fct_finance.lcoe_component_annual
-- One row per technology — the core LCOE calculation
-- Formula (undiscounted, no TVM per V6 User Guide):
--   LCOE = (CapEx + OpEx - ITC - Depreciation Tax Shield - Revenue) / Generation
-- Denominators:
--   Solar / Wind:           lifetime MWh from generation_monthly                 ($/MWh)
--   BESS / Gas / DTC:       installed_capacity_mw * 1000 * useful_life_years*12  ($/kW-mo)
-- Special case:
--   Gas LCOE excludes fuel opex (per User Guide — fuel sits in Facility LCOE only)
-- Sources:
--   CapEx:       SUM(monthly_capex_usd) from project_capex_monthly
--   OpEx:        SUM(total_opex_monthly_usd) from project_opex_monthly
--                (Gas: SUM(total_opex_monthly_usd - gas_fuel_monthly_usd))
--   ITC:         ABS(SUM(itc_benefit_usd)) from tax_credit_monthly
--   Dep shield:  SUM(depreciation_tax_shield_monthly_usd) from depreciation_monthly
--   Revenue:     SUM(revenue_usd) from revenue_monthly (currently 0; OI-005 pending)
--   Generation:  SUM(monthly_generation_mwh) from generation_monthly
--   Capacity:    installed_capacity_mw from v6_silver_capex_components
--   Life:        useful_life_years from v6_silver_project_inputs
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.lcoe_component_annual` AS
WITH
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
  LEFT JOIN capex    cx  ON cx.technology  = t.technology
  LEFT JOIN opex     ox  ON ox.technology  = t.technology
  LEFT JOIN itc      ic  ON ic.technology  = t.technology
  LEFT JOIN dep      dp  ON dp.technology  = t.technology
  LEFT JOIN rev      rv  ON rv.technology  = t.technology
  LEFT JOIN gen      g   ON g.technology   = t.technology
  LEFT JOIN capacity cap ON cap.technology = t.technology
  LEFT JOIN life     lf  ON lf.technology  = t.technology
)
SELECT
  technology,
  ROUND(total_capex_usd + total_opex_usd - total_itc_usd - total_dep_shield_usd - total_revenue_usd, 2) AS lcoe_numerator_usd,
  ROUND(
    CASE
      WHEN technology IN ('Solar','Wind')        THEN lifetime_generation_mwh
      WHEN technology IN ('BESS','Gas','DTC')    THEN installed_capacity_mw * 1000.0 * useful_life_years * 12.0
    END, 2)                                                                AS lcoe_denominator,
  CASE
    WHEN technology IN ('Solar','Wind')        THEN 'MWh'
    WHEN technology IN ('BESS','Gas','DTC')    THEN 'kW-mo'
  END                                                                       AS lcoe_denominator_unit,
  ROUND(
    SAFE_DIVIDE(
      total_capex_usd + total_opex_usd - total_itc_usd - total_dep_shield_usd - total_revenue_usd,
      CASE
        WHEN technology IN ('Solar','Wind')        THEN lifetime_generation_mwh
        WHEN technology IN ('BESS','Gas','DTC')    THEN installed_capacity_mw * 1000.0 * useful_life_years * 12.0
      END
    ), 4)                                                                  AS lcoe_usd_per_unit,
  ROUND(total_capex_usd, 2)                  AS total_capex_usd,
  ROUND(total_opex_usd, 2)                   AS total_opex_usd,
  ROUND(total_itc_usd, 2)                    AS total_itc_usd,
  ROUND(total_dep_shield_usd, 2)             AS total_dep_shield_usd,
  ROUND(total_revenue_usd, 2)                AS total_revenue_usd,
  ROUND(lifetime_generation_mwh, 2)          AS lifetime_generation_mwh
FROM calc
ORDER BY technology;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Full table inspection
SELECT * FROM `sandbox-lakehouse.fct_finance.lcoe_component_annual` ORDER BY technology;

-- 2. Sanity check vs Excel target ranges (variances acceptable until OI-009 closes)
--   Solar:  ~26.9 $/MWh
--   Wind:   ~30.6 $/MWh
--   Gas:    ~12.0 $/kW-mo
--   BESS:   ~2.8  $/kW-mo
--   DTC:    ~9.5  $/kW-mo
SELECT technology, lcoe_denominator_unit AS unit, lcoe_usd_per_unit AS lcoe
FROM `sandbox-lakehouse.fct_finance.lcoe_component_annual`
ORDER BY technology;