# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "ba6ff98b-55c6-41d2-b003-6d0e5e9ab772",
# META       "default_lakehouse_name": "den_lhw_dpr_001_policy_product",
# META       "default_lakehouse_workspace_id": "576daab2-755c-48e5-9567-7583c3efb1b0",
# META       "known_lakehouses": [
# META         {
# META           "id": "ba6ff98b-55c6-41d2-b003-6d0e5e9ab772"
# META         }
# META       ]
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
# Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/DnA%20Pdt%20and%20Prc/_git/DnA%20Pdt%20and%20Prc%20-%20Comn%20Pdt%20Lyr?path=%2Fdocs%2Fpolicy_dp%2Ffabric%2Fcicd_init_and_seed_policy_dp.md&version=GBmain&_a=contents) for detailed instructions and information

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


SCHEMA_NAME = "wc"
DDL_FILE_NAME = "Workers' COMP Physical Data Model DDL.txt"
FILE_PATH = f"abfss://{WORKSPACE_ID}@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/wc_dp/ellie_ddl/{DDL_FILE_NAME}"
EXPECTED_DIM_WC_CARRIER_PLACEMENT_POINTS_RULE = 20821 # 20,819 main + 2 default

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

def create_and_seed_dim_wc_carrier_placement_points_rule(schema_name: str):
    """Create, truncate, seed dim_wc_carrier_placement_points_rule using standard prm pattern"""

    try:
        logger.info(f"Creating and seeding {schema_name}.dim_wc_carrier_placement_points_rule")
        prm_create = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.dim_wc_carrier_placement_points_rule (
            wc_carr_plcmnt_points_rule_key INT,
            wc_carr_plcmnt_points_rule_business_key STRING,
            rating_type STRING,
            minimum_value DECIMAL(8,4),
            maximum_value DECIMAL(8,4),
            low_code STRING,
            high_code STRING,
            points_assigned INT,
            dl_eltid STRING,
            dl_runid STRING,
            dl_row_insert_agent STRING,
            dl_row_hash STRING,
            dl_is_current_flag BOOLEAN,
            dl_row_expiration_date DATE,
            dl_row_effective_date DATE,
            dl_row_update_timestamp TIMESTAMP,
            dl_row_insert_timestamp TIMESTAMP,
            dl_is_deleted_flag BOOLEAN
        ) USING DELTA
        """

        spark.sql(prm_create)
        logger.info(f"Table {schema_name}.dim_wc_carrier_placement_points_rule created successfully")
        prm_truncate = f"""
        TRUNCATE TABLE {schema_name}.dim_wc_carrier_placement_points_rule
        """

        spark.sql(prm_truncate)
        logger.info(f"Table {schema_name}.dim_wc_carrier_placement_points_rule truncated successfully")
        prm_default = f"""
        INSERT INTO {schema_name}.dim_wc_carrier_placement_points_rule
        SELECT
            -1 AS wc_carr_plcmnt_points_rule_key,
            'unknown' AS wc_carr_plcmnt_points_rule_bus_key,
            'unknown' AS rating_type,
            NULL AS minimum_value,
            NULL AS maximum_value,
            'unknown' AS low_code,
            'unknown' AS high_code,
            -1 AS points_assigned,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag

        UNION ALL

        SELECT
            -2 AS wc_carr_plcmnt_points_rule_key,
            'not applicable' AS wc_carr_plcmnt_points_rule_business_key,
            'not applicable' AS rating_type,
            NULL AS minimum_value,
            NULL AS maximum_value,
            'not applicable' AS low_code,
            'not applicable' AS high_code,
            -2 AS points_assigned,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        """

        spark.sql(prm_default)
        logger.info(f"Default rows inserted into {schema_name}.dim_wc_carrier_placement_points_rule successfully")

        prm_seed = f"""
        INSERT INTO {schema_name}.dim_wc_carrier_placement_points_rule

        WITH base_data AS (

            SELECT 'haz_a_1' AS wc_carr_plcmnt_points_rule_business_key, 'hazard' AS rating_type, NULL AS minimum_value, NULL AS maximum_value, 'A/1' AS low_code, 'A/1' AS high_code, 25 AS points_assigned UNION ALL
            SELECT 'haz_b_2' , 'hazard' , NULL , NULL , 'B/2' , 'B/2' , 25 UNION ALL
            SELECT 'haz_c_3' , 'hazard' , NULL , NULL , 'C/3' , 'C/3' , 25 UNION ALL
            SELECT 'haz_d_4' , 'hazard' , NULL , NULL , 'D/4' , 'D/4' , 25 UNION ALL
            SELECT 'haz_e_5' , 'hazard' , NULL , NULL , 'E/5' , 'E/5' , 15 UNION ALL
            SELECT 'haz_f_6' , 'hazard' , NULL , NULL , 'F/6' , 'F/6' , 15 UNION ALL
            SELECT 'haz_g_7' , 'hazard' , NULL , NULL , 'G/7' , 'G/7' ,  0 UNION ALL
            SELECT 'haz_null' , 'hazard' , NULL , NULL , NULL , NULL ,  0 UNION ALL

            SELECT 'exp_0_.9099' , 'expmod' , 0 , .9099 , NULL , NULL , 25  UNION ALL
            SELECT 'exp_.91_1.1099' , 'expmod' , .9100 , 1.1099 , NULL , NULL , 15  UNION ALL
            SELECT 'exp_1.11_1.2599' , 'expmod' , 1.1100 , 1.2599 , NULL , NULL ,  5  UNION ALL
            SELECT 'exp_1.26_1000' , 'expmod' , 1.2600 , 1000 , NULL , NULL ,  0  UNION ALL
            SELECT 'exp_null' , 'expmod' , NULL , NULL , NULL , NULL ,  5  UNION ALL

            SELECT 'dnb_0_199' , 'dnbscore' , 0 , 199 , NULL , NULL , 0  UNION ALL
            SELECT 'dnb_200_299' , 'dnbscore' , 200 , 299 , NULL , NULL , 10  UNION ALL
            SELECT 'dnb_300_399' , 'dnbscore' , 300 , 399 , NULL , NULL , 15  UNION ALL
            SELECT 'dnb_400_1000' , 'dnbscore' , 400 , 1000 , NULL , NULL , 25  UNION ALL
            SELECT 'dnb_null' , 'dnbscore' , NULL , NULL , NULL , NULL ,  0  UNION ALL

            SELECT 'wcy_0_0' , 'wcyears' , 0 , 0.9999 , NULL , NULL ,-15  UNION ALL
            SELECT 'wcy_1_2' , 'wcyears' , 1 , 2.9999 , NULL , NULL ,  5  UNION ALL
            SELECT 'wcy_3_5' , 'wcyears' , 3 , 5.9999 , NULL , NULL , 15  UNION ALL
            SELECT 'wcy_6_1000' , 'wcyears' , 6 , 1000 , NULL , NULL , 25  UNION ALL
            SELECT 'wcy_null' , 'wcyears' , NULL , NULL , NULL , NULL , 0 
        ),

        numbered_data AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY wc_carr_plcmnt_points_rule_business_key)
                    AS wc_carr_plcmnt_points_rule_key,
                *
            FROM base_data
        )

        SELECT
            wc_carr_plcmnt_points_rule_key,
            wc_carr_plcmnt_points_rule_business_key,
            rating_type,
            minimum_value,
            maximum_value,
            low_code,
            high_code,
            points_assigned,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        FROM numbered_data
        """

        spark.sql(prm_seed)
        logger.info(f"Table {schema_name}.dim_wc_carrier_placement_points_rule seeded successfully")

    except Exception as e:
        logger.error(f"Error creating dim_wc_carrier_placement_points_rule: {str(e)}")
        raise        

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_and_seed_segmentation_experience_mod(schema_name: str):
    """Create, truncate, seed segmentation_experience_mod using standard prm pattern"""

    try:
        logger.info(f"Creating and seeding {schema_name}.segmentation_experience_mod")
        prm_create = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.segmentation_experience_mod (
            experience_mod_segment_key INT,
            experience_mod_segment_bus_key STRING,
            minimum_value DECIMAL(8,4),
            maximum_value DECIMAL(8,4),
            sort_order INT,
            dl_eltid STRING,
            dl_runid STRING,
            dl_row_insert_agent STRING,
            dl_row_hash STRING,
            dl_is_current_flag BOOLEAN,
            dl_row_expiration_date DATE,
            dl_row_effective_date DATE,
            dl_row_update_timestamp TIMESTAMP,
            dl_row_insert_timestamp TIMESTAMP,
            dl_is_deleted_flag BOOLEAN
        ) USING DELTA
        """

        spark.sql(prm_create)
        logger.info(f"Table {schema_name}.segmentation_experience_mod created successfully")
        prm_truncate = f"""
        TRUNCATE TABLE {schema_name}.segmentation_experience_mod
        """

        spark.sql(prm_truncate)
        logger.info(f"Table {schema_name}.segmentation_experience_mod truncated successfully")
        prm_default = f"""
        INSERT INTO {schema_name}.segmentation_experience_mod
        SELECT
            -1 AS experience_mod_segment_key,
            'unknown' AS experience_mod_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag

        UNION ALL

        SELECT
            -2 AS experience_mod_segment_key,
            'not applicable' AS experience_mod_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        """

        spark.sql(prm_default)
        logger.info(f"Default rows inserted into {schema_name}.segmentation_experience_mod successfully")

        prm_seed = f"""
        INSERT INTO {schema_name}.segmentation_experience_mod

        WITH base_data AS (

            SELECT 'Less than 1.00' AS experience_mod_segment_bus_key, 0.0000 AS minimum_value, 0.9999 AS maximum_value, 1 AS sort_order UNION ALL
            SELECT '1.00' , 1.0000, 1.0099, 2 UNION ALL
            SELECT '1.01 - 1.05', 1.0100, 1.0599, 3 UNION ALL
            SELECT '1.06 - 1.15', 1.0600, 1.1599, 4 UNION ALL
            SELECT '1.16 - 1.50', 1.1600, 1.5000, 5 UNION ALL
            SELECT 'Greater than 1.50', 1.5001, 9999.0000, 6            
        ),

        numbered_data AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY experience_mod_segment_bus_key)
                    AS experience_mod_segment_key,
                *
            FROM base_data
        )

        SELECT
            experience_mod_segment_key,
            experience_mod_segment_bus_key,
            minimum_value,
            maximum_value,
            sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        FROM numbered_data
        """

        spark.sql(prm_seed)
        logger.info(f"Table {schema_name}.segmentation_experience_mod seeded successfully")

    except Exception as e:
        logger.error(f"Error creating segmentation_experience_mod: {str(e)}")
        raise        

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_and_seed_segmentation_dnb_score(schema_name: str):
    """Create, truncate, seed segmentation_dnb_score using standard prm pattern"""

    try:
        logger.info(f"Creating and seeding {schema_name}.segmentation_dnb_score")
        prm_create = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.segmentation_dnb_score (
            dnb_score_segment_key INT,
            dnb_score_segment_bus_key STRING,
            minimum_value DECIMAL(8,4),
            maximum_value DECIMAL(8,4),
            sort_order INT,
            dl_eltid STRING,
            dl_runid STRING,
            dl_row_insert_agent STRING,
            dl_row_hash STRING,
            dl_is_current_flag BOOLEAN,
            dl_row_expiration_date DATE,
            dl_row_effective_date DATE,
            dl_row_update_timestamp TIMESTAMP,
            dl_row_insert_timestamp TIMESTAMP,
            dl_is_deleted_flag BOOLEAN
        ) USING DELTA
        """

        spark.sql(prm_create)
        logger.info(f"Table {schema_name}.segmentation_dnb_score created successfully")
        prm_truncate = f"""
        TRUNCATE TABLE {schema_name}.segmentation_dnb_score
        """

        spark.sql(prm_truncate)
        logger.info(f"Table {schema_name}.segmentation_dnb_score truncated successfully")
        prm_default = f"""
        INSERT INTO {schema_name}.segmentation_dnb_score
        SELECT
            -1 AS dnb_score_segment_key,
            'unknown' AS dnb_score_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag

        UNION ALL

        SELECT
            -2 AS dnb_score_segment_key,
            'not applicable' AS dnb_score_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        """

        spark.sql(prm_default)
        logger.info(f"Default rows inserted into {schema_name}.segmentation_dnb_score successfully")

        prm_seed = f"""
        INSERT INTO {schema_name}.segmentation_dnb_score

        WITH base_data AS (

            SELECT '0 - 249' AS dnb_score_segment_bus_key, 0 AS minimum_value, 249 AS maximum_value, 1 AS sort_order UNION ALL
            SELECT '250 - 299', 250, 299, 2 UNION ALL
            SELECT '300 - 999', 300, 999, 3 
            ),

        numbered_data AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY dnb_score_segment_bus_key)
                    AS dnb_score_segment_key,
                *
            FROM base_data
        )

        SELECT
            dnb_score_segment_key,
            dnb_score_segment_bus_key,
            minimum_value,
            maximum_value,
            sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        FROM numbered_data
        """

        spark.sql(prm_seed)
        logger.info(f"Table {schema_name}.segmentation_dnb_score seeded successfully")

    except Exception as e:
        logger.error(f"Error creating segmentation_dnb_score: {str(e)}")
        raise        

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_and_seed_segmentation_prior_wc_years(schema_name: str):
    """Create, truncate, seed segmentation_prior_wc_years using standard prm pattern"""

    try:
        logger.info(f"Creating and seeding {schema_name}.segmentation_prior_wc_years")
        prm_create = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.segmentation_prior_wc_years (
            prior_wc_years_segment_key INT,
            prior_wc_years_segment_bus_key STRING,
            minimum_value DECIMAL(8,4),
            maximum_value DECIMAL(8,4),
            sort_order INT,
            dl_eltid STRING,
            dl_runid STRING,
            dl_row_insert_agent STRING,
            dl_row_hash STRING,
            dl_is_current_flag BOOLEAN,
            dl_row_expiration_date DATE,
            dl_row_effective_date DATE,
            dl_row_update_timestamp TIMESTAMP,
            dl_row_insert_timestamp TIMESTAMP,
            dl_is_deleted_flag BOOLEAN
        ) USING DELTA
        """

        spark.sql(prm_create)
        logger.info(f"Table {schema_name}.segmentation_prior_wc_years created successfully")
        prm_truncate = f"""
        TRUNCATE TABLE {schema_name}.segmentation_prior_wc_years
        """

        spark.sql(prm_truncate)
        logger.info(f"Table {schema_name}.segmentation_prior_wc_years truncated successfully")
        prm_default = f"""
        INSERT INTO {schema_name}.segmentation_prior_wc_years
        SELECT
            -1 AS prior_wc_years_segment_key,
            'unknown' AS prior_wc_years_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag

        UNION ALL

        SELECT
            -2 AS prior_wc_years_segment_key,
            'not applicable' AS prior_wc_years_segment_bus_key,
            NULL AS minimum_value,
            NULL AS maximum_value,
            NULL AS sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        """

        spark.sql(prm_default)
        logger.info(f"Default rows inserted into {schema_name}.segmentation_prior_wc_years successfully")

        prm_seed = f"""
        INSERT INTO {schema_name}.segmentation_prior_wc_years

        WITH base_data AS (

            SELECT '0' AS prior_wc_years_segment_bus_key, 0.0000 AS minimum_value, 0.9999 AS maximum_value, 1 AS sort_order UNION ALL
            SELECT '1', 1.000, 1.999, 2 UNION ALL
            SELECT '2', 2.000, 2.999, 3 UNION ALL
            SELECT 'Greater than or equal to 3', 3.000, 9999.000, 4
            ),

        numbered_data AS (
            SELECT
                ROW_NUMBER() OVER (ORDER BY prior_wc_years_segment_bus_key)
                    AS prior_wc_years_segment_key,
                *
            FROM base_data
        )

        SELECT
            prior_wc_years_segment_key,
            prior_wc_years_segment_bus_key,
            minimum_value,
            maximum_value,
            sort_order,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            TRUE AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            FALSE AS dl_is_deleted_flag
        FROM numbered_data
        """

        spark.sql(prm_seed)
        logger.info(f"Table {schema_name}.segmentation_prior_wc_years seeded successfully")

    except Exception as e:
        logger.error(f"Error creating segmentation_prior_wc_years: {str(e)}")
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

        # Create and seed dim_wc_carrier_placement_points_rule
        create_and_seed_dim_wc_carrier_placement_points_rule(SCHEMA_NAME)

        # Create and seed segmentation_experience_mod
        create_and_seed_segmentation_experience_mod(SCHEMA_NAME)

        # Create and seed segmentation_dnb_score
        create_and_seed_segmentation_dnb_score(SCHEMA_NAME)

        # Create and seed segmentation_prior_wc_years
        create_and_seed_segmentation_prior_wc_years(SCHEMA_NAME)

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
