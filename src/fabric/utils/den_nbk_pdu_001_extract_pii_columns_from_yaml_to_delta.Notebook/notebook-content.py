# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# ###### Notebook: Extract PII Columns from YAML Configs
# ###### Purpose:  Scan OneLake YAML files -> extract declared PII columns -> store in Observability Delta table
# ###### Author:   skolpakov
# ###### Updated:  March 2026
# ######  Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/GDAP-Fluidity-PlatformServices/_git/PlatformServices-Fabric?path=/docs/fabric/utils/readme_pii_columns.md&version=GBmain&_a=contents) for information.

# CELL ********************

import logging
import fsspec
import yaml
import posixpath
from datetime import datetime
from pyspark.sql.functions import lit, current_timestamp, explode, col, lit
from delta.tables import DeltaTable
from typing import List, Dict, Any

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configuration

WORKSPACE_NAME = notebookutils.runtime.context.get("currentWorkspaceName")  # Fabric context

# Output table location
OUTPUT_SCHEMA = "audit"
OUTPUT_TABLE  = "yaml_pii_columns_config"

# Default scan path (can be overridden)
DEFAULT_YAML_ROOT = None  # will be built dynamically below

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(levelname)-8s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_lakehouse_paths():
    """Retrieve workspace/lakehouse identifiers from Fabric context."""
    metadata_lh = notebookutils.lakehouse.get("den_lhw_pdi_001_metadata")
    observ_lh   = notebookutils.lakehouse.get("den_lhw_pdi_001_observability")
    
    workspace_id = metadata_lh["workspaceId"]
    metadata_id  = metadata_lh["id"]
    observ_id    = observ_lh["id"]
    
    yaml_root = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{metadata_id}/Files/data_product"
    table_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{observ_id}/Tables/{OUTPUT_SCHEMA}/{OUTPUT_TABLE}"
    
    return yaml_root, table_path, workspace_id

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def collect_pii_info_from_yaml_files(root_dir: str) -> List[Dict[str, Any]]:
    """
    Recursively scan ABFSS path for YAML files and extract target + pii_columns.
    
    Returns list of records (only when pii_columns is non-empty).
    """
    fs = fsspec.filesystem("abfss", account_name="onelake", account_host="onelake.dfs.fabric.microsoft.com")
    records = []
    file_count = 0
    
    logger.info(f"Starting recursive scan of: {root_dir}")
    
    for dirpath, _, filenames in fs.walk(root_dir, detail=False):
        dirpath = dirpath.rstrip('/')
        for filename in filenames:
            if not filename.lower().endswith(('.yaml', '.yml')):
                continue
                
            file_count += 1
            full_path = posixpath.join(dirpath, filename)
            
            try:
                with fs.open(full_path, mode="rt", encoding="utf-8") as f:
                    content = yaml.safe_load(f)
                    
                if not isinstance(content, dict):
                    continue
                    
                target = content.get("target", {})
                if not isinstance(target, dict):
                    continue
                    
                lakehouse = target.get("lakehouse")
                schema    = target.get("schema")
                table     = target.get("table")
                
                if not all([lakehouse, schema, table]):
                    continue
                    
                pii_list = target.get("pii_columns", [])
                if not isinstance(pii_list, list) or not pii_list:
                    continue
                    
                # Store relative path for readability
                relative_path = full_path.split("Files/", 1)[1] if "Files/" in full_path else full_path
                
                records.append({
                    "lakehouse": lakehouse,
                    "schema": schema,
                    "table": table,
                    "pii_columns": pii_list,
                    "yaml_file_path": relative_path,
                    "yaml_file_name": filename,
                    "loaded_timestamp": datetime.utcnow().isoformat()
                })
                
            except yaml.YAMLError as ye:
                logger.warning(f"Invalid YAML → skipping {full_path}: {ye}")
            except Exception as e:
                logger.error(f"Failed to process {full_path}: {type(e).__name__} - {str(e)}")
    
    logger.info(f"Scan complete. Files checked: {file_count:,} | Records with PII: {len(records):,}")
    return records


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def main():
    start_time = datetime.now()
    
    # ─── Get dynamic paths ───
    yaml_root, table_path, workspace_id = get_lakehouse_paths()
    logger.info(f"Workspace: {WORKSPACE_NAME} | YAML root: {yaml_root}")
    logger.info(f"Output table path: {table_path}")
    
    # ─── Scan ───
    all_records = collect_pii_info_from_yaml_files(yaml_root)
    
    if not all_records:
        logger.info("No tables with declared PII columns found. Exiting.")
        return
    
    # ─── Build DataFrame ───
    df = spark.createDataFrame(all_records)
    
    df_final = df.select(
        lit(WORKSPACE_NAME).alias("workspace"),
        col("lakehouse"),
        col("schema"),
        col("table"),
        explode("pii_columns").alias("pii_column"),
        col("yaml_file_path"),
        col("yaml_file_name"),
        current_timestamp().alias("loaded_timestamp")   # Spark-managed UTC timestamp
    )
    
    # ─── Merge or Create ───
    try:
        delta_table = DeltaTable.forPath(spark, table_path)
        logger.info("Target Delta table exists -> performing merge")
        
        delta_table.alias("target").merge(
            df_final.alias("source"),
            """
            target.workspace = source.workspace AND
            target.lakehouse = source.lakehouse AND
            target.schema    = source.schema    AND
            target.table     = source.table     AND
            target.pii_column = source.pii_column
            """
        ).whenMatchedUpdateAll() \
         .whenNotMatchedInsertAll() \
         .execute()
         
    except Exception as e:
        logger.info(f"Target table does not exist or cannot be opened -> creating it ({table_path})")
        df_final.write \
            .format("delta") \
            .mode("overwrite") \
            .option("overwriteSchema", "true") \
            .save(table_path)
    
    duration = datetime.now() - start_time
    duration_seconds = duration.total_seconds()
    logger.info(f"Job completed successfully in {duration_seconds:.1f} seconds | Rows written: {df_final.count():,}")
    
    # Optional: preview
    # df_final.limit(10).show(truncate=False)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    main()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
