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

# Imports
import json
from datetime import datetime
from uuid import uuid4
import notebookutils as nu

from spark_engine.sparkengine import Extract
from spark_engine.common.lakehouse import LakehouseManager

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

# parameters inputs
feed_name = 'feed_name'
run_id = 'run_id'
elt_id = 'elt_id'
product_name = 'product_name'
dataset_config_json = 'dataset_config_json'
invocation_id = 'invocation_id'
workspace_id = 'workspace_id'
lh_observability_id = 'lh_observability_id'
watermark_start = 'watermark_start'
watermark_end = 'watermark_end'

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_current_timestamp() -> object:
    return datetime.utcnow()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_file_location_url(lakehouse_name,file_relative_path) -> str:
    print(f"lakehouse_name: {lakehouse_name}")
    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    lakehouse_files_path = f"{lakehouse_manager.lakehouse_path}/Files"
    return f"{lakehouse_files_path}/{file_relative_path}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def send_message_to_logs(message_metadata: object, metadata_config_dict: object, log_file_name: str) -> object:
    message = {
        "product_name": product_name,
        "feed_name": feed_name,
        "dataset_name": metadata_config_dict['datasetName'],
        "source_system": metadata_config_dict['sourceSystemProperties']['sourceSystemName'],
        "metadata": message_metadata,
        "zone": "Extract",
        "stage": "Ingestion",
        "orchestration_tool": "spark",
        "zone_start_date_time": str(processing_start_time),
        "zone_end_date_time": str(get_current_timestamp()),
        "elt_id": elt_id,
        "run_id": run_id,
        "invocation_id": invocation_id
    }

    output_message = json.dumps(message)

    # save message content to a log file later processesing
    try:   
        nu.fs.put(log_file_name, output_message, True)
    except Exception as error:
        raise error

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

processing_start_time = get_current_timestamp()
metadata_config_dict = json.loads(dataset_config_json, strict=False)

# get log file url
logs_lakehouse_name = "den_lhw_pdi_001_observability"
log_file_relative_path = f"Metadata_Logs/{uuid4()}.json"
raw_lakehouse_name = metadata_config_dict['rawProperties']['lakehouseName']
log_file_name = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lh_observability_id}/Files/{log_file_relative_path}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# instantiate Extract class instance and call its methods 
try:
    source_config = {
        "elt_id": elt_id,
        "run_id": run_id,
        "watermark_start": watermark_start,
        "watermark_end": watermark_end
    }
    data = (
        Extract()
        .source(
            dataset_config_json
        )
        .configure_source(source_config)
        .get_data()
        .copy_data()
        .metrics("dict")
    )
except Exception as error:
    data = {
        "error": str(error),
        "extractStartTime": str(processing_start_time) 
    }
    print("Exception occured while processing the data: ", error) 
    raise error
finally:
    send_message_to_logs(data, metadata_config_dict, log_file_name)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

nu.notebook.exit(json.dumps(data))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
