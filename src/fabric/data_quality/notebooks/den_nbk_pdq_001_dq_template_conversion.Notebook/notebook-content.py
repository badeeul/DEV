# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# MARKDOWN ********************

# ## Data Quality Template Converter
# 
# 
# 
# 
# This notebook is meant to convert the data quality Excel template to the JSON format expected by the platform service. The cell below should be filled in with variables before running the notebook. This notebook is just to help create the JSON which can then be committed to the sub-domain repo so it can be deployed between environments. This is not a step to be performed in each environment and this notebook **will not** populate the `dim_dq_rule_master` table.
# 
# 
# 
# 
# 
# Variables
# 
# 
# 
# 
# **Lakehouse**: lakehouse name where the Excel template has been uploaded and the JSON output will be saved.
# 
# 
# 
# 
# **excel_path**: the path to the Excel template.
# 
# 
# 
# 
# **Json_path**: the path where the output will be saved.
# 
# 
# 
# 
# **Sheet_name**: name of the Excel sheet to be loaded.
# 
# 
# 
# 
# **Skip_rows**: number of rows to skip in the sheet.
# 
# 
# 
# 
# 
#  DQ Rule Constraint Schema
# 
# 
# 
# 
# The notebooks will also validate the schema of the DQ Rule Constraint column to ensure it contains the `type`, `kwargs`, and `meta` fields. Because the `kwargs` and `meta` are dynamic, the sub-fields will not be validated. An error will be raised if the schema is not valid.


# CELL ********************

# fill in values before running

lakehouse = notebookutils.lakehouse.get("den_lhw_pdi_001_metadata")

workspace_id = lakehouse["workspaceId"]

lakehouse_id = lakehouse["id"]



excel_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lakehouse_id}/Files/data_quality/DnA Fluidity Platform - DQ Rule Book Template.xlsx"
json_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lakehouse_id}/Files/data_quality/dq_template_output.json"
sheet_name = "Rule Master <Data Product>"
skip_rows = 1

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

import pandas as pd
import json
import fsspec
from jsonschema import validate
from pyspark.sql.functions import *
from pyspark.sql.types import *

warnings.filterwarnings("ignore", category=UserWarning, module="openpyxl")

pd_df = pd.read_excel(
    io=excel_path,
    sheet_name=sheet_name,
    skiprows=skip_rows,
    header=0,
    dtype=str,
).dropna(how="all")



df = spark.createDataFrame(pd_df)



df = df.select(
    struct(
        col("#").alias("dq_rule_master_key"),
        col("DQ Rule ID").alias("dq_rule_id"),
        col("Data Product Name").alias("data_product_name"),
        col("Sub Domain Name").alias("sub_domain_name"),
        col("DQ Rule Description").alias("dq_rule_description"),
        col("DQ Rule Constraint").alias("dq_rule_constraint"),
        col("DQ Rule Dimension").alias("dq_rule_dimension"),
        col("DQ Screen Type").alias("dq_screen_type"),
        col("DQ Rule Applicable Lakehouse").alias("dq_rule_applicable_lakehouse"),
        col("DQ Rule Applicable Schema").alias("dq_rule_applicable_schema"),
        col("DQ Rule Applicable Object").alias("dq_rule_applicable_object"),
        col("DQ Rule Applicable Attribute").alias("dq_rule_applicable_attribute"),
        col("DQ Rule Failure Action").alias("dq_rule_failure_action"),
        col("DQ Rule Severity Score").alias("dq_rule_severity_score")
    ).alias("dq_json")
)

dq_rule_constraint_schema = {
    "type": "object",
    "properties": {
        "type": {"type": "string"},
        "kwargs": {"type": "object"},
        "meta": {"type": "object"},
    },
    "required": ["type", "kwargs"],
}

dq_json = df.select(to_json(collect_list("dq_json"))).collect()[0][0]

dq_json = json.loads(dq_json)

for idx in dq_json:
    idx["dq_rule_constraint"] = json.loads(idx["dq_rule_constraint"])
    validate(instance=idx["dq_rule_constraint"], schema=dq_rule_constraint_schema)


storage_options = {
    "account_name": "onelake",
    "account_host": "onelake.dfs.fabric.microsoft.com",
}
onelake_fs = fsspec.filesystem("abfss", **storage_options)


with onelake_fs.open(json_path, "w") as json_file:
    json.dump(dq_json, json_file, indent=4)



print("DQ template conversion complete.")

print(json_path)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
