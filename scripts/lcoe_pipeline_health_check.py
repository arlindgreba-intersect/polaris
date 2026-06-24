#!/usr/bin/env python3
"""
LCOE pipeline health check.

Runs basic sanity checks against the LCOE pipeline tables in BigQuery using the
`bq` CLI (assumes `bq` is already authenticated for project sandbox-lakehouse).

Checks:
  - Table exists and has > 0 rows
  - For fct tables: when --run_id is given, that run_id has rows
  - For stg tables: no nulls in run_id

Usage:
  python scripts/lcoe_pipeline_health_check.py
  python scripts/lcoe_pipeline_health_check.py --run_id <RUN_LABEL_OR_ID>

Out of scope:
  - The forecast-tool tables (v6_raw_forecast_inputs, v6_stg_forecast_inputs,
    v6_forecast_*). Run a separate health check for those.
  - The deprecated v6_fct_* tables in fct_finance (last updated 2026-06-21).
"""

import argparse
import csv
import io
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

PROJECT = "sandbox-lakehouse"

# ----------------------------------------------------------------------------
# Table inventory -- only ACTIVE LCOE pipeline objects.
# Forecast tool, pre-v6 legacy, tmp tables, and deprecated v6_fct_* excluded.
# ----------------------------------------------------------------------------

RAW_TABLES = [
    "v6_raw_inputs_tab",
    "v6_raw_capex_tool",
    "v6_raw_opex_tool",
    "v6_raw_lcoe_calcs",
    "v6_raw_pro_forma_summary",
    "v6_raw_sign_off_sheet",
    "v6_ref_macrs_schedule",
]

# Staging -- 12 Dataform-built + 8 legacy still being maintained by manual SQL.
STG_TABLES_DATAFORM = [
    "v6_stg_lcoe_model_controls",
    "v6_stg_project_timeline",
    "v6_stg_project_capacity",
    "v6_stg_generation_seasonality",
    "v6_stg_degradation",
    "v6_stg_tax_attributes",
    "v6_stg_financing_fees",
    "v6_stg_contingency",
    "v6_stg_capex_unit_cost",
    "v6_stg_opex_rates",
    "v6_stg_insurance",
    "v6_stg_property_tax",
]
STG_TABLES_LEGACY = [
    "v6_stg_franchise_tax",
    "v6_stg_land_lease",
    "v6_stg_other_expenses",
    "v6_stg_gas_opex",
    "v6_stg_dtc_opex",
    "v6_stg_operating_lcs",
    "v6_stg_om_schedules",
    "v6_stg_opex_lifetime_totals",  # legacy copy still in stg_finance
]

SILVER_TABLES = [
    "v6_silver_project_inputs",
    "v6_silver_capex_components",
    "v6_silver_opex_all_rates",
    "v6_silver_generation_profile",
    "v6_silver_itc_inputs",
    "v6_silver_operating_lcs",
]

FCT_TABLES = [
    "project_timeline_monthly",
    "project_capex_monthly",
    "project_opex_monthly",
    "generation_monthly",
    "revenue_monthly",       # known $0 placeholder per OI-005
    "tax_credit_monthly",
    "depreciation_monthly",
    "lcoe_component_annual",
    "lcoe_facility_summary",
    "stg_opex_lifetime_totals",  # the *new* one in fct_finance
]

DIM_TABLES = ["dim_month", "dim_year"]

# Tables where revenue is intentionally zero (OI-005 placeholder). The row-count
# check still passes for these because they have rows; we just don't expect a
# non-zero spend column.
PLACEHOLDER_ZERO_TABLES = {"revenue_monthly"}


@dataclass
class CheckResult:
    fqtn: str       # fully qualified table name
    name: str       # which check (e.g. "row count")
    passed: bool
    detail: str     # human-readable detail printed on the line


# ----------------------------------------------------------------------------
# BQ helper
# ----------------------------------------------------------------------------

def bq_csv(sql: str) -> list[list[str]]:
    """Run a BQ query, return parsed CSV rows (including header).

    Uses shell=True on Windows because `bq` resolves to `bq.cmd` which is a
    batch wrapper that PowerShell/cmd finds via PATHEXT, but raw CreateProcess
    does not.
    """
    cmd = (
        'bq query --use_legacy_sql=false --format=csv --quiet --max_rows=10 '
        f'"{sql}"'
    )
    proc = subprocess.run(cmd, capture_output=True, text=True, shell=True)
    if proc.returncode != 0:
        raise RuntimeError(f"bq query failed:\n  sql: {sql}\n  err: {proc.stderr.strip()}")
    rows = list(csv.reader(io.StringIO(proc.stdout)))
    return rows


def get_row_count(fqtn: str) -> Optional[int]:
    """Return total row count or None if the table doesn't exist."""
    try:
        rows = bq_csv(f"SELECT COUNT(*) AS n FROM `{fqtn}`")
    except RuntimeError as e:
        if "Not found" in str(e) or "does not exist" in str(e):
            return None
        raise
    return int(rows[1][0]) if len(rows) > 1 else 0


def get_run_id_count(fqtn: str, run_id: str) -> int:
    """Count rows matching either run_id or run_label."""
    rows = bq_csv(
        f"SELECT COUNT(*) AS n FROM `{fqtn}` "
        f"WHERE run_id = '{run_id}' OR run_label = '{run_id}'"
    )
    return int(rows[1][0])


def has_null_run_id(fqtn: str) -> int:
    rows = bq_csv(f"SELECT COUNTIF(run_id IS NULL) AS n FROM `{fqtn}`")
    return int(rows[1][0])


# ----------------------------------------------------------------------------
# Check runners
# ----------------------------------------------------------------------------

def check_existence_and_rows(fqtn: str, allow_zero: bool = False) -> CheckResult:
    n = get_row_count(fqtn)
    if n is None:
        return CheckResult(fqtn, "exists", False, "table not found")
    if n == 0 and not allow_zero:
        return CheckResult(fqtn, "row count", False, "0 rows (expected > 0)")
    return CheckResult(fqtn, "row count", True, f"{n:,} rows")


def check_run_id_present(fqtn: str, run_id: str) -> CheckResult:
    try:
        n = get_run_id_count(fqtn, run_id)
    except RuntimeError as e:
        return CheckResult(fqtn, "run_id present", False, f"query error: {e}")
    if n == 0:
        return CheckResult(fqtn, "run_id present", False, f"no rows for run_id='{run_id}'")
    return CheckResult(fqtn, "run_id present", True, f"{n:,} rows for run_id")


def check_null_run_id(fqtn: str) -> CheckResult:
    try:
        n = has_null_run_id(fqtn)
    except RuntimeError as e:
        # run_id column may not exist on every legacy table -- that's a known
        # issue not a hard failure for the run.
        return CheckResult(fqtn, "null run_id", False, f"could not check (column missing?): {e}")
    if n > 0:
        return CheckResult(fqtn, "null run_id", False, f"{n:,} rows have NULL run_id")
    return CheckResult(fqtn, "null run_id", True, "no nulls in run_id")


# ----------------------------------------------------------------------------
# Reporting
# ----------------------------------------------------------------------------

def print_result(r: CheckResult) -> None:
    tag = "[PASS]" if r.passed else "[FAIL]"
    print(f"{tag} {r.fqtn:<48s} -- {r.name:<16s} -- {r.detail}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run_id", default=None,
                    help="Optional run_id or run_label to verify in fct tables")
    args = ap.parse_args()

    results: list[CheckResult] = []

    def add(r: CheckResult) -> None:
        results.append(r)
        print_result(r)

    print(f"LCOE pipeline health check -- project={PROJECT}")
    if args.run_id:
        print(f"Filtering fct checks on run_id/run_label = '{args.run_id}'")
    print()

    # --- raw ---
    print("== polaris_raw ==")
    for t in RAW_TABLES:
        add(check_existence_and_rows(f"{PROJECT}.polaris_raw.{t}"))
    add(check_existence_and_rows(f"{PROJECT}.polaris_raw.run_audit"))

    # --- stg (Dataform) ---
    print("\n== stg_finance (Dataform-built) ==")
    for t in STG_TABLES_DATAFORM:
        fqtn = f"{PROJECT}.stg_finance.{t}"
        add(check_existence_and_rows(fqtn))
        add(check_null_run_id(fqtn))

    # --- stg (legacy still in use) ---
    print("\n== stg_finance (legacy, not in Dataform yet) ==")
    for t in STG_TABLES_LEGACY:
        fqtn = f"{PROJECT}.stg_finance.{t}"
        add(check_existence_and_rows(fqtn))
        add(check_null_run_id(fqtn))

    # --- silver ---
    print("\n== mart_finance (silver) ==")
    for t in SILVER_TABLES:
        add(check_existence_and_rows(f"{PROJECT}.mart_finance.{t}"))

    # --- fct ---
    print("\n== fct_finance ==")
    for t in FCT_TABLES:
        fqtn = f"{PROJECT}.fct_finance.{t}"
        # revenue_monthly is OK to have all-zero values; it must still have rows
        add(check_existence_and_rows(fqtn))
        if args.run_id:
            add(check_run_id_present(fqtn, args.run_id))

    # --- dim ---
    print("\n== dim_time ==")
    for t in DIM_TABLES:
        add(check_existence_and_rows(f"{PROJECT}.dim_time.{t}"))

    # --- summary ---
    n_pass = sum(1 for r in results if r.passed)
    n_fail = sum(1 for r in results if not r.passed)
    status = "HEALTHY" if n_fail == 0 else "NEEDS ATTENTION"
    print()
    print("=" * 78)
    print(f"{n_pass} checks passed, {n_fail} checks failed")
    print(f"Pipeline status: {status}")
    print("=" * 78)

    # Print every failure again at the bottom for quick scanning.
    if n_fail:
        print("\nFailed checks:")
        for r in results:
            if not r.passed:
                print(f"  {r.fqtn} -- {r.name}: {r.detail}")

    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
