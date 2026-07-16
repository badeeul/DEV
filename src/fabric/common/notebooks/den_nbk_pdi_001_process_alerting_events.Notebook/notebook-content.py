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

# CELL ********************

import json
import os
from delta.tables import DeltaTable
from pyspark.sql.functions import col
from spark_engine.common.email_util import send_email 
from spark_engine.common.lakehouse import LakehouseManager

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

elt_id = '81625932-737d-4450-a858-f5a575fbcd55'
template_name = "deduplication_msg.json"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

%run den_nbk_pdi_001_workspace_parameters

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_template_location_url(lakehouse_name="den_lhw_pdi_001_metadata",notification_type="emails",file_name="") -> str:
    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    template_path = f"{lakehouse_manager.lakehouse_path}/Files/templates/{notification_type}/"
    return f"{template_path}/{file_name}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def replace_tokens_in_json_object(json_object: dict, param_dict: dict):
    value = json.dumps(json_object)
    for k, v in param_dict.items():
        value = value.replace('{' + k + '}', v)

    value_dict = json.loads(value)
    return value_dict

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_json_file(file_location):
    jsonDf = spark.read.text(file_location, wholetext=True)
    content = jsonDf.first()["value"]
    return json.loads(content)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_table_location_url(lakehouse_name="den_lhw_pdi_001_observability",table_schema="audit",table_name="") -> str:
    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    tables_path = f"{lakehouse_manager.lakehouse_path}/Tables"
    table_schema,table_name = (table_schema,table_name)
    return f"{tables_path}/{table_schema}/{table_name}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_quarantine_log_data(elt_id):
    # Get table's url
    table_path = get_table_location_url(table_name="quarantine_log")

    # Perform the query using DataFrame API
    quarantine_log_df = (
        DeltaTable.forPath(spark, table_path)
        .toDF()
        .filter((col("elt_id") == elt_id) & (col("Total_Rows") > 0))
        .select(
            col("dataset_name"),
            col("quarantine_type"),
            col("Total_Rows").alias("NoOfDuplicates"),
            col("elt_id").alias("ELTId")
        )
        .groupBy(
            "dataset_name",
            "quarantine_type",
            "NoOfDuplicates",
            "ELTId"
        )
    ).count()
    return quarantine_log_df

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

deduplication_df = get_quarantine_log_data(elt_id)
table_count = deduplication_df.count()
error_details = deduplication_df.toPandas().to_html(index=False)

error_details = error_details.replace('\n', '\\n').replace('"', '\\"')

if table_count > 0:
    template_name_location = get_template_location_url(file_name=template_name)

    # set replacement tokens value 
    workspace_name = workspace_name = notebookutils.runtime.context.get("currentWorkspaceName")
    key_vault_name = secretsScope 

    replacement_tokens = {
        'workspace_name': workspace_name,
        'table_count': str(table_count),
        'error_details': error_details
        }

    # load template file and replace tokens
    template_name_location = get_template_location_url(file_name=template_name)
    value = read_json_file(template_name_location)
    request_dict = replace_tokens_in_json_object(value, replacement_tokens)

    # set parameters and send email
    input_params = {
        "subject" : request_dict["subject"],
        "body" : request_dict["body"]["content"],
        "to_email" : request_dict["emailRecipient"],
        "from_account" : request_dict["emailSender"],
        "key_vault_name" : secretsScope
    }
    send_email(**input_params)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
