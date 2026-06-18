# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "jupyter",
# META     "jupyter_kernel_name": "python3.11"
# META   },
# META   "dependencies": {
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# PARAMETERS CELL ********************

dataset_list = ''
lh_metadata_id = ""
workspace_id = ""

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "jupyter_python"
# META }

# CELL ********************

import fsspec
import json

def generate_watermark(source_config_folder_name, source_config_file_name):
    input_path = source_config_folder_name + source_config_file_name
    watermarkPath = f"{source_config_folder_name}watermark/{source_config_file_name}"

    storage_options = {
        "account_name": "onelake",
        "account_host": "onelake.dfs.fabric.microsoft.com",
    }
    onelake_fs = fsspec.filesystem("abfss", **storage_options)

    dataset = json.load(onelake_fs.open(input_path, "r"))
    sourceSystemProperties = dataset["sourceSystemProperties"]

    # set initial values
    query = ''
    columnsList = "*"
    whereClause = ''
    watermarkValue = ''
    sourceWatermarkIdentifier = ''
    jsonWatermarkQuery = ''

    if dataset["datasetTypeName"] in ["database","file"]:
        # build column list
        columnsList = ",".join(sourceSystemProperties.get("includeSpecificColumns", ["*"]))

        if sourceSystemProperties["ingestType"] == "watermark":
            # add watermark column to select list
            sourceWatermarkIdentifier = sourceSystemProperties["sourceWatermarkIdentifier"]
            columnsList += f",{sourceWatermarkIdentifier} as dl_watermark"

            # set watermark value using existing value if available
            watermarkValue = '1900-01-01T00:00:00Z'
            if onelake_fs.exists(watermarkPath):
                existingWatermarkJson = json.load(onelake_fs.open(watermarkPath, "r", encoding="utf-8-sig"))
                if existingWatermarkJson["sourceWatermarkIdentifier"] == sourceWatermarkIdentifier and existingWatermarkJson["watermarkValue"]:
                    watermarkValue = existingWatermarkJson["watermarkValue"]

            # build where clause
            whereClause = f"WHERE {sourceWatermarkIdentifier} > CAST('{watermarkValue}' AS datetime2)"

        filterExpression = sourceSystemProperties.get('filterExpression')

        if sourceSystemProperties.get("isDynamicQuery") and filterExpression:
            filterExpression = filterExpression.strip().lower()
            
            if filterExpression[0:6] == "where ":
                filterExpression = filterExpression.replace("where", "", 1).lstrip()
            elif filterExpression[0:4] == "and ":
                filterExpression = filterExpression.replace("and", "", 1).lstrip()

            if not whereClause:
                whereClause = "where " + filterExpression
            else:
                whereClause = f"{whereClause} and {filterExpression}"

        # set query
        query = f"SELECT {columnsList} FROM {dataset.get('datasetSchema', 'dbo')}.{dataset['datasetName']} {whereClause}"

        # build json for watermark file
        jsonWatermarkQuery = {
            "query": query,
            "sourceWatermarkIdentifier": sourceWatermarkIdentifier,
            "watermarkValue": watermarkValue
        }

        # write json to lakehouse
        with onelake_fs.open(watermarkPath, "w") as json_file:
            json.dump(jsonWatermarkQuery, json_file, indent=4)
            
        print(f"Watermark file generated at: {watermarkPath}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "jupyter_python"
# META }

# CELL ********************

dataset_list = json.loads(dataset_list)

dataset_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lh_metadata_id}/Files/datasets"
for dataset in dataset_list:
    source_config_folder_name = f"{dataset_path}/{dataset['sourceConfigFolderName']}/"
    source_config_file_name = f"{dataset['fileName']}.json"
    generate_watermark(source_config_folder_name, source_config_file_name)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "jupyter_python"
# META }
