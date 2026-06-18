# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "00000000-0000-0000-0000-000000000000",
# META       "default_lakehouse_name": "den_lhw_dpr_001_policy_product",
# META       "default_lakehouse_workspace_id": "00000000-0000-0000-0000-000000000000"
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

# Proxy endpoint (TEST)
PROXY_ENDPOINT = "https://bhg-prod-dna-appsvcs-eus-app.azurewebsites.net/api/proxy/call-test"

# Proxy API key (x-api-key header)
PROXY_API_KEY = "lexisnexis_proxy_51Q7k8L2mN3pQ4rS5tU6vW7xY8zAbCdEfGhIjKlMnOpQrStUvWxYzAb"

# Run controls
LOB_FILTER = "GL"
ROWS_TO_SEND = 10

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
    dp.policy_effec_start_dt                 AS `Inception`,
    uw.emp_nm                                AS `Agency UW`,
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
    substring(trim(di.mail_zip), 1, 5)       AS `Zip5`,

    dmt.mkt_type_cd_bus_key                  AS `markettype`,
    dps.prod_src_cd_bus_key                  AS `productionsrc`

FROM policy.fact_policy fp
JOIN policy.dim_policy dp ON fp.policy_key = dp.policy_key
JOIN policy.dim_lob dl ON fp.lob_key = dl.lob_key
JOIN policy.dim_insured di ON fp.insd_key = di.insd_key

LEFT JOIN policy.dim_mkt_type dmt ON fp.mkt_type_key = dmt.mkt_type_key
LEFT JOIN policy.dim_prod_src dps ON fp.prod_src_key = dps.prod_src_key
LEFT JOIN policy.dim_dist_chnl ddc ON fp.dist_chnl_key = ddc.dist_chnl_key

LEFT JOIN policy.dim_naics dn ON fp.naics_key = dn.naics_key
LEFT JOIN policy.dim_business_class dbc ON fp.gov_bus_class_key = dbc.bus_class_key
LEFT JOIN policy.dim_employee uw ON fp.dec_uw_emp_key = uw.emp_key

WHERE
    dl.lob_cd_bus_key = '{LOB_FILTER}'
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

    # --- new columns ---
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
    request_ts            TIMESTAMP
)
USING DELTA
""")
print("âœ… policy.fact_gl_cdpf_enrichment ready")
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

candidates_df = (
    spark.table("policy.vw_gl_cdpf_candidates")
    .limit(ROWS_TO_SEND)
)

pdf = candidates_df.toPandas()

parsed = pdf["address1"].apply(parse_address)

# âœ… force valid shape
parsed = parsed.apply(
    lambda x: x if isinstance(x, tuple) and len(x) == 2 else ("", "")
)

# âœ… extract explicitly â€” NO DataFrame constructor
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

    results.append({
        "run_id": run_id,
        "policy_code": row["policy_code"],
        "insured_name": row["insured_name"],
        "street_number": row["street_number"],
        "street_name": row["street_name"],
        "city": row["city"],
        "state": row["state"],
        "zip5": row["zip5"],
        "http_status": resp.status_code,
        "ln_response_flag": body.get("ln_response_flag"),
        "naics_code": body.get("naics_code"),
        "confidence_score": str(body.get("confidence_score")) if body.get("confidence_score") is not None else None,
        "requested_endpoint": body.get("requested_endpoint"),
        "response_body": body.get("response_body", resp.text),
        "request_ts": datetime.utcnow()
    })

    print(
        f"[PROXY] {row['policy_code']} "
        f"status={resp.status_code} "
        f"naics={body.get('naics_code')} "
        f"conf={body.get('confidence_score')}"
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
    results_df = spark.createDataFrame(pd.DataFrame(results))

    results_df_clean = results_df.selectExpr(
        "run_id",
        "policy_code",
        "insured_name",
        "street_number",
        "street_name",
        "city",
        "state",
        "zip5",

        "naics_code_agent",
        "dba",
        "class_codes",
        "class_desc",
        "suffixes",
        "agency_code",
        "inception",
        "agency_uw",
        "ytd_prem",
        "industry",
        "sub_industry",
        "bus_type",
        "payroll",
        "revenue",

        "CAST(http_status AS INT) AS http_status",
        "ln_response_flag",
        "naics_code",
        "confidence_score",
        "requested_endpoint",
        "response_body",
        "request_ts"
    )

    results_df_clean.write.mode("append").insertInto("policy.fact_gl_cdpf_enrichment")
    print("âœ… Results appended via insertInto")

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
