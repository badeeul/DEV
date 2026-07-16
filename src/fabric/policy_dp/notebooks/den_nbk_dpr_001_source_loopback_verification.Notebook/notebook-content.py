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

%run den_nbk_pdi_001_workspace_parameters

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

%run den_nbk_pde_001_shared_utils

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from pyspark.sql.types import *
from pyspark.sql.functions import *
from notebookutils import mssparkutils
import pandas as pd
from datetime import *
import json
import os
import ast
from delta.tables import DeltaTable
from spark_engine.common.email_util import * 
from spark_engine.common.lakehouse import LakehouseManager

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

workspace_name = notebookutils.runtime.context.get("currentWorkspaceName")
key_vault_name = secretsScope 
replacement_tokens = {
        'workspace_name': workspace_name
        }

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

# notebook parameters
parameter_template_name = 'params_loopback_verification.json'
email_template_name = 'dp_loopback_verification_results.json'
premium_fees_commission = '{"rowCount": 12,"rows": [{"LOB": "Businessowner\'s","premamount": 4708884478.00,"fsamount": 0.00,"paamount": 9599573.9525,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 825149723.10,"nocommprem": -114564.00},{"LOB": "Commercial Auto","premamount": 1650910526.00,"fsamount": 0.00,"paamount": 2378849.87,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 239155748.57,"nocommprem": 0.00},{"LOB": "Commercial Excess","premamount": 25164126.00,"fsamount": 0.00,"paamount": 0.00,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 3721107.92,"nocommprem": 0.00},{"LOB": "Commercial Package","premamount": 18873084.00,"fsamount": 0.00,"paamount": 30505.93,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 2968669.72,"nocommprem": 0.00},{"LOB": "Commercial Umbrella","premamount": 86965716.00,"fsamount": 0.00,"paamount": 98162.21,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 12866291.20,"nocommprem": 0.00},{"LOB": "Disability","premamount": 200265474.00,"fsamount": 0.00,"paamount": 0.00,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 32758556.42,"nocommprem": 0.00},{"LOB": "Homeowners","premamount": 2023320394.00,"fsamount": 0.00,"paamount": 2109411.03,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 289650940.89,"nocommprem": 0.00},{"LOB": "Manuscript Policy","premamount": 4672632.00,"fsamount": 0.00,"paamount": 0.00,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 967472.96,"nocommprem": 0.00},{"LOB": "Personal Umbrella","premamount": 5080410.00,"fsamount": 0.00,"paamount": 2301.28,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 732364.83,"nocommprem": 0.00},{"LOB": "Professional Liability","premamount": 78844114.00,"fsamount": 0.00,"paamount": 110429.78,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 14379088.74,"nocommprem": 0.00},{"LOB": "Program Commercial Package","premamount": 1788805010.00,"fsamount": 0.00,"paamount": 2988114.88,"sf3amount": 0.00,"sf4amount": 0.00,"sf5amount": 0.00,"sf6amount": 0.00,"commisamt": 371360749.35,"nocommprem": 0.00},{"LOB": "Workers\' Compensation","premamount": 13233224661.02,"fsamount": 111653431.00,"paamount": 284639511.00,"sf3amount": 30630466.00,"sf4amount": 3222035.00,"sf5amount": 15516745.00,"sf6amount": 9092377.00,"commisamt": 1403913667.579,"nocommprem": 197257149.4933}]}'
new_renewal_bind_premium = '{"rowCount": 12,	"rows": [  {"LOB": "Businessowner\'s","NW_BindPrem": 1499351127.0000,"RN_BindPrem": 4196628839.0000  },  {"LOB": "Commercial Auto","NW_BindPrem": 522906247.0000,"RN_BindPrem": 1564093868.0000  },  {"LOB": "Commercial Excess","NW_BindPrem": 8026508.0000,"RN_BindPrem": 22411253.0000  },  {"LOB": "Commercial Package","NW_BindPrem": 8276239.0000,"RN_BindPrem": 13149392.0000  },  {"LOB": "Commercial Umbrella","NW_BindPrem": 32149650.0000,"RN_BindPrem": 74442248.0000  },  {"LOB": "Disability","NW_BindPrem": 51587767.0000,"RN_BindPrem": 235521687.0000  },  {"LOB": "Homeowners","NW_BindPrem": 677857506.0000,"RN_BindPrem": 1777564252.0000  },  {"LOB": "Manuscript Policy","NW_BindPrem": 4824249.0000,"RN_BindPrem": 0.0000  },  {"LOB": "Personal Umbrella","NW_BindPrem": 1994472.0000,"RN_BindPrem": 4175885.0000  },  {"LOB": "Professional Liability","NW_BindPrem": 17801123.0000,"RN_BindPrem": 63833759.0000  },  {"LOB": "Program Commercial Package","NW_BindPrem": 632505438.0000,"RN_BindPrem": 1156138893.0000  },  {"LOB": "Workers\' Compensation","NW_BindPrem": 4414256719.0000,"RN_BindPrem": 9715313388.0000  }]}'
new_renewal_policy_count = '{"rowCount": 12,"rows": [  {"LOB": "Businessowner\'s","New_PolCount": 2392436,"Rnw_PolCount": 744403  },  {"LOB": "Commercial Auto","New_PolCount": 668879,"Rnw_PolCount": 189979  },  {"LOB": "Commercial Excess","New_PolCount": 24758,"Rnw_PolCount": 15274  },  {"LOB": "Commercial Package","New_PolCount": 10917,"Rnw_PolCount": 314  },  {"LOB": "Commercial Umbrella","New_PolCount": 156604,"Rnw_PolCount": 63071  },  {"LOB": "Disability","New_PolCount": 82879,"Rnw_PolCount": 169050  },  {"LOB": "Homeowners","New_PolCount": 4654657,"Rnw_PolCount": 1013788  },  {"LOB": "Manuscript Policy","New_PolCount": 76,"Rnw_PolCount": 1  },  {"LOB": "Personal Umbrella","New_PolCount": 28079,"Rnw_PolCount": 15674  },  {"LOB": "Professional Liability","New_PolCount": 45699,"Rnw_PolCount": 15992  },  {"LOB": "Program Commercial Package","New_PolCount": 20558,"Rnw_PolCount": 37463  },  {"LOB": "Workers\' Compensation","New_PolCount": 4550136,"Rnw_PolCount": 1956611  }]}'
dec_premium = '{"rowCount": 12,"rows": [  {"LOB": "Businessowner\'s","DecPrem": 5695980119.00  },  {"LOB": "Commercial Auto","DecPrem": 2087000115.00  },  {"LOB": "Commercial Excess","DecPrem": 30437761.00  },  {"LOB": "Commercial Package","DecPrem": 21425631.00  },  {"LOB": "Commercial Umbrella","DecPrem": 106591898.00  },  {"LOB": "Disability","DecPrem": 287109454.00  },  {"LOB": "Homeowners","DecPrem": 2455442070.00  },  {"LOB": "Manuscript Policy","DecPrem": 4824249.00  },  {"LOB": "Personal Umbrella","DecPrem": 6170357.00  },  {"LOB": "Professional Liability","DecPrem": 81634882.00  },  {"LOB": "Program Commercial Package","DecPrem": 1788644331.00  },  {"LOB": "Workers\' Compensation","DecPrem": 15184109395.00  }]}'

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# WRITTEN PREMIUM / FEES / COMMISSION BY LOB
# IIS
data = json.loads(premium_fees_commission)
rows_data = data['rows']
iis_premium_fees_commission_df = spark.createDataFrame(rows_data)
iis_premium_fees_commission_df = iis_premium_fees_commission_df.withColumn('statefees', col('fsamount')+col('paamount')+col('sf3amount')+col('sf4amount')+col('sf5amount')+col('sf6amount'))

# POLICY DATA PRODUCT
dpr_premium_fees_commission_df=spark.sql("""
SELECT 
  l.lob_desc AS LOB
, sum(t.prem_amt) AS premamount
, sum(t.fsa_amt) AS fsamount
, sum(t.paa_amt) AS paamount
, sum(t.sf3_amt) AS sf3amount
, sum(t.sf4_amt) AS sf4amount
, sum(t.sf5_amt) AS sf5amount
, sum(t.sf6_amt) AS sf6amount
, sum(t.comm_amt) AS commisamt
, sum(t.non_comm_prem_amt) AS nocommprem
FROM den_lhw_dpr_001_policy_product.policy.fact_policy_transaction t
left join den_lhw_dpr_001_policy_product.policy.dim_lob l
on t.lob_key = l.lob_key and l.dl_is_current_flag = 1
GROUP BY l.lob_desc
ORDER BY 1
""")
dpr_premium_fees_commission_df = dpr_premium_fees_commission_df.withColumn('statefees', col('fsamount')+col('paamount')+col('sf3amount')+col('sf4amount')+col('sf5amount')+col('sf6amount'))

numeric_columns = ['commisamt', 'statefees', 'nocommprem', 'premamount']

for col_name in numeric_columns:
    iis_premium_fees_commission_df = iis_premium_fees_commission_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))
    dpr_premium_fees_commission_df = dpr_premium_fees_commission_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))

for col_name in numeric_columns:
    iis_premium_fees_commission_df = iis_premium_fees_commission_df.withColumnRenamed(col_name, f"iis_{col_name}")
    dpr_premium_fees_commission_df = dpr_premium_fees_commission_df.withColumnRenamed(col_name, f"dpr_{col_name}")

premium_fees_commission_joined_df = iis_premium_fees_commission_df.join(dpr_premium_fees_commission_df, on="LOB", how="full_outer")

for col_name in numeric_columns:
    iis_col = f"iis_{col_name}"
    dpr_col = f"dpr_{col_name}"
    diff_col = f"{col_name} Difference"
    diff_pct_col = f"{col_name} Difference (%)"
    match_pct_col = f"{col_name} Match (%)"
    
    premium_fees_commission_joined_df = premium_fees_commission_joined_df.withColumn(
        diff_col, 
        round(col(iis_col) - col(dpr_col), 6)
    )

    premium_fees_commission_joined_df = premium_fees_commission_joined_df.withColumn(
        diff_pct_col,
        when(
            col(iis_col) != 0, 
            round((col(iis_col) - col(dpr_col)) / col(iis_col) * 100, 2)
        ).otherwise(
            when(col(dpr_col) != 0, 100.0).otherwise(0.0)
        )
    )

    premium_fees_commission_joined_df = premium_fees_commission_joined_df.withColumn(
        match_pct_col,
        when(
            col(diff_pct_col) <= 100,
            round(100 - col(diff_pct_col), 4)
        ).otherwise(0.0)
    )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

numeric_columns = ['commisamt', 'statefees', 'nocommprem', 'premamount']
    
summary_cols = ["LOB"]
for col_name in numeric_columns:
    summary_cols.extend([
        f"iis_{col_name}" 
        ,f"dpr_{col_name}"
        ,f"{col_name} Difference"
    ])

prem_fee_comm_diff_df = premium_fees_commission_joined_df.select(summary_cols)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

numeric_columns = ['commisamt', 'statefees', 'nocommprem', 'premamount']

summary_cols = ["LOB"]
for col_name in numeric_columns:
    summary_cols.extend([        
        f"{col_name} Difference"
        ,f"{col_name} Difference (%)"
        ,f"{col_name} Match (%)"
    ])

prem_fee_comm_diff_match_pct_df = premium_fees_commission_joined_df.select(summary_cols)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

data = json.loads(new_renewal_bind_premium)
rows_data = data['rows']
iis_new_renewal_bind_premium_df = spark.createDataFrame(rows_data)
dpr_new_renewal_bind_premium_df = spark.sql("""
SELECT  l.lob_desc AS LOB,  
coalesce(sum(CASE WHEN tt.policy_trans_type_cd_bus_key = 'NW' THEN t.prem_amt END), 0) AS NW_BindPrem,  
coalesce(sum(CASE WHEN tt.policy_trans_type_cd_bus_key = 'RN' THEN t.prem_amt END), 0) AS RN_BindPrem
FROM den_lhw_dpr_001_policy_product.policy.fact_policy p
LEFT JOIN den_lhw_dpr_001_policy_product.policy.dim_lob l ON l.lob_key = p.lob_key and l.dl_is_current_flag = 1
LEFT JOIN den_lhw_dpr_001_policy_product.policy.fact_policy_transaction t ON p.policy_key = t.policy_key
LEFT JOIN den_lhw_dpr_001_policy_product.policy.dim_policy_trans_type tt ON t.policy_trans_type_key = tt.policy_trans_type_key and tt.dl_is_current_flag = 1
GROUP BY l.lob_desc
ORDER BY 1
""")

numeric_columns = ['NW_BindPrem', 'RN_BindPrem']
for col_name in numeric_columns:
    iis_new_renewal_bind_premium_df = iis_new_renewal_bind_premium_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))
    dpr_new_renewal_bind_premium_df = dpr_new_renewal_bind_premium_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))

for col_name in numeric_columns:
    iis_new_renewal_bind_premium_df = iis_new_renewal_bind_premium_df.withColumnRenamed(col_name, f"iis_{col_name}")
    dpr_new_renewal_bind_premium_df = dpr_new_renewal_bind_premium_df.withColumnRenamed(col_name, f"dpr_{col_name}")

new_renewal_bind_joined_df = iis_new_renewal_bind_premium_df.join(dpr_new_renewal_bind_premium_df, on="LOB", how="full_outer")

for col_name in numeric_columns:
    iis_col = f"iis_{col_name}"
    dpr_col = f"dpr_{col_name}"
    diff_col = f"{col_name} Difference"
    diff_pct_col = f"{col_name} Difference (%)"
    match_pct_col = f"{col_name} Match (%)"
    
    new_renewal_bind_joined_df = new_renewal_bind_joined_df.withColumn(
        diff_col, 
        round(col(iis_col) - col(dpr_col), 6)
    )

    new_renewal_bind_joined_df = new_renewal_bind_joined_df.withColumn(
        diff_pct_col,
        when(
            col(iis_col) != 0, 
            round((col(iis_col) - col(dpr_col)) / col(iis_col) * 100, 2)
        ).otherwise(
            when(col(dpr_col) != 0, 100.0).otherwise(0.0)
        )
    )

    new_renewal_bind_joined_df = new_renewal_bind_joined_df.withColumn(
        match_pct_col,
        when(
            col(diff_pct_col) <= 100,
            round(100 - col(diff_pct_col), 4)
        ).otherwise(0.0)
    )

summary_cols = ["LOB"]
for col_name in numeric_columns:
    summary_cols.extend([
        f"iis_{col_name}" 
        ,f"dpr_{col_name}"
        ,f"{col_name} Difference"
        ,f"{col_name} Difference (%)"
        ,f"{col_name} Match (%)"
    ])

new_renewal_bind_premium_summary_df = new_renewal_bind_joined_df.select(summary_cols)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

data = json.loads(new_renewal_policy_count)
rows_data = data['rows']
iis_new_renewal_policy_count_df = spark.createDataFrame(rows_data)

dpr_new_renewal_policy_count_df = spark.sql("""SELECT
  l.lob_desc AS LOB
, sum((case when p.policy_bus_type like 'New%' then 1 else 0 end)) as New_PolCount
, sum((case when p.policy_bus_type like 'Renewal%' then 1 else 0 end)) as Rnw_PolCount
FROM den_lhw_dpr_001_policy_product.policy.dim_policy p
INNER JOIN den_lhw_dpr_001_policy_product.policy.fact_policy f on p.policy_key=f.policy_key and p.dl_is_current_flag = 1
LEFT JOIN den_lhw_dpr_001_policy_product.policy.dim_lob l on l.lob_key = f.lob_key and l.dl_is_current_flag = 1
GROUP BY l.lob_desc
ORDER BY 1""")

numeric_columns = ['New_PolCount', 'Rnw_PolCount']
for col_name in numeric_columns:
    iis_new_renewal_policy_count_df = iis_new_renewal_policy_count_df.withColumn(col_name, col(col_name).cast("integer"))
    dpr_new_renewal_policy_count_df = dpr_new_renewal_policy_count_df.withColumn(col_name, col(col_name).cast("integer"))

for col_name in numeric_columns:
    iis_new_renewal_policy_count_df = iis_new_renewal_policy_count_df.withColumnRenamed(col_name, f"iis_{col_name}")
    dpr_new_renewal_policy_count_df = dpr_new_renewal_policy_count_df.withColumnRenamed(col_name, f"dpr_{col_name}")

new_renewal_policy_count_joined_df = iis_new_renewal_policy_count_df.join(dpr_new_renewal_policy_count_df, on="LOB", how="full_outer")

for col_name in numeric_columns:
    iis_col = f"iis_{col_name}"
    dpr_col = f"dpr_{col_name}"
    diff_col = f"{col_name} Difference"
    diff_pct_col = f"{col_name} Difference (%)"
    match_pct_col = f"{col_name} Match (%)"
    
    new_renewal_policy_count_joined_df = new_renewal_policy_count_joined_df.withColumn(
        diff_col, 
        col(iis_col) - col(dpr_col)
    )

    new_renewal_policy_count_joined_df = new_renewal_policy_count_joined_df.withColumn(
        diff_pct_col,
        when(
            col(iis_col) != 0, 
            round((col(iis_col) - col(dpr_col)) / col(iis_col) * 100, 2)
        ).otherwise(
            when(col(dpr_col) != 0, 100.0).otherwise(0.0)
        )
    )

    new_renewal_policy_count_joined_df = new_renewal_policy_count_joined_df.withColumn(
        match_pct_col,
        when(
            col(diff_pct_col) <= 100,
            round(100 - col(diff_pct_col), 4)
        ).otherwise(0.0)
    )

summary_cols = ["LOB"]
for col_name in numeric_columns:
    summary_cols.extend([
        f"iis_{col_name}" 
        ,f"dpr_{col_name}"
        ,f"{col_name} Difference"
        ,f"{col_name} Difference (%)"
        ,f"{col_name} Match (%)"
    ])

new_renewal_policy_count_summary_df = new_renewal_policy_count_joined_df.select(summary_cols)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

data = json.loads(str(dec_premium))
rows_data = data['rows']
iis_dec_premium_df = spark.createDataFrame(rows_data)

dpr_dec_premium_df = spark.sql("""
SELECT
  l.lob_desc AS LOB
, sum(f.dec_prem) as DecPrem
FROM den_lhw_dpr_001_policy_product.policy.fact_policy f
LEFT JOIN den_lhw_dpr_001_policy_product.policy.dim_lob l on l.lob_key = f.lob_key and l.dl_is_current_flag = 1 
GROUP BY l.lob_desc
ORDER BY 1
""")

numeric_columns = ['DecPrem']
for col_name in numeric_columns:
    iis_dec_premium_df = iis_dec_premium_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))
    dpr_dec_premium_df = dpr_dec_premium_df.withColumn(col_name, col(col_name).cast("decimal(19,4)"))

for col_name in numeric_columns:
    iis_dec_premium_df = iis_dec_premium_df.withColumnRenamed(col_name, f"iis_{col_name}")
    dpr_dec_premium_df = dpr_dec_premium_df.withColumnRenamed(col_name, f"dpr_{col_name}")

dec_premium_joined_df = iis_dec_premium_df.join(dpr_dec_premium_df, on="LOB", how="full_outer")

for col_name in numeric_columns:
    iis_col = f"iis_{col_name}"
    dpr_col = f"dpr_{col_name}"
    diff_col = f"{col_name} Difference"
    diff_pct_col = f"{col_name} Difference (%)"
    match_pct_col = f"{col_name} Match (%)"
    
    dec_premium_joined_df =dec_premium_joined_df.withColumn(
        diff_col, 
        round(col(iis_col) - col(dpr_col), 6)
    )

    dec_premium_joined_df = dec_premium_joined_df.withColumn(
        diff_pct_col,
        when(
            col(iis_col) != 0, 
            round((col(iis_col) - col(dpr_col)) / col(iis_col) * 100, 2)
        ).otherwise(
            when(col(dpr_col) != 0, 100.0).otherwise(0.0)
        )
    )

    dec_premium_joined_df = dec_premium_joined_df.withColumn(
        match_pct_col,
        when(
            col(diff_pct_col) <= 100,
            round(100 - col(diff_pct_col), 4)
        ).otherwise(0.0)
    )

summary_cols = ["LOB"]
for col_name in numeric_columns:
    summary_cols.extend([
        f"iis_{col_name}" 
        ,f"dpr_{col_name}"
        ,f"{col_name} Difference"
        ,f"{col_name} Difference (%)"
        ,f"{col_name} Match (%)"
    ])

dec_premium_summary_df = dec_premium_joined_df.select(summary_cols)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# get values for 'tables_to_analyze' and 'table_pk_list' from parameter_template json
parameter_template_name_location = get_template_location_url(notification_type="parameters",file_name=parameter_template_name)
parameter_value = read_json_file(parameter_template_name_location)
parameter_dict = replace_tokens_in_json_object(parameter_value, replacement_tokens)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

table_list = parameter_dict["tables_to_analyze"]

def generate_combined_sql():
    sql_parts = []

    for i, table_name in enumerate(table_list):
        try:
            columns = spark.catalog.listColumns(f"den_lhw_dpr_001_policy_product.policy.{table_name}")
            
            key_columns = [col.name for col in columns 
                          if col.name.endswith('_key') and 'bus' not in col.name.lower()]
            
            if key_columns:
                column_name = key_columns[0]
                
                table_sql = f"""
                SELECT 
                    '{table_name}' AS table_name,
                    '{column_name}' AS column_name,
                    CASE 
                        WHEN {column_name} = -1 THEN 'Unknown'
                        WHEN {column_name} = -2 THEN 'Not Applicable'
                        WHEN {column_name} = 0 THEN 'Zero Value'
                        WHEN {column_name} IS NULL THEN 'NULL'
                        ELSE 'Key Populated'
                    END AS key_group,
                    COUNT(*) AS record_count
                FROM den_lhw_dpr_001_policy_product.policy.{table_name}
                WHERE dl_is_current_flag = 1 OR dl_is_current_flag IS NULL
                GROUP BY 
                    CASE 
                        WHEN {column_name} = -1 THEN 'Unknown'
                        WHEN {column_name} = -2 THEN 'Not Applicable'
                        WHEN {column_name} = 0 THEN 'Zero Value'
                        WHEN {column_name} IS NULL THEN 'NULL'
                        ELSE 'Key Populated'
                    END                
                """
                
                if i < len(table_list) - 1:
                    table_sql += "\nUNION\n"
                
                sql_parts.append(table_sql)
                
        except Exception as e:
            print(f"Error generating SQL for {table_name}: {str(e)}")
    
    combined_sql = "".join(sql_parts)    
    combined_sql += "\nORDER BY 1, 3"
    
    return combined_sql

combined_sql = generate_combined_sql()

try:
    key_check_df = spark.sql(combined_sql)
except Exception as e:
    print(f"Error executing SQL: {str(e)}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def generate_duplicate_sql(table_pk_list):
    
    sql_parts = []
    if isinstance(table_pk_list[0], dict):
        tables_to_check = [(item['table_name'], item['primary_key']) for item in table_pk_list]
    else:
        tables_to_check = table_pk_list
    
    for i, (table_name, pk_column) in enumerate(tables_to_check):
        sql = f"""
        SELECT 
            '{table_name}' AS table_name,
            '{pk_column}' AS primary_key_column,
            {pk_column} AS primary_key_value,
            COUNT(*) AS duplicate_count
        FROM den_lhw_dpr_001_policy_product.policy.{table_name}
        WHERE {pk_column} IS NOT NULL
        and dl_is_current_flag = 1
        GROUP BY {pk_column}
        HAVING COUNT(*) > 1
        """
        
        sql_parts.append(sql)

    if sql_parts:
        combined_sql = "\nUNION ALL\n".join(sql_parts)
        combined_sql += "\nORDER BY table_name, duplicate_count DESC"
        return combined_sql
    
    return None
    
table_pk_list = parameter_dict["table_pk_list"] 
sql = generate_duplicate_sql(table_pk_list)
if sql:
    duplicates_df = spark.sql(sql)
    
    if duplicates_df.count() > 0:
        duplicates_df = duplicates_df.withColumn("status", lit("Has Duplicates"))
        tables_with_duplicates = [row.table_name for row in duplicates_df.select("table_name").distinct().collect()]
    else:
        tables_with_duplicates = []
    
    clean_rows = []
    for item in table_pk_list:
        table_name = item['table_name'] if isinstance(item, dict) else item[0]
        pk_column = item['primary_key'] if isinstance(item, dict) else item[1]
        
        if table_name not in tables_with_duplicates:
            clean_rows.append(Row(
                table_name=table_name,
                primary_key_column=pk_column,
                primary_key_value="No duplicates found",
                duplicate_count=0,
                status="Clean - No Duplicates"
            ))

    if clean_rows:
        clean_df = spark.createDataFrame(clean_rows)

        if duplicates_df.count() > 0:
            final_df = duplicates_df.union(clean_df)
        else:
            final_df = clean_df
    else:
        final_df = duplicates_df
    
    dup_check_df = final_df.orderBy(
        col("duplicate_count").asc(),
        col("table_name"),
        when(col("status") == "Has Duplicates", 0).otherwise(1)
    )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def calculate_widths(pandas_df):
    widths = {}
    base_font_size = 12 
    min_width = 80  
    max_width = 300
    
    for column in pandas_df.columns:
        max_content_length = pandas_df[column].astype(str).apply(len).max()
        header_length = len(str(column))
        
        max_length = __builtins__.max(max_content_length, header_length)
        
        calculated_width = max_length * base_font_size
        final_width = __builtins__.max(min_width, __builtins__.min(calculated_width, max_width))
        
        widths[column] = final_width
    
    return widths

def create_html_table(df1, df2=None, df3=None, df4=None, df5=None, df6=None, df7=None, table1_title="", table2_title="", table3_title="", table4_title="", table5_title="", table6_title="", table7_title=""):
    
    
    def process_dataframe(df):
        pandas_df = df.toPandas()
        widths = calculate_widths(pandas_df)
                
        if 'Match (%)' in pandas_df.columns and pandas_df['Match (%)'].dtype in ['int64', 'float64']:
            pandas_df['Match (%)'] = pandas_df['Match (%)'].apply(
                lambda x: f"{x:.4f}%" if pd.notna(x) else "N/A"
            )
        if 'Difference (%)' in pandas_df.columns and pandas_df['Difference (%)'].dtype in ['int64', 'float64']:
            pandas_df['Difference (%)'] = pandas_df['Difference (%)'].apply(
                lambda x: f"{x:.4f}%" if pd.notna(x) else "N/A"
            )
            
        return pandas_df, widths
    
    def generate_table_html(pandas_df, widths):
        html_table = pandas_df.to_html(
            index=False, 
            classes='dynamic-table', 
            escape=False
        )
        
        css_styles = ""
        for i, column in enumerate(pandas_df.columns, 1):
            css_styles += """
                th:nth-child(%d), td:nth-child(%d) { 
                    width: %dpx; 
                    max-width: %dpx;
                    %s
                    border: 1px solid #3498db !important;
                }
                """ % (
                i, i, widths[column], widths[column],
                'text-align: right;' if column != 'LOB' else ''
            )

        return html_table, css_styles
    
    # Process first dataframe
    pandas_df1, widths1 = process_dataframe(df1)
    html_table1, css_styles1 = generate_table_html(pandas_df1, widths1)
    
    # Process second dataframe if provided
    if df2 is not None:
        pandas_df2, widths2 = process_dataframe(df2)
        html_table2, css_styles2 = generate_table_html(pandas_df2, widths2)

    # Process third dataframe if provided
    if df3 is not None:
        pandas_df3, widths3 = process_dataframe(df3)
        html_table3, css_styles3 = generate_table_html(pandas_df3, widths3)

    # Process fourth dataframe if provided
    if df4 is not None:
        pandas_df4, widths4 = process_dataframe(df4)
        html_table4, css_styles4 = generate_table_html(pandas_df4, widths4)
    
    # Process fifth dataframe if provided
    if df5 is not None:
        pandas_df5, widths4 = process_dataframe(df5)
        html_table5, css_styles4 = generate_table_html(pandas_df5, widths4)

    # Process sixth dataframe if provided
    if df6 is not None:
        pandas_df6, widths4 = process_dataframe(df6)
        html_table6, css_styles4 = generate_table_html(pandas_df6, widths4)

    # Process seventh dataframe if provided
    if df6 is not None:
        pandas_df7, widths4 = process_dataframe(df7)
        html_table7, css_styles4 = generate_table_html(pandas_df7, widths4)
    
    # Generate HTML content
    html_content = """
    <html>
    <head>
    <style>
        .dynamic-table {
            border: 2px solid #2980b9;
            border-collapse: collapse;
            width: auto;
            margin: 20px 0;
            font-family: Arial, sans-serif;
            font-size: 12px;
            table-layout: fixed;
            box-shadow: 0 2px 6px rgba(52, 152, 219, 0.2);
        }
        .dynamic-table th, .dynamic-table td {
            border: 1px solid #3498db;
            padding: 10px 8px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .dynamic-table th {
            background: linear-gradient(135deg, #3498db, #2980b9);
            background-color: transparent;
            color: inherit;
            font-weight: bold;
            border-bottom: 2px solid #2471a3;
            text-align: center;
        }
        .dynamic-table td {
            background-color: transparent;
            color: inherit;
        }
        .dynamic-table tr:nth-child(even) td {
            background-color: transparent;
            color: inherit;
        }
        .dynamic-table tr:hover td {
            background-color: transparent;
            color: inherit;
        }
    """
    html_content += css_styles1
    html_content += """

        .dynamic-table thead th {
            border-bottom: 2px solid #2471a3;
        }
        .dynamic-table tbody tr:last-child td {
            border-bottom: 1px solid #3498db;
        }
        
        .numeric {
            text-align: right; 
            font-family: 'Courier New', monospace;
            font-weight: bold;
        }
        .positive-diff { color: #27ae60; }
        .negative-diff { color: #e74c3c; }
        .zero-diff { color: #3498db; font-weight: bold; }
        
        th:nth-child(1), td:nth-child(1) {
            text-align: left !important;
            font-weight: bold;
            border-left: 1px solid #3498db !important;
        }
        
        
        th:last-child, td:last-child {
            border-right: 1px solid #3498db !important;
        }
        
        .table-title {
            color: #2980b9;
            font-size: 16px;
            font-weight: bold;
            margin: 20px 0 10px 0;
            padding-bottom: 5px;
            border-bottom: 2px solid #3498db;
        }
        
        .table-container {
            margin-bottom: 30px;
        }
    </style>
    </head>
    <body>
        <h4 style="color: #2980b9; border-bottom: 2px solid #3498db; padding-bottom: 5px;">
            The verification process for Common Product and Pricing data product has been completed. Please find the summary below:
        </h4>
        
        <!-- First Table -->
        <div class="table-container">
            <div class="table-title">"""
    html_content += table1_title + "</div>" if table1_title else ''
    html_content += """<div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">"""
    html_content += html_table1
    html_content += """
            </div>
        </div>
    """

    if df2 is not None:
        html_content += """
        <!-- Second Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table2_title) if table2_title else '',
            html_table2
        )

    if df3 is not None:
        html_content += """
        <!-- Third Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table3_title) if table3_title else '',
            html_table3
        )

    if df4 is not None:
        html_content += """
        <!-- Fourth Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table4_title) if table4_title else '',
            html_table4
        )

    if df5 is not None:
        html_content += """
        <!-- Fifth Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table5_title) if table5_title else '',
            html_table5
        )

    if df6 is not None:
        html_content += """
        <!-- sixth Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table6_title) if table6_title else '',
            html_table6
        )

    if df7 is not None:
        html_content += """
        <!-- seventh Table -->
        <div class="table-container">
            {0}
            <div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">
                {1}
            </div>
        </div>
        """.format(
            '<div class="table-title">{}</div>'.format(table7_title) if table7_title else '',
            html_table7
        )


        html_content +="""
            </body>
                </html>"""
    return html_content 
    
body = create_html_table(
    prem_fee_comm_diff_df,
    prem_fee_comm_diff_match_pct_df,
    new_renewal_bind_premium_summary_df,
    new_renewal_policy_count_summary_df,
    dec_premium_summary_df,
    key_check_df,
    dup_check_df,
    table1_title="IIS Vs DPR WRITTEN PREMIUM / FEES / COMMISSION BY LOB - Difference - Part 1",
    table2_title="IIS Vs DPR WRITTEN PREMIUM / FEES / COMMISSION BY LOB - Difference % & Match % - Part 2",
    table3_title="IIS Vs DPR NEW/RENEWAL BIND PREMIUM BY LOB",
    table4_title="IIS Vs DPR NEW/RENEWAL POLICY COUNT BY LOB",
    table5_title="IIS Vs DPR TOTAL DEC PREM BY LOB",
    table6_title="DPR KEY POPULATION CHECK",
    table7_title="DPR DUPLICATES IN DIMENSIONs CHECK"
    )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

email_template_name_location = get_template_location_url(notification_type="emails",file_name=email_template_name)

email_value = read_json_file(email_template_name_location)
email_dict = replace_tokens_in_json_object(email_value, replacement_tokens)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# set parameters and send email
date_str = datetime.now().strftime('%Y-%m-%d')
subject = email_dict["subject"] + ' - ' + date_str

input_params = {
    "subject" : subject,
    "body" : body,
    "to_email" : email_dict["emailRecipient"],
    "cc_email" : email_dict["emailCc"],
    "from_account" : email_dict["emailSender"],
    "key_vault_name" : secretsScope,
    "attachments": ''
    }
send_email(**input_params)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
