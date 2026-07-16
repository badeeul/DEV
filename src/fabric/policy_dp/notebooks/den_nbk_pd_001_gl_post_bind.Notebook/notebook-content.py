# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "b6adb647-6f2d-4cc8-b9e2-9a1201642b6a",
# META       "default_lakehouse_name": "den_lhw_dpr_001_policy_product",
# META       "default_lakehouse_workspace_id": "a5b83bde-449c-4623-a821-90f37a02ac15"
# META     },
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# CELL ********************

import re
import uuid
import requests
import xml.etree.ElementTree as ET
import pandas as pd
from datetime import datetime
from pyspark.sql.types import (
    StringType,
    IntegerType,
    TimestampType
)
from pyspark.sql import functions as F

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

# Proxy environment: "prod" or "test".
# Switch this single value to flip every LexisNexis call between the live and
# test endpoints (see the PROXY_ENDPOINT cell just below):
#   prod -> https://.../api/proxy/call
#   test -> https://.../api/proxy/call-test
proxy_env = "prod"

# Proxy base endpoint. The "-test" suffix and final PROXY_ENDPOINT are derived in
# the cell BELOW the parameters cell based on proxy_env above.
_PROXY_BASE = "https://bhg-prod-dna-appsvcs-eus-app.azurewebsites.net/api/proxy/call"

# Proxy API key (x-api-key header)
PROXY_API_KEY = "lexisnexis_proxy_51Q7k8L2mN3pQ4rS5tU6vW7xY8zAbCdEfGhIjKlMnOpQrStUvWxYzAb"

# Run controls
LOB_FILTER = "GL"

# NAICS Blacklist - ineligible codes (4/5/6-digit prefixes)
NAICS_BLACKLIST = {
    "2371": "Utility System Construction",
    "2372": "Land Subdivision",
    "2373": "Highway, Street, and Bridge Construction",
    "2379": "Other Heavy and Civil Engineering Construction",
    "2389": "Other Specialty Trade Contractors",
    "23621": "Industrial Building Construction",
    "23622": "Commercial and Institutional Building Construction",
    "23811": "Poured Concrete Foundation and Structure Contractors",
    "23812": "Structural Steel and Precast Concrete Contractors",
    "23816": "Roofing Contractors",
    "23817": "Siding Contractors",
    "23819": "Other Foundation, Structure, and Building Exterior Contractors",
    "23829": "Other Building Equipment Contractors",
    "23831": "Drywall and Insulation Contractors",
    "236116": "New Multifamily Housing Construction (except For-Sale Builders)",
}

def _match_single_naics(naics_code):
    """Return (matched_prefix, description) if naics starts with a blacklisted
    prefix, else (None, None)."""
    if not naics_code:
        return (None, None)
    code = str(naics_code).strip()
    # Check longest prefix first for most specific match
    for length in (6, 5, 4):
        prefix = code[:length]
        if prefix in NAICS_BLACKLIST:
            return (prefix, NAICS_BLACKLIST[prefix])
    return (None, None)


def check_naics_blacklist(naics_1, naics_2=None, naics_3=None):
    """Match all three LexisNexis NAICS ranks against the blacklist.

    Returns (flag, matched_code, description) where flag is the RANK of the
    first NAICS that hits the blacklist ("1", "2", or "3", checked in that
    order) instead of a plain "Y"/"N". If none of the three match, flag is
    "N" and matched_code/description are None.
    """
    for rank, code in (("1", naics_1), ("2", naics_2), ("3", naics_3)):
        prefix, desc = _match_single_naics(code)
        if prefix is not None:
            return (rank, prefix, desc)
    return ("N", None, None)


def parse_naics_from_response(response_body):
    """
    Parse NAICS values directly from the raw LexisNexis Commercial Data Prefill
    SOAP response (Risk XML).

    Per the LN implementation guide:
      - Firmographics/NAICCodes1 is the PRIMARY NAICS (Code + Description).
      - EnhancedFirmographics/NAICCodes1ConfScore is the confidence for the
        primary NAICS (requires EnhancedFirmographics=true in the request).
      - NAICCodes2 / NAICCodes3 are ranked alternates (Code + Description only;
        the firmographic block does NOT carry a per-alternate confidence score,
        so naics_2_conf / naics_3_conf are populated only if LN ever returns one).

    Returns a dict with: naics_code, naics_description, confidence_score,
    naics_2, naics_2_desc, naics_2_conf, naics_3, naics_3_desc, naics_3_conf.
    """
    out = {
        "naics_code": None, "naics_description": None, "confidence_score": None,
        "naics_2": None, "naics_2_desc": None, "naics_2_conf": None,
        "naics_3": None, "naics_3_desc": None, "naics_3_conf": None,
    }
    if not response_body:
        return out
    try:
        root = ET.fromstring(response_body)
    except Exception:
        return out

    def lname(el):
        return el.tag.rsplit("}", 1)[-1]

    def child(parent, name):
        for c in parent:
            if lname(c) == name:
                return c
        return None

    def child_text(parent, name):
        c = child(parent, name)
        if c is not None and c.text is not None:
            return c.text.strip() or None
        return None

    # Locate the real Firmographics result block (skip the <Firmographics>true</>
    # toggle that lives under Sources).
    firmo = None
    for el in root.iter():
        if lname(el) == "Firmographics" and any(
            lname(c) in ("Status", "BusinessIdentity", "CompanyName", "NAICCodes1")
            for c in el
        ):
            firmo = el
            break
    if firmo is None:
        return out

    # NAICCodes1/2/3 -> code + description (+ ConfScore if ever present inline)
    rank_map = {
        1: ("naics_code", "naics_description", None),
        2: ("naics_2", "naics_2_desc", "naics_2_conf"),
        3: ("naics_3", "naics_3_desc", "naics_3_conf"),
    }
    for rank, (k_code, k_desc, k_conf) in rank_map.items():
        node = child(firmo, f"NAICCodes{rank}")
        if node is not None:
            out[k_code] = child_text(node, "Code")
            out[k_desc] = child_text(node, "Description")
            if k_conf is not None:
                out[k_conf] = child_text(node, "ConfScore")

    # Primary NAICS confidence = EnhancedFirmographics/.../NAICCodes1ConfScore
    for el in firmo.iter():
        if lname(el) == "NAICCodes1ConfScore" and el.text:
            out["confidence_score"] = el.text.strip() or None
            break

    return out

trigger_time = "1900-01-01T00:00:00Z"
pipeline_name = "dfa_pln_dpr_001_gl_post_bind"
workspace_id = "00000000-0000-0000-0000-000000000000"
pipeline_id = "00000000-0000-0000-0000-000000000000"
run_id = str(uuid.uuid4())

print("run_id:", run_id)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Derive PROXY_ENDPOINT AFTER the parameters cell so the pipeline-provided
# proxy_env override is in effect (Fabric injects the parameter override as a
# cell that runs immediately after the PARAMETERS cell).
#   prod -> https://.../api/proxy/call
#   test -> https://.../api/proxy/call-test
PROXY_ENDPOINT = _PROXY_BASE if str(proxy_env).strip().lower() == "prod" else f"{_PROXY_BASE}-test"
print(f"proxy_env={proxy_env} -> PROXY_ENDPOINT={PROXY_ENDPOINT}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Compute issued date range: Monday of prior week through Sunday of current week
from datetime import timedelta
_today = datetime.utcnow().date()
_days_since_sunday = (_today.weekday() + 1) % 7
_issued_high_sunday = _today - timedelta(days=_days_since_sunday)
_issued_low_monday = _issued_high_sunday - timedelta(days=6)
ISSUED_LOW = str(_issued_low_monday)
ISSUED_HIGH = str(_issued_high_sunday)
print(f"Issued date range: {ISSUED_LOW} to {ISSUED_HIGH}")

spark.sql(f"""
CREATE OR REPLACE VIEW policy.vw_gl_cdpf_candidates AS
SELECT
    dn.naics_bus_key                         AS `NAICS Code (Agent Entered)`,
    dp.policy_num_bus_key                    AS `Policy Code`,
    trim(di.insd_nm)                         AS `Insured Name`,
    CAST(NULL AS STRING)                     AS `DBA (Doing Business As)`,

    dbc.bus_class_cd_bus_key                 AS `Class Codes (Agent entered)`,
    dbc.bus_class_desc                       AS `Description of Class Codes`,
    dbc.bus_class_suffix_bus_key             AS `Suffixes`,

    ddc.agcy_cd_bus_key                      AS `Agency Code`,
    CAST(dp.policy_effec_start_dt AS STRING)  AS `Inception`,
    fp.dw_prem                               AS `YTD Prem`,
    dp.gov_state                             AS `Gov State`,

    dn.naics_industry                        AS `Industry`,
    dn.naics_sub_industry                    AS `Sub Industry`,
    dn.naics_bus_type                        AS `Bus. Type`,

    CAST(NULL AS DECIMAL(19,4))              AS `Payroll (Exposure)`,
    CAST(NULL AS DECIMAL(19,4))              AS `Revenue (Exposure)`,

    dp.policy_issue_dt                       AS `poissue`,
    dl.lob_cd_bus_key                        AS `lob`,
    di.mail_add1                             AS `address1`,
    di.mail_add2                             AS `address2`,
    di.mail_city                             AS `city`,
    di.mail_state                            AS `state`,
    substring(trim(di.mail_zip), 1, 5)       AS `zip5`,

    dmt.mkt_type_cd_bus_key                  AS `markettype`,
    dps.prod_src_cd_bus_key                  AS `productionsrc`

FROM policy.fact_policy fp
JOIN policy.dim_policy dp
    ON fp.policy_key = dp.policy_key
    AND dp.dl_is_current_flag = true
JOIN policy.dim_lob dl
    ON fp.lob_key = dl.lob_key
    AND dl.dl_is_current_flag = true
LEFT JOIN policy.dim_insured di
    ON di.policy_num_bus_key = dp.policy_num_bus_key
    AND di.dl_is_current_flag = true

LEFT JOIN policy.dim_mkt_type dmt
    ON fp.mkt_type_key = dmt.mkt_type_key
    AND dmt.dl_is_current_flag = true
LEFT JOIN policy.dim_prod_src dps
    ON fp.prod_src_key = dps.prod_src_key
    AND dps.dl_is_current_flag = true
LEFT JOIN policy.dim_dist_chnl ddc
    ON fp.dist_chnl_key = ddc.dist_chnl_key
    AND ddc.dl_is_current_flag = true

LEFT JOIN policy.dim_naics dn
    ON fp.naics_key = dn.naics_key
    AND dn.dl_is_current_flag = true
LEFT JOIN policy.dim_business_class dbc
    ON fp.gov_bus_class_key = dbc.bus_class_key
    AND dbc.dl_is_current_flag = true

WHERE
    dl.lob_cd_bus_key = '{LOB_FILTER}'
    AND fp.dl_is_current_flag = true
    AND fp.policy_issue_dt_key <> -1
    AND CAST(dp.policy_issue_dt AS DATE) BETWEEN '{ISSUED_LOW}' AND '{ISSUED_HIGH}'
    AND ddc.agcy_cd_bus_key <> 'PAFAKE10'
""")
print("âœ… View created: policy.vw_gl_cdpf_candidates")
display(spark.table("policy.vw_gl_cdpf_candidates").limit(25))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

spark.sql("""
CREATE TABLE IF NOT EXISTS policy.fact_gl_cdpf_enrichment (
    run_id                STRING,
    policy_code           STRING,
    insured_name          STRING,
    street_number         STRING,
    street_name           STRING,
    city                  STRING,
    state                 STRING,
    zip5                  STRING,

    naics_code_agent      STRING,
    dba                   STRING,
    class_codes           STRING,
    class_desc            STRING,
    suffixes              STRING,
    agency_code           STRING,
    inception             STRING,
    agency_uw             STRING,
    ytd_prem              STRING,
    industry              STRING,
    sub_industry          STRING,
    bus_type              STRING,
    payroll               STRING,
    revenue               STRING,

    http_status           INT,
    ln_response_flag      STRING,
    naics_code            STRING,
    confidence_score      STRING,
    requested_endpoint    STRING,
    response_body         STRING,
    naics_description     STRING,
    naics_2               STRING,
    naics_2_desc          STRING,
    naics_2_conf          STRING,
    naics_3               STRING,
    naics_3_desc          STRING,
    naics_3_conf          STRING,
    naics_blacklist_flag  STRING,
    blacklisted_naics     STRING,
    blacklisted_naics_desc STRING,
    exposure_basis        STRING,
    location_address      STRING,
    request_ts            TIMESTAMP
)
USING DELTA
""")
print("✅ policy.fact_gl_cdpf_enrichment ready")

# Idempotently add the NAICS alternate columns to any pre-existing table
# (CREATE TABLE IF NOT EXISTS will not alter a table that already exists).
for _col in [
    "naics_2 STRING", "naics_2_desc STRING", "naics_2_conf STRING",
    "naics_3 STRING", "naics_3_desc STRING", "naics_3_conf STRING",
]:
    try:
        spark.sql(f"ALTER TABLE policy.fact_gl_cdpf_enrichment ADD COLUMNS ({_col})")
    except Exception:
        pass

display(spark.table("policy.vw_gl_cdpf_candidates").limit(10))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def parse_address(addr: str):
    import re

    if addr is None:
        return ("", "")

    addr = str(addr).strip()

    if addr == "":
        return ("", "")

    s = re.sub(r"[,.;]", " ", addr)
    s = re.sub(r"\s+", " ", s).strip()

    m = re.match(r"^(\d+)\s+(.*)$", s)

    if m:
        return (m.group(1), m.group(2))
    else:
        return ("", s)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

candidates_df = spark.table("policy.vw_gl_cdpf_candidates")

# Enrich with curated layer data (YTD Prem, Industry, Sub Industry, Bus. Type, DBA)
curated_insured = spark.table("den_lhw_scu_001_policy_curated.policy.insured") \
    .filter("lower(trim(code)) = lower(trim(basemgacode))") \
    .selectExpr(
        "lower(trim(code)) as _ci_code",
        "CAST(poytdprem AS STRING) as _ytd_prem"
    ) \
    .dropDuplicates(["_ci_code"])

curated_wcinfo = spark.table("den_lhw_scu_001_policy_curated.policy.wcinfo") \
    .selectExpr(
        "lower(trim(code)) as _w_code",
        "industry as _w_industry",
        "subindustry as _w_subindustry",
        "businesstype as _w_businesstype"
    ) \
    .dropDuplicates(["_w_code"])

curated_industry = spark.table("den_lhw_scu_001_policy_curated.policy.industry") \
    .selectExpr("lower(trim(industry)) as _ind_key", "descrip as _industry_desc") \
    .dropDuplicates(["_ind_key"])

curated_subindustry = spark.table("den_lhw_scu_001_policy_curated.policy.subindustry") \
    .selectExpr("lower(trim(subindustry)) as _subind_key", "descrip as _sub_industry_desc") \
    .dropDuplicates(["_subind_key"])

curated_businesstype = spark.table("den_lhw_scu_001_policy_curated.policy.businesstype") \
    .selectExpr("lower(trim(businesstype)) as _bt_key", "businessdescrip as _bus_type_desc") \
    .dropDuplicates(["_bt_key"])

curated_dba = spark.table("den_lhw_scu_001_policy_curated.policy.wclocnam") \
    .filter("biztype = 'T' AND uselocnum = 'A'") \
    .selectExpr("lower(trim(code)) as _dba_code", "text as _dba_text") \
    .dropDuplicates(["_dba_code"])


# Transaction classcode: filter to current records (trancnt=0, after=1) per analyst SQL
curated_classcode = spark.table("den_lhw_scu_001_policy_curated.policy.transaction_classcode") \
    .filter(f"lower(trim(lob)) = lower('{LOB_FILTER}') AND trancnt = 0 AND after = 1") \
    .withColumn("_cc_code", F.lower(F.trim(F.col("code"))))

# Exposure + basis are carried straight from transaction_classcode (see
# curated_cc_details below), mirroring the analyst query which reads
# [Exposure] = tc.exposure and [Exposure Basis] = tc.basis per class-code row
# with NO basis='p' filter and NO SUM. (The old basis='p'-only curated_payroll
# CTE was dropped because it hid every non-payroll basis, e.g. sales/receipts.)

curated_revenue = curated_classcode \
    .filter("lower(trim(basis)) IN ('s', 'r')") \
    .groupBy("_cc_code") \
    .agg(F.sum(F.col("exposure").cast("decimal(19,4)")).alias("_revenue")) \
    .withColumnRenamed("_cc_code", "_rev_code") \
    .dropDuplicates(["_rev_code"])

# Class code, description, suffix, exposure basis, and exposure -- all pulled
# from the SAME transaction_classcode row (more accurate than dim for GL, and
# matches the analyst query where class/desc/suffix/basis/exposure all come
# from tc). Grained per (policy code, class) so every class code keeps its own
# exposure + basis; exposure is comma-stripped like replace(tc.exposure,',','').
curated_cc_details = curated_classcode \
    .selectExpr(
        "_cc_code as _ccd_code",
        "lower(trim(CAST(class AS STRING))) as _ccd_class_key",
        "CAST(class AS STRING) as _tc_class",
        "description as _tc_description",
        "CAST(classsuffix AS STRING) as _tc_classsuffix",
        "basis as _exposure_basis",
        "CAST(regexp_replace(CAST(exposure AS STRING), ',', '') AS decimal(19,4)) as _exposure"
    ) \
    .dropDuplicates(["_ccd_code", "_ccd_class_key"])

# DBA: aggregate all DBA names with ';' separator (matches analyst STRING_AGG pattern)
curated_dba_agg = spark.table("den_lhw_scu_001_policy_curated.policy.wclocnam") \
    .filter("biztype = 'T' AND uselocnum = 'A'") \
    .withColumn("_dba_agg_code", F.lower(F.trim(F.col("code")))) \
    .groupBy("_dba_agg_code") \
    .agg(F.concat_ws(";", F.collect_set("text")).alias("_dba_agg_text"))

# Insured name: prefer wclocnam type='n' uselocnum='n' (legal name), fallback to dim_insured
curated_insnm = spark.table("den_lhw_scu_001_policy_curated.policy.wclocnam") \
    .filter("type = 'n' AND uselocnum = 'n'") \
    .selectExpr("lower(trim(code)) as _insnm_code", "text as _insured_name_legal") \
    .dropDuplicates(["_insnm_code"])

# Location address from wclocnam via transaction_classcode loctypenum
curated_loc_addr = spark.table("den_lhw_scu_001_policy_curated.policy.wclocnam") \
    .selectExpr(
        "lower(trim(code)) as _loc_code",
        "loctypenum as _loc_loctypenum",
        "text as _loc_address"
    )

curated_cc_loc = curated_classcode \
    .selectExpr("_cc_code as _ccl_code", "loctypenum as _ccl_loctypenum") \
    .dropDuplicates(["_ccl_code"]) \
    .join(
        curated_loc_addr,
        (F.col("_ccl_code") == F.col("_loc_code")) & (F.col("_ccl_loctypenum") == F.col("_loc_loctypenum")),
        "left"
    ) \
    .select("_ccl_code", "_loc_address") \
    .dropDuplicates(["_ccl_code"])

# Revenue from transaction_wclocnam_locationextra (annualsalesorrevenue)
curated_locextra = spark.table("den_lhw_scu_001_policy_curated.policy.transaction_wclocnam_locationextra") \
    .filter("trancnt = 0 AND after = 1") \
    .withColumn("_lx_code", F.lower(F.trim(F.col("code")))) \
    .groupBy("_lx_code") \
    .agg(F.sum(F.col("annualsalesorrevenue").cast("decimal(19,4)")).alias("_annual_revenue")) \
    .dropDuplicates(["_lx_code"])

# Agency UW = employee.name where empcode = agency.sbr (matches fn_uw_op_GetAGYUW for GL).
# For GL the UWT-team lookup always falls back to the agency's SBR usercode, which
# maps directly to employee.name. Validated against golden policies.
curated_agency = spark.table("den_lhw_scu_001_policy_curated.policy.agency") \
    .selectExpr("lower(trim(agency)) as _agy_code", "lower(trim(sbr)) as _agy_sbr") \
    .dropDuplicates(["_agy_code"])

curated_agency_uw = spark.table("den_lhw_scu_001_policy_curated.policy.employee") \
    .selectExpr("lower(trim(empcode)) as _agyuw_empcode", "name as _agency_uw") \
    .dropDuplicates(["_agyuw_empcode"])

# Join curated data to candidates
enriched_df = candidates_df \
    .withColumn("_join_key", F.lower(F.trim(F.col("`Policy Code`")))) \
    .join(curated_insured, F.col("_join_key") == curated_insured["_ci_code"], "left") \
    .join(curated_wcinfo, F.col("_join_key") == curated_wcinfo["_w_code"], "left") \
    .join(curated_industry, F.lower(F.trim(F.col("_w_industry"))) == curated_industry["_ind_key"], "left") \
    .join(curated_subindustry, F.lower(F.trim(F.col("_w_subindustry"))) == curated_subindustry["_subind_key"], "left") \
    .join(curated_businesstype, F.lower(F.trim(F.col("_w_businesstype"))) == curated_businesstype["_bt_key"], "left") \
    .join(curated_dba, F.col("_join_key") == curated_dba["_dba_code"], "left") \
    .join(curated_dba_agg, F.col("_join_key") == curated_dba_agg["_dba_agg_code"], "left") \
    .join(curated_insnm, F.col("_join_key") == curated_insnm["_insnm_code"], "left") \
    .join(curated_revenue, F.col("_join_key") == curated_revenue["_rev_code"], "left") \
    .join(curated_cc_details, F.col("_join_key") == curated_cc_details["_ccd_code"], "left") \
    .join(curated_cc_loc, F.col("_join_key") == curated_cc_loc["_ccl_code"], "left") \
    .join(curated_locextra, F.col("_join_key") == curated_locextra["_lx_code"], "left") \
    .join(curated_agency, F.lower(F.trim(F.col("`Agency Code`"))) == curated_agency["_agy_code"], "left") \
    .join(curated_agency_uw, F.col("_agy_sbr") == curated_agency_uw["_agyuw_empcode"], "left") \
    .drop("_join_key", "_ci_code", "_w_code", "_w_industry", "_w_subindustry", "_w_businesstype", "_ind_key", "_subind_key", "_bt_key", "_dba_code", "_dba_agg_code", "_insnm_code", "_rev_code", "_ccd_code", "_ccd_class_key", "_ccl_code", "_lx_code", "_agy_code", "_agy_sbr", "_agyuw_empcode")

pdf = enriched_df.toPandas()

pdf.columns = (
    pdf.columns
        .str.lower()
        .str.replace(" ", "_")
        .str.replace(".", "", regex=False)
        .str.replace("(", "", regex=False)
        .str.replace(")", "", regex=False)
)

# Deduplicate: keep the row with the most non-null/non-"unknown" values per
# policy + class code. A policy can carry multiple agent-entered class codes
# (each is its own row from dim_business_class), and every one must survive as
# its own output row. All curated look-ups are deduped to one row per policy,
# so they never fan out — the only legitimate multi-row source is the class
# code. Dedup therefore keys on (policy_code, class code), not policy alone.
def _row_quality(row):
    """Score a row by how many useful values it has."""
    score = 0
    for v in row:
        s = str(v).strip().lower() if v is not None and str(v).strip() else ""
        if s and s != "unknown" and s != "0" and s != "0.0000" and not s.startswith("java.util"):
            score += 1
    return score

if "policy_code" in pdf.columns and len(pdf) > 0:
    # Effective class = curated tc.class when present, else the dim governing
    # class. Dedup per (policy, effective class) so every transaction_classcode
    # class keeps its own row -- matches the analyst query, which drives one row
    # per tc class (joined on policy code alone) with its own exposure + basis.
    if "_tc_class" in pdf.columns and "class_codes_agent_entered" in pdf.columns:
        pdf["_dedup_class"] = pdf["_tc_class"].fillna(pdf["class_codes_agent_entered"])
    elif "_tc_class" in pdf.columns:
        pdf["_dedup_class"] = pdf["_tc_class"]
    elif "class_codes_agent_entered" in pdf.columns:
        pdf["_dedup_class"] = pdf["class_codes_agent_entered"]
    else:
        pdf["_dedup_class"] = ""
    pdf["_quality"] = pdf.apply(_row_quality, axis=1)
    pdf = pdf.sort_values("_quality", ascending=False).drop_duplicates(subset=["policy_code", "_dedup_class"], keep="first")
    pdf = pdf.drop(columns=["_quality", "_dedup_class"]).reset_index(drop=True)

print(f"Rows after dedup: {len(pdf)}")

parsed = pdf["address1"].apply(parse_address)

# âœ… force valid shape
parsed = parsed.apply(
    lambda x: x if isinstance(x, tuple) and len(x) == 2 else ("", "")
)

# ✅ extract explicitly
pdf["street_number"] = parsed.apply(lambda x: x[0])
pdf["street_name"] = parsed.apply(lambda x: x[1])

display(pdf.head())

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

pdf["street_number"] = pdf["street_number"].fillna("").astype(str)
pdf["street_name"] = pdf["street_name"].fillna("").astype(str)
pdf["city"] = pdf["city"].fillna("").astype(str)
pdf["state"] = pdf["state"].fillna("").astype(str)
pdf["zip5"] = pdf["zip5"].fillna("").astype(str)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

results = []

headers = {
    "accept": "application/json",
    "Content-Type": "application/json",
    "x-api-key": PROXY_API_KEY
}

print(f"Rows after filtering: {len(pdf)}")

for _, row in pdf.iterrows():
    payload = {
        "business_name": row["insured_name"],
        "street_number": row["street_number"],
        "street_name": row["street_name"],
        "city": row["city"],
        "state": row["state"],
        "zip5": row["zip5"],
        "unit": "",
        "quote_value": row["policy_code"],
        # Request the EnhancedFirmographics source so the response includes
        # NAICCodes1ConfScore (the confidence for the primary NAICS).
        # NOTE: the proxy must honor this flag and set
        # <EnhancedFirmographics>true</EnhancedFirmographics> in the SOAP Sources.
        "enhanced_firmographics": True,
        "timeout_seconds": 40
    }

    resp = requests.post(
        PROXY_ENDPOINT,
        headers=headers,
        json=payload,
        timeout=60
    )

    try:
        body = resp.json()
    except Exception:
        body = {"response_body": resp.text}

    # Parse NAICS straight from the raw LN SOAP (doc-correct: NAICCodes1 = Primary).
    _rb = body.get("response_body", resp.text)
    _naics = parse_naics_from_response(_rb)

    # Primary NAICS = NAICCodes1 (fall back to the proxy-flattened value if the
    # parse misses, e.g. NO_MATCH or unexpected payload).
    _naics_code = _naics["naics_code"] or body.get("naics_code")
    _naics_desc = _naics["naics_description"] or body.get("naics_description")

    # Confidence = NAICCodes1ConfScore, straight from EnhancedFirmographics
    # (which is now enabled in the request). No fallback to any other source.
    _naics_conf = _naics["confidence_score"]

    # Match all three NAICS ranks (primary + 2 alternates) against the
    # blacklist. Flag = which rank hit ("1"/"2"/"3"), or "N" if none.
    _bl = check_naics_blacklist(_naics_code, _naics["naics_2"], _naics["naics_3"])

    # FULL RESULTS APPEND
    results.append({
        # core identifiers
        "run_id": run_id,
        "policy_code": row["policy_code"],
        "insured_name": str(row.get("_insured_name_legal") or row["insured_name"]),

        # parsed address (prefer location address from classcode if available)
        "street_number": row["street_number"],
        "street_name": row["street_name"],
        "city": row["city"],
        "state": row["gov_state"] if row.get("gov_state") else row["state"],
        "zip5": row["zip5"],

        #  agent / policy attributes
        "naics_code_agent": str(row.get("naics_code_agent_entered") or "") or None,
        "dba": str(row.get("_dba_agg_text") or row.get("_dba_text") or "") or None,
        "class_codes": str(row.get("_tc_class") or row.get("class_codes_agent_entered") or "") or None,
        "class_desc": str(row.get("_tc_description") or row.get("description_of_class_codes") or "") or None,
        "suffixes": str(row.get("_tc_classsuffix") or row.get("suffixes") or "") or None,
        "agency_code": str(row.get("agency_code") or "") or None,
        "inception": str(row.get("inception") or "") if not str(row.get("inception") or "").startswith("java.util") else None,
        "agency_uw": str(row.get("_agency_uw") or "") or None,
        "ytd_prem": str(row.get("_ytd_prem") or "") or None,
        "industry": str(row.get("_industry_desc") or "") or None,
        "sub_industry": str(row.get("_sub_industry_desc") or "") or None,
        "bus_type": str(row.get("_bus_type_desc") or "") or None,
        "payroll": str(row.get("_exposure") or "") or None,
        "revenue": str(row.get("_annual_revenue") or row.get("_revenue") or "") or None,

        # LN response
        "http_status": resp.status_code,
        "ln_response_flag": body.get("ln_response_flag"),
        "naics_code": _naics_code,
        "confidence_score": _naics_conf,
        "requested_endpoint": body.get("requested_endpoint"),
        "response_body": _rb,
        "naics_description": _naics_desc,
        "naics_2": _naics["naics_2"],
        "naics_2_desc": _naics["naics_2_desc"],
        "naics_2_conf": _naics["naics_2_conf"],
        "naics_3": _naics["naics_3"],
        "naics_3_desc": _naics["naics_3_desc"],
        "naics_3_conf": _naics["naics_3_conf"],
        "naics_blacklist_flag": _bl[0],
        "blacklisted_naics": _bl[1],
        "blacklisted_naics_desc": _bl[2],
        "exposure_basis": str(row.get("_exposure_basis") or "") or None,
        "location_address": str(row.get("_loc_address") or "") or None,
        "request_ts": datetime.utcnow()
    })

    print(
        f"[PROXY] {row['policy_code']} "
        f"status={resp.status_code} "
        f"naics={_naics_code} "
        f"conf={_naics_conf}"
    )

print(f"âœ… Built {len(results)} result rows")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if len(results) == 0:
    print("âš ï¸ No results to write â€” skipping Spark insert")
else:
    from pyspark.sql.types import StructType, StructField

    write_schema = StructType([
        StructField("run_id", StringType()),
        StructField("policy_code", StringType()),
        StructField("insured_name", StringType()),
        StructField("street_number", StringType()),
        StructField("street_name", StringType()),
        StructField("city", StringType()),
        StructField("state", StringType()),
        StructField("zip5", StringType()),
        StructField("naics_code_agent", StringType()),
        StructField("dba", StringType()),
        StructField("class_codes", StringType()),
        StructField("class_desc", StringType()),
        StructField("suffixes", StringType()),
        StructField("agency_code", StringType()),
        StructField("inception", StringType()),
        StructField("agency_uw", StringType()),
        StructField("ytd_prem", StringType()),
        StructField("industry", StringType()),
        StructField("sub_industry", StringType()),
        StructField("bus_type", StringType()),
        StructField("payroll", StringType()),
        StructField("revenue", StringType()),
        StructField("http_status", IntegerType()),
        StructField("ln_response_flag", StringType()),
        StructField("naics_code", StringType()),
        StructField("confidence_score", StringType()),
        StructField("requested_endpoint", StringType()),
        StructField("response_body", StringType()),
        StructField("naics_description", StringType()),
        StructField("naics_2", StringType()),
        StructField("naics_2_desc", StringType()),
        StructField("naics_2_conf", StringType()),
        StructField("naics_3", StringType()),
        StructField("naics_3_desc", StringType()),
        StructField("naics_3_conf", StringType()),
        StructField("naics_blacklist_flag", StringType()),
        StructField("blacklisted_naics", StringType()),
        StructField("blacklisted_naics_desc", StringType()),
        StructField("exposure_basis", StringType()),
        StructField("location_address", StringType()),
        StructField("request_ts", TimestampType()),
    ])

    col_order = [f.name for f in write_schema.fields]
    rows = [tuple(r[c] for c in col_order) for r in results]

    results_df = spark.createDataFrame(rows, schema=write_schema)
    results_df.createOrReplaceTempView("_tmp_gl_enrichment")
    # Insert BY NAME (explicit column list) so it is robust to the physical
    # column order of the target table. The naics_2/naics_3 columns were added
    # via ALTER TABLE ADD COLUMNS, so on a pre-existing table they live at the
    # END physically while write_schema has them in the middle. A positional
    # "INSERT ... SELECT *" would therefore shift every column from naics_2 on
    # (e.g. location_address would receive naics_3_desc). Naming the columns
    # forces target<-source alignment by name.
    _col_list = ", ".join(col_order)
    spark.sql(
        f"INSERT INTO policy.fact_gl_cdpf_enrichment ({_col_list}) "
        f"SELECT {_col_list} FROM _tmp_gl_enrichment"
    )
    print(f"✅ {len(results)} rows appended via SQL INSERT (by name)")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

display(
    spark.table("policy.fact_gl_cdpf_enrichment")
         .filter(F.col("run_id") == run_id)
         .orderBy(F.col("request_ts").desc())
)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
