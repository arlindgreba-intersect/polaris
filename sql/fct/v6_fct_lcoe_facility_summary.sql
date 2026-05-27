-- =============================================================================
-- Polaris V6 — fct_finance.lcoe_facility_summary
-- Final CC/RR RLR output table — feeds Looker
-- One row per technology (Solar, Wind, Gas, BESS, DTC) plus a Facility roll-up row.
-- Facility roll-up:
--   Numerator   = SUM of all per-tech LCOE numerators from lcoe_component_annual
--   Denominator = DTC kW-mo denominator (1,095 MW × 1000 × 20 yr × 12 mo)
--   Unit        = $/kW-mo
--   LCOE        = Numerator / Denominator
-- Per-tech rows are copied verbatim from lcoe_component_annual.
-- Run metadata (run_label, run_type) sourced from mart_finance.lcoe_inputs_wide.
-- =============================================================================

CREATE OR REPLACE TABLE `sandbox-lakehouse.fct_finance.lcoe_facility_summary` AS
WITH
run_meta AS (
  SELECT
    ANY_VALUE(run_label) AS run_label,
    ANY_VALUE(run_type)  AS run_type
  FROM `sandbox-lakehouse.mart_finance.lcoe_inputs_wide`
),
lca AS (
  SELECT * FROM `sandbox-lakehouse.fct_finance.lcoe_component_annual`
),
dtc_denom AS (
  SELECT lcoe_denominator AS dtc_denom_kwmo
  FROM lca WHERE technology = 'DTC'
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
  m.run_label,
  m.run_type,
  CURRENT_TIMESTAMP()                     AS created_at
FROM lca
CROSS JOIN run_meta m

UNION ALL

SELECT
  'Facility'                                                   AS technology,
  ROUND(SAFE_DIVIDE(t.sum_numerator, d.dtc_denom_kwmo), 4)     AS lcoe_usd_per_unit,
  'kW-mo'                                                      AS lcoe_denominator_unit,
  ROUND(t.sum_capex, 2)                                        AS total_capex_usd,
  ROUND(t.sum_opex, 2)                                         AS total_opex_usd,
  ROUND(t.sum_itc, 2)                                          AS total_itc_usd,
  ROUND(t.sum_dep, 2)                                          AS total_dep_shield_usd,
  ROUND(t.sum_revenue, 2)                                      AS total_revenue_usd,
  ROUND(t.sum_numerator, 2)                                    AS lcoe_numerator_usd,
  ROUND(d.dtc_denom_kwmo, 2)                                   AS lcoe_denominator,
  m.run_label,
  m.run_type,
  CURRENT_TIMESTAMP()                                          AS created_at
FROM totals t
CROSS JOIN dtc_denom d
CROSS JOIN run_meta m
ORDER BY
  CASE technology
    WHEN 'Solar' THEN 1 WHEN 'Wind' THEN 2 WHEN 'Gas' THEN 3
    WHEN 'BESS' THEN 4 WHEN 'DTC' THEN 5 WHEN 'Facility' THEN 6
  END;


-- =============================================================================
-- VALIDATION QUERIES
-- =============================================================================

-- 1. Full table inspection
SELECT *
FROM `sandbox-lakehouse.fct_finance.lcoe_facility_summary`
ORDER BY
  CASE technology
    WHEN 'Solar' THEN 1 WHEN 'Wind' THEN 2 WHEN 'Gas' THEN 3
    WHEN 'BESS' THEN 4 WHEN 'DTC' THEN 5 WHEN 'Facility' THEN 6
  END;

-- 2. Facility LCOE expected range check (Excel target 76.665 $/kW-mo, range 70-80)
--    Per-tech LCOEs unchanged from lcoe_component_annual.
--    Reconciliation against Excel exact figure to occur once OI-005 (revenue
--    placeholder) and OI-009 (BESS/DTC O&M inputs) close.
SELECT
  technology,
  lcoe_usd_per_unit,
  lcoe_denominator_unit,
  CASE
    WHEN technology = 'Facility' AND lcoe_usd_per_unit BETWEEN 70 AND 80 THEN 'IN_RANGE'
    WHEN technology = 'Facility' THEN 'OUT_OF_RANGE — open OIs pending'
    ELSE NULL
  END AS facility_range_check
FROM `sandbox-lakehouse.fct_finance.lcoe_facility_summary`
WHERE technology = 'Facility';