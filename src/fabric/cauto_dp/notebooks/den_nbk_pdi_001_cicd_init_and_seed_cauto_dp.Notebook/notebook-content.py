# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "0693055c-be39-4d2a-a54e-1fddeb0ce6dc",
# META       "default_lakehouse_name": "den_lhw_dpr_001_cauto_product",
# META       "default_lakehouse_workspace_id": "a5b83bde-449c-4623-a821-90f37a02ac15"
# META     },
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# MARKDOWN ********************

# ## Notebook Overview
# 
# 
# 
# Pease refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/DnA%20Pdt%20and%20Prc/_git/DnA%20Pdt%20and%20Prc%20-%20Comn%20Pdt%20Lyr?path=%2Fdocs%2Fpolicy_dp%2Ffabric%2Fcicd_init_and_seed_policy_dp.md&version=GBmain&_a=contents) for detailed instructions and information


# CELL ********************

import logging
import re
from datetime import datetime

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configuration constants and variables
LAKEHOUSE_PROPERTIES = notebookutils.lakehouse.get("den_lhw_pdi_001_metadata")
WORKSPACE_ID = LAKEHOUSE_PROPERTIES["workspaceId"]
LAKEHOUSE_ID  = LAKEHOUSE_PROPERTIES["id"]

SCHEMA_NAME  = "cauto"
DDL_FILE_NAME = "Commercial Auto Physical Data Model DDL.txt"
FILE_PATH = f"abfss://{WORKSPACE_ID}@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/cauto_dp/ellie_ddl/{DDL_FILE_NAME}"


# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_schema(schema_name: str):
    """ Create and set the schema as the current context."""
    try:
        logger.info(f"Ensuring schema {schema_name} exists")
        spark.sql(f"CREATE SCHEMA IF NOT EXISTS {schema_name}")
        logger.info(f"Schema {schema_name} ready")
        spark.sql(f"USE {schema_name}")
        logger.info(f"Schema {schema_name} set as current context")
    except Exception as e:
        logger.error(f"Error creating or setting schema {schema_name}: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_input_file(file_path: str) -> str:
    """Read the DDL file from the specified path.""" 
    try:
        logger.info(f"Reading file from {file_path}")
        ddl_content = spark.read.text(file_path).collect()
        ddl_text = "\n".join([row.value for row in ddl_content])
        logger.info("File read successfully")
        return ddl_text
    except Exception as e:
        logger.error(f"Error reading file: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def extract_table_names(ddl_text: str) -> list:
    """Extract table names from DDL text."""
    try:
        logger.info("Extracting table names from DDL")
        # Regular expression to match CREATE TABLE statements and extract table names
        table_pattern = r"CREATE TABLE IF NOT EXISTS\s+[`']?(\w+)[`']?\s*\("
        table_names = re.findall(table_pattern, ddl_text, re.IGNORECASE)
        if not table_names:
            logger.error("No table names found in DDL")
            raise ValueError("No valid CREATE TABLE statements found in DDL")
        logger.info(f"Extracted table names: {table_names}")
        return table_names
    except Exception as e:
        logger.error(f"Error extracting table names: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def execute_ddl_statements(schema_name: str, ddl_text: str):
    """Execute DDL statements from the input file."""
    try:

        # Parse the DDL statements (assuming statements are separated by ';')
        ddl_statements = [stmt.strip() + ';' for stmt in ddl_text.split(';') if stmt.strip()]
        for i, stmt in enumerate(ddl_statements):
            try:
                logger.info(f"Executing DDL statement {i+1}: {stmt[:100]}...")
                spark.sql(stmt)
                logger.info(f"DDL statement {i+1} executed successfully")
            except Exception as e:
                logger.error(f"Error executing DDL statement {i+1}: {str(e)}")
                continue
    except Exception as e:
        logger.error(f"Error executing DDL statements: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def validate_tables(schema_name: str, table_names: list):
    """Validate table existence and row counts."""
    try:
        # table_names.extend(['dim_date', 'dim_policy_status'])
        for table in table_names:
            try:
                logger.info(f"Validating table: {schema_name}.{table}")
                row_count = spark.sql(f"SELECT COUNT(*) AS row_count FROM {table}").collect()[0]['row_count']
                if table == 'dim_date':
                    row_count = spark.sql(f"SELECT COUNT(*) AS row_count FROM {table}").collect()[0]['row_count']
                    if row_count != EXPECTED_DIM_DATE_ROWS:
                        logger.warning(f"Table {schema_name}.dim_date has {row_count} rows, expected {EXPECTED_DIM_DATE_ROWS}")
                    else:
                        logger.info(f"Table {schema_name}.dim_date has expected {row_count} rows")
                elif table == 'dim_policy_status':
                    if row_count != EXPECTED_DIM_POLICY_STATUS_ROWS:
                        logger.warning(f"Table {schema_name}.dim_policy_status has {row_count} rows, expected {EXPECTED_DIM_POLICY_STATUS_ROWS}")
                    else:
                        logger.info(f"Table {schema_name}.dim_policy_status has expected {row_count} rows")
                else:
                    logger.info(f"Table {schema_name}.{table} exists with {row_count} rows")
                # spark.sql(f"DESCRIBE {table}").show(5)
            except Exception as e:
                logger.error(f"Validation failed for table {schema_name}.{table}: {str(e)}")
    except Exception as e:
        logger.error(f"Error during table validation: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def main(run_me: bool = True):
    """Main function to orchestrate notebook execution."""
    start_time = datetime.now()
    logger.info(f"Starting notebook execution at {start_time}")
    
    if not run_me:
        logger.info("run_me is False, skipping notebook execution")
        return  
    try:
        # Create schema
        create_schema(SCHEMA_NAME)

        # Read DDL file
        ddl_text = read_input_file(FILE_PATH)   

        # Extract table names
        table_names = extract_table_names(ddl_text)
        
        # Execute DDL statements
        execute_ddl_statements(SCHEMA_NAME, ddl_text)
                       
        # Validate tables
        validate_tables(SCHEMA_NAME, table_names)

        end_time = datetime.now()
        logger.info(f"Notebook execution completed successfully at {end_time}. Duration: {end_time - start_time}")
    except Exception as e:
        logger.error(f"Notebook execution failed: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    # Set run_me parameter (default True)
    run_me = True  # Change to False to skip execution
    
    # Validate run_me parameter
    if not isinstance(run_me, bool):
        logger.error("run_me parameter must be a boolean")
        raise ValueError("run_me parameter must be a boolean")
    
    # Run main function
    main(run_me)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
