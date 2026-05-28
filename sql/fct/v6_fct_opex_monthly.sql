-- =============================================================================
-- Polaris V6 - fct_finance.project_opex_monthly
-- Append-only with canonical run_id / run_label / pushed_at / created_at.
-- Preserves timeline_run_id / timeline_pushed_at for source-lineage traceability.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `sandbox-lakehouse.fct_finance.project_opex_monthly` (
  calendar_month_end          DATE,
  technology                  STRING,
  operating_year_num          INT64,
  operating_month_num         INT64,
  land_lease_monthly_usd      FLOAT64,
  insurance_monthly_usd       FLOAT64,
  property_tax_monthly_usd    FLOAT64,
  other_expenses_monthly_usd  FLOAT64,
  gas_fuel_monthly_usd        FLOAT64,
  dtc_hv_monthly_usd          FLOAT64,
  lcs_monthly_usd             FLOAT64,
  total_opex_monthly_usd      FLOAT64,
  has_missing_om_inputs       BOOL,
  timeline_run_id             STRING,
  timeline_pushed_at          TIMESTAMP,
  run_id                      STRING,
  pushed_at                   TIMESTAMP,
  run_label                   STRING,
  created_at                  TIMESTAMP
);

INSERT INTO `sandbox-lakehouse.fct_finance.project_opex_monthly`
(calendar_month_end, technology, operating_year_num, operating_month_num,
 land_lease_monthly_usd, insurance_monthly_usd, property_tax_monthly_usd,
 other_expenses_monthly_usd, gas_fuel_monthly_usd, dtc_hv_monthly_usd,
 lcs_monthly_usd, total_opex_monthly_usd, has_missing_om_inputs,
 timeline_run_id, timeline_pushed_at, run_id, pushed_at, run_label, created_at)
WITH
canonical AS (
  SELECT run_id, pushed_at
  FROM `sandbox-lakehouse.stg_finance.v6_stg_project_timeline`
  ORDER BY pushed_at DESC LIMIT 1
),
base AS (
WITH

-- ── Latest run IDs ─────────────────────────────────────────────────────────
latest_silver AS (
  SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_opex_all_rates`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_other_exp AS (
  SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_other_expenses`
  ORDER BY pushed_at DESC LIMIT 1
),
latest_lcs AS (
  SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs`
  ORDER BY pushed_at DESC LIMIT 1
),

-- ── Silver opex rates (one row per tech, all rate fields pre-joined) ────────
silver AS (
  SELECT
    s.*,
    g.trunk_escalator   AS gas_trunk_escalator,
    g.lateral_escalator AS gas_lateral_escalator
  FROM `sandbox-lakehouse.mart_finance.v6_silver_opex_all_rates` s
  LEFT JOIN (
    SELECT trunk_escalator, lateral_escalator
    FROM `sandbox-lakehouse.stg_finance.v6_stg_gas_opex`
    WHERE run_id = (
      SELECT run_id FROM `sandbox-lakehouse.stg_finance.v6_stg_gas_opex`
      ORDER BY pushed_at DESC LIMIT 1
    )
    LIMIT 1
  ) g ON TRUE
  WHERE s.run_id = (SELECT run_id FROM latest_silver)
),

-- ── Other expenses — active line items only ─────────────────────────────────
other_exp AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_other_expenses`
  WHERE run_id    = (SELECT run_id FROM latest_other_exp)
    AND unit      IS NOT NULL
    AND yr1_rate  IS NOT NULL
    AND yr1_rate  > 0
),

-- ── Operating LCs ───────────────────────────────────────────────────────────
lcs AS (
  SELECT *
  FROM `sandbox-lakehouse.stg_finance.v6_stg_operating_lcs`
  WHERE run_id = (SELECT run_id FROM latest_lcs)
    AND lc_amount_usd IS NOT NULL
    AND lc_amount_usd > 0
),

-- ── Generation monthly (needed for $/MWh and gas fuel opex) ─────────────────
gen AS (
  SELECT
    calendar_month_end,
    technology,
    monthly_generation_mwh,
    operating_year_num
  FROM `sandbox-lakehouse.fct_finance.generation_monthly`
),

-- ── Project capacity (needed for $/kW-mo unit) ──────────────────────────────
capacity AS (
  SELECT
    technology,
    installed_capacity_mw
  FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
  WHERE run_id = (
    SELECT run_id FROM `sandbox-lakehouse.mart_finance.v6_silver_capex_components`
    ORDER BY pushed_at DESC LIMIT 1
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY technology ORDER BY silver_created_at DESC) = 1
),

-- ── Timeline — operating months only ────────────────────────────────────────
timeline AS (
  SELECT
    calendar_month_end,
    calendar_year,
    calendar_month_num,
    technology,
    operating_year_num,
    operating_month_num,
    substantial_completion_date,
    end_of_useful_life_date,
    run_id,
    pushed_at
  FROM `sandbox-lakehouse.fct_finance.project_timeline_monthly`
  WHERE is_operation = TRUE
),

-- ── COMPONENT 1: Land lease ─────────────────────────────────────────────────
land_lease AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    CASE
      WHEN s.land_lease_toggle = 1 OR s.land_lease_toggle IS NULL
      THEN ROUND(
        s.land_lease_yr1_total
        * POWER(1 + COALESCE(s.land_lease_escalator, 0),
                t.operating_year_num - 1)
        / 12.0, 2)
      ELSE 0
    END AS land_lease_monthly_usd
  FROM timeline t
  JOIN silver s ON s.technology = t.technology
  WHERE t.technology NOT IN ('Gas', 'DTC')  -- Gas/DTC land lease TBD via OI-009
),

-- ── COMPONENT 2: Insurance ──────────────────────────────────────────────────
-- Standard techs use insurance_annual_premium from silver
-- DTC uses dtc_insurance_yr1 + dtc_insurance_escalation
insurance AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    CASE
      WHEN t.technology = 'DTC'
      THEN ROUND(
        COALESCE(s.dtc_insurance_yr1, 0)
        * POWER(1 + COALESCE(s.dtc_insurance_escalation, 0),
                t.operating_year_num - 1)
        / 12.0, 2)
      ELSE ROUND(
        COALESCE(s.insurance_annual_premium, 0)
        * POWER(1 + COALESCE(s.insurance_premium_rate, 0),
                t.operating_year_num - 1)
        / 12.0, 2)
    END AS insurance_monthly_usd
  FROM timeline t
  JOIN silver s ON s.technology = t.technology
),

-- ── COMPONENT 3: Property tax ───────────────────────────────────────────────
-- 3-period: before abatement / during abatement / after abatement
-- Abatement starts at abatement_start_year, lasts abatement_tenor_years
-- Reduced tax = full_annual - abatement_annual - ag_value_lost
property_tax AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      CASE
        -- Before abatement period starts
        WHEN t.calendar_year < CAST(s.abatement_start_year AS INT64)
        THEN s.property_tax_full_annual / 12.0

        -- During abatement period
        WHEN t.calendar_year >= CAST(s.abatement_start_year AS INT64)
         AND t.calendar_year <  CAST(s.abatement_start_year AS INT64)
                                + CAST(s.abatement_tenor_years AS INT64)
        THEN (s.property_tax_full_annual
              - COALESCE(s.annual_abatement_payment_usd, 0)
              - COALESCE(s.annual_ag_value_lost_usd, 0))
             / 12.0

        -- After abatement expires — full rate again
        ELSE s.property_tax_full_annual / 12.0
      END
    , 2) AS property_tax_monthly_usd
  FROM timeline t
  JOIN silver s ON s.technology = t.technology
  WHERE s.property_tax_full_annual IS NOT NULL
),

-- ── COMPONENT 4: Other expenses ─────────────────────────────────────────────
-- Join active line items to operating months, apply unit conversion + escalation
other_exp_monthly AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    e.expense_name,
    e.unit,
    ROUND(
      CASE e.unit
        -- $/Yr — annualised rate divided by 12
        WHEN '$/Yr'
        THEN e.yr1_rate
             * POWER(1 + COALESCE(e.annual_escalation, 0), t.operating_year_num - 1)
             / 12.0

        -- $/Month — already monthly
        WHEN '$/Month'
        THEN e.yr1_rate
             * POWER(1 + COALESCE(e.annual_escalation, 0), t.operating_year_num - 1)

        -- $ — one-time at start_date month only
        WHEN '$'
        THEN CASE
               WHEN t.calendar_month_end = LAST_DAY(e.start_date, MONTH)
               THEN e.yr1_rate
               ELSE 0
             END

        -- $/kW-mo — rate × installed capacity in kW
        WHEN '$/kW-mo'
        THEN e.yr1_rate
             * COALESCE(c.installed_capacity_mw, 0) * 1000.0
             * POWER(1 + COALESCE(e.annual_escalation, 0), t.operating_year_num - 1)

        -- $/MWh — rate × monthly generation
        WHEN '$/MWh'
        THEN e.yr1_rate
             * COALESCE(g.monthly_generation_mwh, 0)
             * POWER(1 + COALESCE(e.annual_escalation, 0), t.operating_year_num - 1)

        ELSE 0
      END
    , 2) AS other_exp_monthly_usd

  FROM timeline t
  JOIN other_exp e ON e.technology = t.technology
  LEFT JOIN capacity c ON c.technology = t.technology
  LEFT JOIN gen g
    ON  g.technology         = t.technology
    AND g.calendar_month_end = t.calendar_month_end

  -- Only include expense if calendar_month_end is within active window
  WHERE t.calendar_month_end >= LAST_DAY(e.start_date, MONTH)
    AND (e.end_date IS NULL
         OR t.calendar_month_end <= LAST_DAY(e.end_date, MONTH))
),

-- ── COMPONENT 5: Gas fuel opex ──────────────────────────────────────────────
-- Monthly fuel cost = gen_mwh × mmbtu_per_mwh × effective_fuel_price × escalation
-- FT reservation = (trunk_vol + lateral_vol) × respective_rates × days_in_month × escalation
gas_fuel AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      -- Variable fuel cost
      COALESCE(g.monthly_generation_mwh, 0)
      * (s.gas_mmbtu_per_mwh / 1000.0)   -- BTU/kWh → mmbtu/MWh conversion
      * s.gas_effective_fuel_price_per_mmbtu
      * POWER(1 + COALESCE(s.gas_fuel_price_escalation, 0), t.operating_year_num - 1)
      -- Trunk FT reservation (daily rate × days in month)
      + s.gas_trunk_ft_volume
        * s.gas_trunk_reservation_rate
        * (DATE_DIFF(LAST_DAY(t.calendar_month_end, MONTH), DATE_TRUNC(t.calendar_month_end, MONTH), DAY) + 1)
      * POWER(1 + COALESCE(s.gas_trunk_escalator, 0), t.operating_year_num - 1)
      -- Lateral FT reservation
      + s.gas_lateral_ft_volume
        * s.gas_lateral_reservation_rate
        * (DATE_DIFF(LAST_DAY(t.calendar_month_end, MONTH), DATE_TRUNC(t.calendar_month_end, MONTH), DAY) + 1)
      * POWER(1 + COALESCE(s.gas_lateral_escalator, 0), t.operating_year_num - 1)
    , 2) AS gas_fuel_monthly_usd

  FROM timeline t
  JOIN silver s ON s.technology = t.technology
  LEFT JOIN gen g
    ON  g.technology         = 'Gas'
    AND g.calendar_month_end = t.calendar_month_end
  WHERE t.technology = 'Gas'
),

-- ── COMPONENT 6: DTC HV maintenance ─────────────────────────────────────────
dtc_hv AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    ROUND(
      COALESCE(s.dtc_hv_maintenance_yr1, 0)
      * POWER(1 + COALESCE(s.dtc_hv_maintenance_escalation, 0),
              t.operating_year_num - 1)
      / 12.0
    , 2) AS dtc_hv_monthly_usd
  FROM timeline t
  JOIN silver s ON s.technology = t.technology
  WHERE t.technology = 'DTC'
),

-- ── COMPONENT 7: Operating LCs ──────────────────────────────────────────────
lcs_monthly AS (
  SELECT
    t.calendar_month_end,
    t.technology,
    t.operating_year_num,
    l.lc_label,
    ROUND(
      (l.lc_amount_usd / 12.0)         -- annual → monthly conversion
      * POWER(1 + COALESCE(l.escalation, 0), t.operating_year_num - 1)
    , 2) AS lc_monthly_usd
  FROM timeline t
  JOIN lcs l
    ON  l.technology         = t.technology
    AND t.calendar_month_end >= l.start_period
    AND t.calendar_month_end <= l.end_period
),

-- ── AGGREGATE all components by tech + month ─────────────────────────────────
agg_other AS (
  SELECT technology, calendar_month_end, operating_year_num,
    SUM(other_exp_monthly_usd) AS other_expenses_monthly_usd
  FROM other_exp_monthly
  GROUP BY 1, 2, 3
),

agg_lcs AS (
  SELECT technology, calendar_month_end, operating_year_num,
    SUM(lc_monthly_usd) AS lcs_monthly_usd
  FROM lcs_monthly
  GROUP BY 1, 2, 3
)

-- ── FINAL: join all components ───────────────────────────────────────────────
SELECT
  t.calendar_month_end,
  t.technology,
  t.operating_year_num,
  t.operating_month_num,

  -- Individual components
  COALESCE(ll.land_lease_monthly_usd,     0)  AS land_lease_monthly_usd,
  COALESCE(ins.insurance_monthly_usd,     0)  AS insurance_monthly_usd,
  COALESCE(pt.property_tax_monthly_usd,   0)  AS property_tax_monthly_usd,
  COALESCE(oe.other_expenses_monthly_usd, 0)  AS other_expenses_monthly_usd,
  COALESCE(gf.gas_fuel_monthly_usd,       0)  AS gas_fuel_monthly_usd,
  COALESCE(dh.dtc_hv_monthly_usd,         0)  AS dtc_hv_monthly_usd,
  COALESCE(lc.lcs_monthly_usd,            0)  AS lcs_monthly_usd,

  -- Total monthly opex
  ROUND(
    COALESCE(ll.land_lease_monthly_usd,     0)
    + COALESCE(ins.insurance_monthly_usd,   0)
    + COALESCE(pt.property_tax_monthly_usd, 0)
    + COALESCE(oe.other_expenses_monthly_usd, 0)
    + COALESCE(gf.gas_fuel_monthly_usd,     0)
    + COALESCE(dh.dtc_hv_monthly_usd,       0)
    + COALESCE(lc.lcs_monthly_usd,          0)
  , 2)                                        AS total_opex_monthly_usd,

  -- Null flags for OI-009 tracking
  CASE WHEN t.technology IN ('BESS','DTC')
       AND COALESCE(ll.land_lease_monthly_usd, 0) = 0
       AND COALESCE(ins.insurance_monthly_usd, 0) = 0
       THEN TRUE ELSE FALSE
  END                                         AS has_missing_om_inputs,

  -- Audit
  t.run_id                                    AS timeline_run_id,
  t.pushed_at                                 AS timeline_pushed_at

FROM timeline t
LEFT JOIN land_lease  ll  ON ll.technology  = t.technology AND ll.calendar_month_end  = t.calendar_month_end
LEFT JOIN insurance   ins ON ins.technology = t.technology AND ins.calendar_month_end = t.calendar_month_end
LEFT JOIN property_tax pt ON pt.technology  = t.technology AND pt.calendar_month_end  = t.calendar_month_end
LEFT JOIN agg_other   oe  ON oe.technology  = t.technology AND oe.calendar_month_end  = t.calendar_month_end
LEFT JOIN gas_fuel    gf  ON gf.technology  = t.technology AND gf.calendar_month_end  = t.calendar_month_end
LEFT JOIN dtc_hv      dh  ON dh.technology  = t.technology AND dh.calendar_month_end  = t.calendar_month_end
LEFT JOIN agg_lcs     lc  ON lc.technology  = t.technology AND lc.calendar_month_end  = t.calendar_month_end

ORDER BY t.technology, t.calendar_month_end
)
SELECT
  b.calendar_month_end, b.technology, b.operating_year_num, b.operating_month_num,
  b.land_lease_monthly_usd, b.insurance_monthly_usd, b.property_tax_monthly_usd,
  b.other_expenses_monthly_usd, b.gas_fuel_monthly_usd, b.dtc_hv_monthly_usd,
  b.lcs_monthly_usd, b.total_opex_monthly_usd, b.has_missing_om_inputs,
  b.timeline_run_id, b.timeline_pushed_at,
  c.run_id, c.pushed_at,
  'Monthly_Haul_04_2026' AS run_label,
  CURRENT_TIMESTAMP() AS created_at
FROM base b
CROSS JOIN canonical c;