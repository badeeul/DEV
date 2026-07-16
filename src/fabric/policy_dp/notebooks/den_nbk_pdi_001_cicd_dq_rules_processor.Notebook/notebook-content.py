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

# ## Notebook Overview# 
# TO DO: Update the link once file is created# 
# # 
# Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/DnA%20Pdt%20and%20Prc/_git/DnA%20Pdt%20and%20Prc%20-%20Comn%20Pdt%20Lyr?path=%2Fdocs%2Fpolicy_dp%2Ffabric%2Fcicd_run_init_pipeline.md&version=GBmain&_a=contents) for detailed instructions and information


# CELL ********************

import json
import fsspec
import warnings
from datetime import datetime
from pyspark.sql.functions import col, lit, row_number, to_json, collect_list, current_timestamp, struct
from pyspark.sql.window import Window
from jsonschema import validate, ValidationError
from typing import Dict
import logging
import pandas as pd
import pkg_resources
import time

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configuration
CONFIG = {
    "workspace_id": "Dynamicaly set based on the runtime environment",
    "metadata_lakehouse_id": "Dynamicaly set based on the runtime environment",
    "metadata_lakehouse_name": "den_lhw_pdi_001_metadata",
    "observability_lakehouse_name": "den_lhw_pdi_001_observability",
    "observability_lakehouse_id": "Dynamicaly set based on the runtime environment",
    "excel_folder_path": "data_quality",  # Changed from excel_file_name to folder path
    "json_file_name": "dq_template_output.json",
    "sheet_name": "Rule Master Policy Data Product",
    "skip_rows": 1,
    "table_name": "dim_dq_rule_master",
    "schema_name": "data_quality",
    "whl_name": "spark_engine-0.1.0-py3-none-any.whl"
}

# JSON Schema for validation
DQ_RULE_CONSTRAINT_SCHEMA = {
    "type": "object",
    "properties": {
        "type": {"type": "string"},
        "kwargs": {"type": "object"},
        "meta": {"type": "object"},
    },
    "required": ["type", "kwargs"],
}

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def validate_config(config):
    """Validate configuration parameters"""
    required_keys = ["workspace_id", "metadata_lakehouse_id", "metadata_lakehouse_name", 
                    "observability_lakehouse_name", "observability_lakehouse_id", "excel_folder_path", "json_file_name",
                    "sheet_name", "skip_rows", "table_name", "schema_name", "whl_name"]
    missing_keys = [key for key in required_keys if key not in config]
    if missing_keys:
        raise ValueError(f"Missing configuration keys: {missing_keys}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_file_paths(config, excel_file_name: str = None):
    """
    Create file paths using configuration.
    
    Args:
        config (dict): Configuration dictionary
        excel_file_name (str, optional): Name of a specific Excel file. If None, returns base paths only.
    
    Returns:
        dict: Dictionary containing various file paths
    """
    base_path = f"abfss://{config['workspace_id']}@onelake.dfs.fabric.microsoft.com/{config['metadata_lakehouse_id']}/Files/{config['excel_folder_path']}"
    
    paths = {
        "folder_path": base_path,
        "table_path": f"abfss://{config['workspace_id']}@onelake.dfs.fabric.microsoft.com/{config['observability_lakehouse_id']}/Tables/{config['schema_name']}/{config['table_name']}"
    }
    
    if excel_file_name:
        # For specific Excel file, create its JSON output path
        json_file_name = excel_file_name.rsplit('.', 1)[0] + '_output.json'
        paths["json_path"] = f"{base_path}/{json_file_name}"
    else:
        # Default JSON path for backward compatibility
        paths["json_path"] = f"{base_path}/{config['json_file_name']}"
    
    return paths

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_lakehouse_info(lakehouse_name: str) -> Dict[str, str]:
    """
    Retrieve information about a lakehouse by its name.
    Args:
        lakehouse_name (str): The name of the lakehouse.
    Returns:
        Dict[str, str]: Lakehouse information.
    """
    lakehouse_info = notebookutils.lakehouse.get(lakehouse_name)
    return lakehouse_info

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def list_excel_files(folder_path: str) -> list:
    """
    List all Excel files (.xlsx, .xls) in a specified folder.
    
    Args:
        folder_path (str): The OneLake path to the folder containing Excel files.
    
    Returns:
        list: List of full paths to Excel files found in the folder.
    """
    try:
        logger.info(f"Searching for Excel files in: {folder_path}")
        files = notebookutils.fs.ls(folder_path)
        
        # Filter for Excel files
        excel_files = [
            file.path for file in files 
            if not file.isDir and (file.name.lower().endswith('.xlsx') or file.name.lower().endswith('.xls'))
        ]
        
        logger.info(f"Found {len(excel_files)} Excel file(s): {[file.split('/')[-1] for file in excel_files]}")
        
        if not excel_files:
            logger.warning(f"No Excel files found in {folder_path}")
        
        return excel_files
    except Exception as e:
        logger.error(f"Error listing Excel files in {folder_path}: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def validate_row_counts(pd_df: pd.DataFrame, df: 'pyspark.sql.DataFrame', expected_min_rows: int = 1):
    """
    Validate row counts between Excel and processed DataFrame.
    
    Args:
        pd_df (pd.DataFrame): Original pandas DataFrame from Excel
        df (pyspark.sql.DataFrame): Processed Spark DataFrame
        expected_min_rows (int): Minimum expected rows for validation
    
    Raises:
        ValueError: If row counts are invalid or unexpected
    """
    excel_row_count = len(pd_df)
    processed_row_count = df.count()
    
    logger.info(f"Excel row count: {excel_row_count}")
    logger.info(f"Processed DataFrame row count: {processed_row_count}")
    
    if excel_row_count == 0:
        raise ValueError("Excel file contains no data rows")
    
    if processed_row_count == 0:
        raise ValueError("Processed DataFrame contains no rows after filtering")
    
    if processed_row_count < expected_min_rows:
        raise ValueError(f"Processed DataFrame has fewer than {expected_min_rows} rows: {processed_row_count}")
    
    if processed_row_count > excel_row_count:
        logger.warning(f"Processed row count ({processed_row_count}) exceeds Excel row count ({excel_row_count}). This may indicate data duplication.")
    
    logger.info(f"Row count validation passed: {processed_row_count} rows processed from {excel_row_count} Excel rows")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def process_excel_to_spark_df(excel_path, sheet_name, skip_rows):
    """Read Excel and convert to Spark DataFrame with transformations"""
    try:
        warnings.filterwarnings("ignore", category=UserWarning, module="openpyxl")
        
        # Read Excel directly into pandas with optimized settings
        pd_df = pd.read_excel(
            io=excel_path,
            sheet_name=sheet_name,
            skiprows=skip_rows,
            header=0,
            dtype=str
        ).dropna(how="all")

        if pd_df.empty:
            raise ValueError("Excel file is empty or contains no valid data after dropping null rows")

        # Clean string columns: strip whitespace and replace non-breaking spaces
        for col_name in pd_df.columns:
            if pd_df[col_name].dtype == "object":
                pd_df[col_name] = pd_df[col_name].astype(str).str.replace('\u00a0', '', regex=False).str.strip()

        # Convert to Spark DataFrame
        df = spark.createDataFrame(pd_df)
        
        # Apply transformations (removed row_number generation - will be added after combining all files)
        df = (df.filter(col("DQ Rule Constraint") != "nan")
              .withColumn("DQ Active Flag", lit(1))
              .withColumn("DQ Effective Date", current_timestamp())
              .withColumn("DQ Expiration Date", lit("2099-12-31 23:59:59").cast("timestamp")))

        # Validate row counts
        logger.info(f"Validating row counts")
        validate_row_counts(pd_df, df)

        return df
    except Exception as e:
        logger.error(f"Error processing Excel file: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_dq_json_struct(df):
    """Create structured JSON column (without dq_rule_master_key - will be added later)"""
    try:
        logger.info("Creating JSON structure for DataFrame")
        return df.select(
            to_json(struct(
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
                col("DQ Rule Severity Score").alias("dq_rule_severity_score"),
                col("DQ Active Flag").alias("is_current_flag"),
                col("DQ Effective Date").alias("row_effective_date"),
                col("DQ Expiration Date").alias("row_expiration_date")
            )).alias("dq_json")
        )
    except Exception as e:
        logger.error(f"Error creating JSON structure: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def save_json_to_onelake(json_data, json_path):
    """Save JSON data to OneLake"""
    storage_options = {
        "account_name": "onelake",
        "account_host": "onelake.dfs.fabric.microsoft.com",
    }
    try:
        logger.info(f"Saving JSON to {json_path}")
        onelake_fs = fsspec.filesystem("abfss", **storage_options)
        with onelake_fs.open(json_path, "w") as json_file:
            json.dump(json_data, json_file, indent=4)
    except Exception as e:
        logger.error(f"Error saving JSON to OneLake: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def write_to_delta_table(json_path, table_path):
    """Write JSON data to Delta table"""
    from spark_engine.common.observability import GDAPObservability
    from spark_engine.common.lakehouse import LakehouseManager
    try:
        lakehouse_manager = LakehouseManager(CONFIG["observability_lakehouse_id"],CONFIG["workspace_id"])
        if not lakehouse_manager.check_if_table_exists(CONFIG["table_name"], CONFIG["schema_name"]):
            # Instantiate Observability class and create tables
            logger.info(f"Creating tables in Observability lakehouse...")
            gdap_observability = GDAPObservability(spark)
            gdap_observability.create_observability_tables()
        logger.info(f"Writing to Delta table at {table_path}")
        df = (spark.read
                .option("multiLine", True)
                .json(json_path)
                .selectExpr(
                    "cast(dq_rule_master_key as int) as dq_rule_master_key",
                    "dq_rule_id",
                    "data_product_name",
                    "sub_domain_name",
                    "dq_rule_description",
                    "to_json(dq_rule_constraint) as dq_rule_constraint",
                    "dq_rule_dimension",
                    "dq_screen_type",
                    "dq_rule_applicable_lakehouse",
                    "dq_rule_applicable_schema",
                    "dq_rule_applicable_object",
                    "dq_rule_applicable_attribute",
                    "dq_rule_failure_action",
                    "cast(dq_rule_severity_score as double) as dq_rule_severity_score",
                    "cast(is_current_flag as boolean) as is_current_flag",
                    "cast(row_effective_date as timestamp) as row_effective_date",
                    "cast(row_expiration_date as timestamp) as row_expiration_date"
                ))           
        df.write.mode("overwrite").option("overwriteSchema","true").save(table_path)
        logger.info(f"Successfully wrote to Delta table at {table_path}")

        # Validate final Delta table row count
        final_count = spark.read.format("delta").load(table_path).count()
        logger.info(f"Final Delta table row count: {final_count}")
        
        if final_count == 0:
            raise ValueError("Final Delta table is empty after write operation")
    except Exception as e:
        logger.error(f"Error writing to Delta table: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def check_whl_published(whl_name: str = 'spark_engine-0.1.0-py3-none-any.whl', 
                        max_attempts: int = 10, 
                        sleep_interval_seconds: int = 60) -> bool:
    """
    Check if a custom .whl file is published/installed in the Fabric Spark environment.
    Retries until the package is found or max_attempts is reached.
    
    Args:
        whl_name (str): The name of the .whl file (e.g., 'my_package-1.0-py3-none-any.whl').
        max_attempts (int): Maximum number of attempts to check for the package.
        sleep_interval_seconds (int): Time to wait between attempts in seconds.
    
    Returns:
        bool: True if the .whl file is found in the Spark environment, False otherwise.
    """
    for attempt in range(1, max_attempts + 1):
        try:
            # Get the list of installed libraries in the Spark environment
            installed_packages = {pkg.key.lower() for pkg in pkg_resources.working_set}
            
            # Extract the package name from the .whl file (normalized to lowercase and hyphens)
            package_name = whl_name.split('-')[0].replace('_', '-').lower()
            
            # Check if the package is in the installed packages
            if package_name in installed_packages:
                logger.info(f'Package from {whl_name} is installed in the Spark environment.')
                return True
            else:
                logger.info(f'Attempt {attempt}/{max_attempts}: Package from {whl_name} not found. Retrying in {sleep_interval_seconds} seconds...')
                if attempt < max_attempts:
                    time.sleep(sleep_interval_seconds)
                else:
                    logger.warning(f'Max attempts reached. Package from {whl_name} is not installed.')
                    return False
                    
        except Exception as e:
            logger.error(f'Error checking .whl file on attempt {attempt}: {str(e)}')
            if attempt < max_attempts:
                logger.info(f'Retrying in {sleep_interval_seconds} seconds...')
                time.sleep(sleep_interval_seconds)
            else:
                logger.error(f'Max attempts reached. Failed to verify {whl_name}.')
                return False

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def main(run_me: bool = True):
    """
    Main function to orchestrate the DQ rules execution.
    Loops through all Excel files in the configured folder and processes each one.
    
    Args:
        run_me (bool): Flag to determine if the pipeline should be run.
    """
    start_time = datetime.now()
    logger.info(f"Starting script execution at {start_time}")
    
    if not run_me:
        logger.info("run_me is False, skipping execution")
        return 
    
    all_dq_data = []  # Collect all DQ rules from all Excel files
    
    try:
        # Validate configuration
        logger.info("Validating configuration")
        validate_config(CONFIG)
        
        # Check if the .whl file is published
        whl_name = CONFIG["whl_name"]
        logger.info(f'Checking if {whl_name} is published in the Spark environment...')
        if check_whl_published(whl_name):
            logger.info(f'{whl_name} is published. Proceeding with next task.')
        else:
            logger.error(f'Failed to verify {whl_name} is published. Aborting dq rules metadata run.')
            raise RuntimeError(f'{whl_name} is not published in the Spark environment.')

        # Initialize lakehouses info
        CONFIG["workspace_id"] = get_lakehouse_info(CONFIG["metadata_lakehouse_name"])["workspaceId"]
        CONFIG["metadata_lakehouse_id"] = get_lakehouse_info(CONFIG["metadata_lakehouse_name"])["id"]
        CONFIG["observability_lakehouse_id"] = get_lakehouse_info(CONFIG["observability_lakehouse_name"])["id"]
        
        # Create base file paths
        logger.info("Creating file paths")
        paths = create_file_paths(CONFIG)
        
        # Get list of all Excel files in the folder
        excel_files = list_excel_files(paths["folder_path"])
        
        if not excel_files:
            raise ValueError(f"No Excel files found in folder: {paths['folder_path']}")
        
        logger.info(f"Processing {len(excel_files)} Excel file(s)")
        
        # Process each Excel file
        for idx, excel_file_path in enumerate(excel_files, 1):
            excel_file_name = excel_file_path.split('/')[-1]
            logger.info(f"\n{'='*60}")
            logger.info(f"Processing file {idx}/{len(excel_files)}: {excel_file_name}")
            logger.info(f"{'='*60}")
            
            try:
                # Process Excel to Spark DataFrame
                logger.info(f"Processing Excel file: {excel_file_name}")
                df = process_excel_to_spark_df(excel_file_path, CONFIG["sheet_name"], CONFIG["skip_rows"])
                
                # Create JSON structure
                logger.info("Creating JSON structure")
                df_json = create_dq_json_struct(df)
                
                # Collect JSON data as a list of dictionaries
                logger.info("Collecting JSON data")
                json_rows = df_json.select("dq_json").collect()
                dq_json = [json.loads(row.dq_json) for row in json_rows]
                
                if not dq_json:
                    logger.warning(f"No valid JSON data collected from {excel_file_name}, skipping...")
                    continue
                
                # Validate and parse dq_rule_constraint for each record
                logger.info(f"Validating JSON constraints for {len(dq_json)} rules")
                for record in dq_json:
                    if not isinstance(record, dict):
                        logger.error(f"Expected dictionary, got {type(record)}: {record}")
                        raise TypeError(f"JSON record is not a dictionary: {record}")
                    try:
                        record["dq_rule_constraint"] = json.loads(record["dq_rule_constraint"])
                        validate(instance=record["dq_rule_constraint"], schema=DQ_RULE_CONSTRAINT_SCHEMA)
                    except json.JSONDecodeError as e:
                        logger.error(f"Invalid JSON in dq_rule_constraint: {record['dq_rule_constraint']}")
                        raise
                
                # Add to combined list
                all_dq_data.extend(dq_json)
                logger.info(f"Successfully processed {len(dq_json)} rules from {excel_file_name}")
                
            except Exception as e:
                logger.error(f"Error processing file {excel_file_name}: {str(e)}")
                # Decide whether to continue or stop on error
                # Current behavior: log error and continue with next file
                logger.warning(f"Skipping {excel_file_name} and continuing with next file...")
                continue
        
        if not all_dq_data:
            raise ValueError("No valid DQ rules collected from any Excel files")
        
        # Add incremental dq_rule_master_key to all records
        logger.info("Assigning incremental dq_rule_master_key to all records")
        for idx, record in enumerate(all_dq_data, start=1):
            record["dq_rule_master_key"] = idx
        
        logger.info(f"\n{'='*60}")
        logger.info(f"Total DQ rules collected from all files: {len(all_dq_data)}")
        logger.info(f"{'='*60}")
        
        # Save combined JSON to OneLake
        combined_json_path = paths["json_path"]
        logger.info(f"Saving combined JSON to {combined_json_path}")
        save_json_to_onelake(all_dq_data, combined_json_path)
        logger.info(f"DQ template conversion complete. Combined JSON saved at: {combined_json_path}")
        
        # Write to Delta table
        write_to_delta_table(combined_json_path, paths["table_path"])
        
        end_time = datetime.now()
        logger.info(f"\n{'='*60}")
        logger.info(f"Notebook execution completed successfully at {end_time}")
        logger.info(f"Duration: {end_time - start_time}")
        logger.info(f"Total files processed: {len(excel_files)}")
        logger.info(f"Total DQ rules loaded: {len(all_dq_data)}")
        logger.info(f"{'='*60}")
        
    except Exception as e:
        logger.error(f"Error in DQ rule processing: {str(e)}")
        raise
    finally:
        logger.info("Done processing DQ Rules metadata.")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    try:
        main(run_me=True)
    except Exception as e:
        logger.error(f'An error occurred during execution: {str(e)}')
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
