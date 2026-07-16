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

SCHEMA_NAME  = "policy"
DDL_FILE_NAME = "Product and Pricing Physical Data Model DDL.txt"
FILE_PATH = f"abfss://{WORKSPACE_ID}@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/policy_dp/ellie_ddl/{DDL_FILE_NAME}"
EXPECTED_DIM_DATE_ROWS = 20821 # 20,819 main + 2 default
EXPECTED_DIM_POLICY_STATUS_ROWS = 43  # 41 main + 2 default
EXPECTED_DIM_DIGITAL_DECISION_STATUS_ROW = 11  # 9 main + 2 default

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

def create_and_seed_dim_date(schema_name: str):
    """Create, truncate, and seed seed dim_date table with defult and main data."""
    try:
        logger.info(f"Creating and seeding {schema_name}.dim_date table")
        # Define the dim_date table DDL
        dim_date_ddl = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.dim_date (
            date_key INT,
            `date` DATE,
            `day` TINYINT,
            day_suffix STRING,
            day_name STRING,
            day_of_week TINYINT,
            day_of_week_in_month TINYINT,
            day_of_year SMALLINT,
            is_weekend TINYINT,
            `week` TINYINT,
            iso_week TINYINT,
            first_of_week DATE,
            last_of_week DATE,
            week_of_month TINYINT,
            `month` TINYINT,
            month_name STRING,
            first_of_month DATE,
            last_of_month DATE,
            first_of_next_month DATE,
            last_of_next_month DATE,
            `quarter` TINYINT,
            year_quarter STRING,
            first_of_quarter DATE,
            last_of_quarter DATE,
            `year` SMALLINT,
            iso_year SMALLINT,
            first_of_year DATE,
            last_of_year DATE,
            is_leap_year TINYINT,
            has_53_weeks TINYINT,
            has_53_iso_weeks TINYINT,
            mmyyyy STRING,
            style101 STRING,
            style103 STRING,
            style112 STRING,
            style120 STRING,
            year_to_date TINYINT,
            prior_year_to_date TINYINT,
            prior_year TINYINT,
            prior_2_years TINYINT,
            trailing_12_months TINYINT,
            prior_month_ytd TINYINT,
            prior_month_pytd TINYINT,
            prior_month_ttm TINYINT,
            inforce_date_ytd TINYINT,
            inforce_date_pytd TINYINT,
            prior_month_py_ttm TINYINT,
            current_quarter TINYINT,
            prior_year_quarter TINYINT,
            prior_trailing_4_quarter TINYINT,
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
        ) USING DELTA COMMENT 'Dimension table for dates, containing various date-related attributes for analytics';
        """
        spark.sql(dim_date_ddl)
        logger.info(f"Table {schema_name}.dim_date created successfully")
    # Truncate dim_date to ensure idempotency
        spark.sql(f"TRUNCATE TABLE {schema_name}.dim_date")
        logger.info(f"Table {schema_name}.dim_date truncated")
    # Insert default rows into dim_date
        default_rows_query = f"""
        INSERT INTO dim_date
        SELECT
            -1 AS date_key,
            NULL AS `date`,
            -1 AS `day`,
            'unknown' AS day_suffix,
            'unknown' AS day_name,
            -1 AS day_of_week,
            -1 AS day_of_week_in_month,
            -1 AS day_of_year,
            -1 AS is_weekend,
            -1 AS `week`,
            -1 AS iso_week,
            NULL AS first_of_week,
            NULL AS last_of_week,
            -1 AS week_of_month,
            -1 AS `month`,
            'unknown' AS month_name,
            NULL AS first_of_month,
            NULL AS last_of_month,
            NULL AS first_of_next_month,
            NULL AS last_of_next_month,
            -1 AS `quarter`,
            'unknown' AS year_quarter,
            NULL AS first_of_quarter,
            NULL AS last_of_quarter,
            -1 AS `year`,
            -1 AS iso_year,
            NULL AS first_of_year,
            NULL AS last_of_year,
            -1 AS is_leap_year,
            -1 AS has_53_weeks,
            -1 AS has_53_iso_weeks,
            'unknown' AS mmyyyy,
            'unknown' AS style101,
            'unknown' AS style103,
            'unknown' AS style112,
            'unknown' AS style120,
            -1 AS year_to_date,
            -1 AS prior_year_to_date,
            -1 AS prior_year,
            -1 AS prior_2_years,
            -1 AS trailing_12_months,
            -1 AS prior_month_ytd,
            -1 AS prior_month_pytd,
            -1 AS prior_month_ttm,
            -1 AS inforce_date_ytd,
            -1 AS inforce_date_pytd,
            -1 AS prior_month_py_ttm,
            -1 AS current_quarter,
            -1 AS prior_year_quarter,
            -1 AS prior_trailing_4_quarter,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        UNION ALL
        SELECT
            -2 AS date_key,
            NULL AS `date`,
            -2 AS `day`,
            'not applicable' AS day_suffix,
            'not applicable' AS day_name,
            -2 AS day_of_week,
            -2 AS day_of_week_in_month,
            -2 AS day_of_year,
            -2 AS is_weekend,
            -2 AS `week`,
            -2 AS iso_week,
            NULL AS first_of_week,
            NULL AS last_of_week,
            -2 AS week_of_month,
            -2 AS `month`,
            'not applicable' AS month_name,
            NULL AS first_of_month,
            NULL AS last_of_month,
            NULL AS first_of_next_month,
            NULL AS last_of_next_month,
            -2 AS `quarter`,
            'not applicable' AS year_quarter,
            NULL AS first_of_quarter,
            NULL AS last_of_quarter,
            -2 AS `year`,
            -2 AS iso_year,
            NULL AS first_of_year,
            NULL AS last_of_year,
            -2 AS is_leap_year,
            -2 AS has_53_weeks,
            -2 AS has_53_iso_weeks,
            'not applicable' AS mmyyyy,
            'not applicable' AS style101,
            'not applicable' AS style103,
            'not applicable' AS style112,
            'not applicable' AS style120,
            -2 AS year_to_date,
            -2 AS prior_year_to_date,
            -2 AS prior_year,
            -2 AS prior_2_years,
            -2 AS trailing_12_months,
            -2 AS prior_month_ytd,
            -2 AS prior_month_pytd,
            -2 AS prior_month_ttm,
            -2 AS inforce_date_ytd,
            -2 AS inforce_date_pytd,
            -2 AS prior_month_py_ttm,
            -2 AS current_quarter,
            -2 AS prior_year_quarter,
            -2 AS prior_trailing_4_quarter,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        """
        spark.sql(default_rows_query)
        logger.info(f"Default rows inserted into {schema_name}.dim_date")

        # Seed the dim_date table with generated data
        seed_query = """
        WITH seq AS (
            SELECT sequence(to_date('1983-01-01'), to_date('2039-12-31'), INTERVAL 1 DAY) AS date_array
        ),
        d AS (
            SELECT explode(date_array) AS d
            FROM seq
        ),
        src AS (
            SELECT
                d AS TheDate,
                dayofmonth(d) AS TheDay,
                date_format(d, 'EEEE') AS TheDayName,
                weekofyear(d) AS TheWeek,
                weekofyear(d) AS TheISOWeek,
                dayofweek(d) AS TheDayOfWeek,
                month(d) AS TheMonth,
                date_format(d, 'MMMM') AS TheMonthName,
                quarter(d) AS TheQuarter,
                year(d) AS TheYear,
                make_date(year(d), month(d), 1) AS TheFirstOfMonth,
                make_date(year(d), 12, 31) AS TheLastOfYear,
                dayofyear(d) AS TheDayOfYear
            FROM d
        ),
        dim AS (
            SELECT
                TheDate,
                TheDay,
                CASE
                    WHEN TheDay / 10 = 1 THEN 'th'
                    ELSE CASE RIGHT(TheDay, 1)
                        WHEN '1' THEN 'st'
                        WHEN '2' THEN 'nd'
                        WHEN '3' THEN 'rd'
                        ELSE 'th'
                    END
                END AS TheDaySuffix,
                TheDayName,
                TheDayOfWeek,
                ROW_NUMBER() OVER (PARTITION BY TheFirstOfMonth, TheDayOfWeek ORDER BY TheDate) AS TheDayOfWeekInMonth,
                TheDayOfYear,
                CASE
                    WHEN TheDayOfWeek IN (1, 7) THEN 1
                    ELSE 0
                END AS IsWeekend,
                TheWeek,
                TheISOWeek,
                date_sub(TheDate, TheDayOfWeek - 1) AS TheFirstOfWeek,
                date_add(date_sub(TheDate, TheDayOfWeek - 1), 6) AS TheLastOfWeek,
                DENSE_RANK() OVER (PARTITION BY TheYear, TheMonth ORDER BY TheWeek) AS TheWeekOfMonth,
                TheMonth,
                TheMonthName,
                TheFirstOfMonth,
                last_day(TheDate) AS TheLastOfMonth,
                add_months(TheFirstOfMonth, 1) AS TheFirstOfNextMonth,
                last_day(add_months(TheFirstOfMonth, 1)) AS TheLastOfNextMonth,
                TheQuarter,
                concat(TheYear, '-Q', TheQuarter) AS TheYearQuarter,
                MIN(TheDate) OVER (PARTITION BY TheYear, TheQuarter) AS TheFirstOfQuarter,
                MAX(TheDate) OVER (PARTITION BY TheYear, TheQuarter) AS TheLastOfQuarter,
                TheYear,
                TheYear - CASE
                    WHEN TheMonth = 1 AND TheISOWeek > 51 THEN 1
                    WHEN TheMonth = 12 AND TheISOWeek = 1 THEN -1
                    ELSE 0
                END AS TheISOYear,
                make_date(TheYear, 1, 1) AS TheFirstOfYear,
                TheLastOfYear,
                CASE
                    WHEN (TheYear % 400 = 0) OR (TheYear % 4 = 0 AND TheYear % 100 != 0) THEN 1
                    ELSE 0
                END AS IsLeapYear,
                CASE
                    WHEN weekofyear(TheLastOfYear) = 53 THEN 1
                    ELSE 0
                END AS Has53Weeks,
                CASE
                    WHEN weekofyear(TheLastOfYear) = 53 THEN 1
                    ELSE 0
                END AS Has53ISOWeeks,
                concat(date_format(TheDate, 'MM'), TheYear) AS MMYYYY,
                date_format(TheDate, 'MM/dd/yyyy') AS Style101,
                date_format(TheDate, 'dd/MM/yyyy') AS Style103,
                date_format(TheDate, 'yyyyMMdd') AS Style112,
                date_format(TheDate, 'yyyy-MM-dd') AS Style120,
                CASE
                    WHEN year(current_date()) = TheYear AND TheDate < add_months(current_date(), -12) THEN 1
                    ELSE 0
                END AS YearToDate,
                CASE
                    WHEN year(add_months(current_date(), -12)) = TheYear AND TheDate < add_months(current_date(), -12) THEN 1
                    ELSE 0
                END AS PriorYearToDate,
                CASE
                    WHEN year(add_months(current_date(), -12)) = TheYear THEN 1
                    ELSE 0
                END AS PriorYear,
                CASE
                    WHEN year(add_months(current_date(), -24)) = TheYear THEN 1
                    ELSE 0
                END AS Prior2Years,
                CASE
                    WHEN TheDate > add_months(current_date(), -12) AND TheDate <= current_date() THEN 1
                    ELSE 0
                END AS Trailing12Months,
                CASE
                    WHEN year(last_day(add_months(current_date(), -1))) = TheYear AND TheDate <= last_day(add_months(current_date(), -1)) THEN 1
                    ELSE 0
                END AS PriorMonthYTD,
                CASE
                    WHEN year(last_day(add_months(current_date(), -13))) = TheYear AND TheDate <= last_day(add_months(current_date(), -13)) THEN 1
                    ELSE 0
                END AS PriorMonthPYTD,
                CASE
                    WHEN TheDate > last_day(add_months(current_date(), -13)) AND TheDate <= last_day(add_months(current_date(), -1)) THEN 1
                    ELSE 0
                END AS PriorMonthTTM,
                CASE
                    WHEN TheDate = date_sub(make_date(year(current_date()), month(current_date()), 1), 1) THEN 1
                    ELSE 0
                END AS InforceDateYTD,
                CASE
                    WHEN TheDate = date_sub(make_date(year(current_date()) - 1, month(current_date()), 1), 1) THEN 1
                    ELSE 0
                END AS InforceDatePYTD,
                CASE
                    WHEN TheDate > last_day(add_months(current_date(), -25)) AND TheDate <= last_day(add_months(current_date(), -13)) THEN 1
                    ELSE 0
                END AS PriorMonthPYTTM,
                CASE
                    WHEN quarter(current_date()) = TheQuarter AND year(current_date()) = TheYear THEN 1
                    ELSE 0
                END AS CurrentQuarter,
                CASE
                    WHEN TheDate >= add_months(date_trunc('QUARTER', current_date()), -12) AND TheDate < date_trunc('QUARTER', current_date()) THEN 1
                    ELSE 0
                END AS PriorYearQuarter,
                CASE
                    WHEN TheDate >= add_months(date_trunc('QUARTER', current_date()), -12) AND TheDate < date_trunc('QUARTER', current_date()) THEN 1
                    ELSE 0
                END AS PriorTrailing4Quarter
            FROM src
        )
        INSERT INTO dim_date
        SELECT
            cast(date_format(TheDate, 'yyyyMMdd') AS INT) AS date_key,
            TheDate AS `date`,
            TheDay AS `day`,
            TheDaySuffix AS day_suffix,
            TheDayName AS day_name,
            TheDayOfWeek AS day_of_week,
            TheDayOfWeekInMonth AS day_of_week_in_month,
            TheDayOfYear AS day_of_year,
            IsWeekend AS is_weekend,
            TheWeek AS `week`,
            TheISOWeek AS iso_week,
            TheFirstOfWeek AS first_of_week,
            TheLastOfWeek AS last_of_week,
            TheWeekOfMonth AS week_of_month,
            TheMonth AS `month`,
            TheMonthName AS month_name,
            TheFirstOfMonth AS first_of_month,
            TheLastOfMonth AS last_of_month,
            TheFirstOfNextMonth AS first_of_next_month,
            TheLastOfNextMonth AS last_of_next_month,
            TheQuarter AS `quarter`,
            TheYearQuarter AS year_quarter,
            TheFirstOfQuarter AS first_of_quarter,
            TheLastOfQuarter AS last_of_quarter,
            TheYear AS `year`,
            TheISOYear AS iso_year,
            TheFirstOfYear AS first_of_year,
            TheLastOfYear AS last_of_year,
            IsLeapYear AS is_leap_year,
            Has53Weeks AS has_53_weeks,
            Has53ISOWeeks AS has_53_iso_weeks,
            MMYYYY AS mmyyyy,
            Style101 AS style101,
            Style103 AS style103,
            Style112 AS style112,
            Style120 AS style120,
            YearToDate AS year_to_date,
            PriorYearToDate AS prior_year_to_date,
            PriorYear AS prior_year,
            Prior2Years AS prior_2_years,
            Trailing12Months AS trailing_12_months,
            PriorMonthYTD AS prior_month_ytd,
            PriorMonthPYTD AS prior_month_pytd,
            PriorMonthTTM AS prior_month_ttm,
            InforceDateYTD AS inforce_date_ytd,
            InforceDatePYTD AS inforce_date_pytd,
            PriorMonthPYTTM AS prior_month_py_ttm,
            CurrentQuarter AS current_quarter,
            PriorYearQuarter AS prior_year_quarter,
            PriorTrailing4Quarter AS prior_trailing_4_quarter,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag

        FROM dim
        ORDER BY TheDate
        """
        spark.sql(seed_query)
        logger.info(f"Table {schema_name}.dim_date seeded successfully")
    except Exception as e:
        logger.error(f"Error creating or seeding {schema_name}.dim_date: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_and_seed_dim_policy_status(schema_name: str):
    """Create, truncate, and seed seed dim_policy_statu table with defult and main data, and update parent keys."""
    try:
        logger.info(f"Creating and seeding {schema_name}.dim_policy_status table")
        # Define the dim_policy_status table DDL
        dim_policy_status_ddl = f"""
        CREATE TABLE IF NOT EXISTS dim_policy_status (
            policy_status_key INT,
            policy_status_level STRING,
            policy_status_cd_bus_key STRING,
            policy_status_desc STRING,
            policy_status_parent_cd_bus_key STRING,
            policy_status_parent_key INT,
            l0_level STRING,
            l1_level STRING,
            l2_level STRING,
            l3_level STRING,
            l4_level STRING,
            l5_level STRING,
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
        ) USING DELTA COMMENT "list of policy statuses, it includes policy life cycle messages";
        """
        spark.sql(dim_policy_status_ddl)
        logger.info(f"Table {schema_name}.dim_policy_status created successfully")

        # Truncate dim_date to ensure idempotency
        spark.sql(f"TRUNCATE TABLE {schema_name}.dim_policy_status")
        logger.info(f"Table {schema_name}.dim_policy_status truncated")

        # Insert default rows into dim_policy_status
        default_policy_status_query = f"""
        INSERT INTO dim_policy_status
        SELECT
            -1 AS policy_status_key,
            'unknown' AS policy_status_level,
            'unknown' AS policy_status_cd_bus_key,
            'unknown' AS policy_status_desc,
            'unknown' AS policy_status_parent_cd_bus_key,
            -1 AS policy_status_parent_key,
            'unknown' AS l0_level,
            'unknown' AS l1_level,
            'unknown' AS l2_level,
            'unknown' AS l3_level,
            'unknown' AS l4_level,
            'unknown' AS l5_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        UNION ALL
        SELECT
            -2 AS policy_status_key,
            'not applicable' AS policy_status_level,
            'not applicable' AS policy_status_cd_bus_key,
            'not applicable' AS policy_status_desc,
            'not applicable' AS policy_status_parent_cd_bus_key,
            -2 AS policy_status_parent_key,
            'not applicable' AS l0_level,
            'not applicable' AS l1_level,
            'not applicable' AS l2_level,
            'not applicable' AS l3_level,
            'not applicable' AS l4_level,
            'not applicable' AS l5_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        """
        spark.sql(default_policy_status_query)
        logger.info(f"Default rows inserted into {schema_name}.dim_policy_status")

        # Seed the dim_policy_status table using UNION ALL
        seed_policy_status_query = f"""
        INSERT INTO dim_policy_status (
            policy_status_key,
            policy_status_level,
            policy_status_cd_bus_key,
            policy_status_desc,
            policy_status_parent_cd_bus_key,
            l0_level,
            l1_level,
            l2_level,
            l3_level,
            l4_level,
            l5_level,
            dl_eltid,
            dl_runid,
            dl_row_insert_agent,
            dl_row_hash,
            dl_is_current_flag,
            dl_row_expiration_date,
            dl_row_effective_date,
            dl_row_update_timestamp,
            dl_row_insert_timestamp,
            dl_is_deleted_flag
        )
        SELECT
            row_number() OVER (ORDER BY policy_status_level) AS policy_status_key,
            policy_status_level,
            policy_status_cd_bus_key,
            policy_status_desc,
            policy_status_parent_cd_bus_key,
            l0_level,
            l1_level,
            l2_level,
            l3_level,
            l4_level,
            l5_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        FROM (
            SELECT 'LN0' AS policy_status_level, 'NB - New Submission' AS policy_status_cd_bus_key, 'NB - New Submission' AS policy_status_desc, NULL AS policy_status_parent_cd_bus_key, 'NB - New Submission' AS l0_level, NULL AS l1_level, NULL AS l2_level, NULL AS l3_level, NULL AS l4_level, NULL AS l5_level
            UNION ALL SELECT 'LR0', 'RN - Renewal', 'RN - Renewal', NULL, 'RN - Renewal', NULL, NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LW0', 'Canceled For Rewrite', 'Canceled For Rewrite', NULL, 'Canceled For Rewrite', NULL, NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LX0', 'Canceled For Reissue', 'Canceled For Reissue', NULL, 'Canceled For Reissue', NULL, NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LZ0', 'Other - Exception', 'Other - Exception', NULL, 'Other - Exception', NULL, NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LN1', 'NB - Completed Submission', 'NB - Completed Submission', 'NB - New Submission', 'NB - New Submission', 'NB - Completed Submission', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LN1_1', 'NB - Quoted', 'NB - Quoted', 'NB - Completed Submission', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', NULL, NULL, NULL
            UNION ALL SELECT 'LN1_1_1', 'NB - Open Quote', 'NB - Open Quote', 'NB - Quoted', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Open Quote', NULL, NULL
            UNION ALL SELECT 'LN1_1_2', 'NB - Total Written', 'NB - Total Written', 'NB - Quoted', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', NULL, NULL
            UNION ALL SELECT 'LN1_1_2_1', 'NB - Issued', 'NB - Issued', 'NB - Total Written', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', 'NB - Issued', NULL
            UNION ALL SELECT 'LN1_1_2_2', 'NB - Cancel', 'NB - Cancel', 'NB - Total Written', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', 'NB - Cancel', NULL
            UNION ALL SELECT 'LN1_1_2_2_1', 'NB - Canceled Flat', 'NB - Canceled Flat', 'NB - Cancel', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', 'NB - Cancel', 'NB - Canceled Flat'
            UNION ALL SELECT 'LN1_1_2_2_2', 'NB - Canceled Short Rate', 'NB - Canceled Short Rate', 'NB - Cancel', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', 'NB - Cancel', 'NB - Canceled Short Rate'
            UNION ALL SELECT 'LN1_1_2_2_3', 'NB - Canceled Pro-rata', 'NB - Canceled Pro-rata', 'NB - Cancel', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Total Written', 'NB - Cancel', 'NB - Canceled Pro-rata'
            UNION ALL SELECT 'LN1_1_3', 'NB - Quote Not Taken', 'NB - Quote Not Taken', 'NB - Quoted', 'NB - New Submission', 'NB - Completed Submission', 'NB - Quoted', 'NB - Quote Not Taken', NULL, NULL
            UNION ALL SELECT 'LN1_2', 'NB - Open Completed Submission', 'NB - Open Completed Submission', 'NB - Completed Submission', 'NB - New Submission', 'NB - Completed Submission', 'NB - Open Completed Submission', NULL, NULL, NULL
            UNION ALL SELECT 'LN1_3', 'NB - Guard Declined', 'NB - Guard Declined', 'NB - Completed Submission', 'NB - New Submission', 'NB - Completed Submission', 'NB - Guard Declined', NULL, NULL, NULL
            UNION ALL SELECT 'LN1_3_1', 'NB - Decline - Class of Exposure', 'NB - Decline - Class of Exposure', 'NB - Guard Declined', 'NB - New Submission', 'NB - Completed Submission', 'NB - Guard Declined', 'NB - Decline - Class of Exposure', NULL, NULL
            UNION ALL SELECT 'LN1_3_2', 'NB - Decline - Broker of Record', 'NB - Decline - Broker of Record', 'NB - Guard Declined', 'NB - New Submission', 'NB - Completed Submission', 'NB - Guard Declined', 'NB - Decline - Broker of Record', NULL, NULL
            UNION ALL SELECT 'LN1_3_3', 'NB - Decline - Questions', 'NB - Decline - Questions', 'NB - Guard Declined', 'NB - New Submission', 'NB - Completed Submission', 'NB - Guard Declined', 'NB - Decline - Questions', NULL, NULL
            UNION ALL SELECT 'LN1_3_4', 'NB - Decline - UW', 'NB - Decline - UW', 'NB - Guard Declined', 'NB - New Submission', 'NB - Completed Submission', 'NB - Guard Declined', 'NB - Decline - UW', NULL, NULL
            UNION ALL SELECT 'LN1_4', 'NB - Agency Withdrawal', 'NB - Agency Withdrawal', 'NB - Completed Submission', 'NB - New Submission', 'NB - Completed Submission', 'NB - Agency Withdrawal', NULL, NULL, NULL
            UNION ALL SELECT 'LN1_4_1', 'NB - Agent Withdrew After Initial Prem Estimate', 'NB - Agent Withdrew After Initial Prem Estimate', 'NB - Agency Withdrawal', 'NB - New Submission', 'NB - Completed Submission', 'NB - Agency Withdrawal', 'NB - Agent Withdrew After Initial Prem Estimate', NULL, NULL
            UNION ALL SELECT 'LN1_4_2', 'NB - Not Responding to UW', 'NB - Not Responding to UW', 'NB - Agency Withdrawal', 'NB - New Submission', 'NB - Completed Submission', 'NB - Agency Withdrawal', 'NB - Not Responding to UW', NULL, NULL
            UNION ALL SELECT 'LN1_4_3', 'NB - Agent Withdraw Before Quote', 'NB - Agent Withdraw Before Quote', 'NB - Agency Withdrawal', 'NB - New Submission', 'NB - Completed Submission', 'NB - Agency Withdrawal', 'NB - Agent Withdraw Before Quote', NULL, NULL
            UNION ALL SELECT 'LN2', 'NB - Open Submission', 'NB - Open Submission', 'NB - New Submission', 'NB - New Submission', 'NB - Open Submission', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LN3', 'NB - Abandoned Before Prem Est', 'NB - Abandoned Before Prem Est', 'NB - New Submission', 'NB - New Submission', 'NB - Abandoned Before Prem Est', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LN4', 'NB - Other Exception', 'NB - Other Exception', 'NB - New Submission', 'NB - New Submission', 'NB - Other Exception', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LR1', 'RN - Quoted', 'RN - Quoted', 'RN - Renewal', 'RN - Renewal', 'RN - Quoted', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LR1_1', 'RN - Total Written', 'RN - Total Written', 'RN - Quoted', 'RN - Renewal', 'RN - Quoted', 'RN - Total Written', NULL, NULL, NULL
            UNION ALL SELECT 'LR1_1_1', 'RN - Issued', 'RN - Issued', 'RN - Total Written', 'RN - Renewal', 'RN - Quoted', 'RN - Total Written', 'RN - Issued', NULL, NULL        
            UNION ALL SELECT 'LR1_1_2', 'RN - Cancel', 'RN - Cancel', 'RN - Total Written', 'RN - Renewal', 'RN - Quoted', 'RN - Total Written', 'RN - Cancel', NULL, NULL
            UNION ALL SELECT 'LR1_1_2_1', 'RN - Canceled Short Rate', 'RN - Canceled Short Rate', 'RN - Cancel', 'RN - Renewal', 'RN - Quoted', 'RN - Total Written', 'RN - Cancel', 'RN - Canceled Short Rate', NULL
            UNION ALL SELECT 'LR1_1_2_2', 'RN - Canceled Pro-rata', 'RN - Canceled Pro-rata', 'RN - Cancel', 'RN - Renewal', 'RN - Quoted', 'RN - Total Written', 'RN - Cancel', 'RN - Canceled Pro-rata', NULL
            UNION ALL SELECT 'LR1_2', 'RN - Open Quote', 'RN - Open Quote', 'RN - Quoted', 'RN - Renewal', 'RN - Quoted', 'RN - Open Quote', NULL, NULL, NULL
            UNION ALL SELECT 'LR1_3', 'RN - Quote Not Taken', 'RN - Quote Not Taken', 'RN - Quoted', 'RN - Renewal', 'RN - Quoted', 'RN - Quote Not Taken', NULL, NULL, NULL
            UNION ALL SELECT 'LR2', 'RN - Open Renewal', 'RN - Open Renewal', 'RN - Renewal', 'RN - Renewal', 'RN - Open Renewal', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LR3', 'RN - Guard Declined', 'RN - Guard Declined', 'RN - Renewal', 'RN - Renewal', 'RN - Guard Declined', NULL, NULL, NULL, NULL
            UNION ALL SELECT 'LR4', 'RN - Other Exception', 'RN - Other Exception', 'RN - Renewal', 'RN - Renewal', 'RN - Other Exception', NULL, NULL, NULL, NULL
        ) AS data
        """
        spark.sql(seed_policy_status_query)
        logger.info(f"Table {schema_name}.dim_policy_status seeded successfully")

        # Update policy_status_parent_key
        update_parent_key_query = f"""
        MERGE INTO dim_policy_status AS a
        USING dim_policy_status AS b
        ON a.policy_status_parent_cd_bus_key = b.policy_status_cd_bus_key
        WHEN MATCHED AND a.policy_status_key > 0 THEN
            UPDATE SET a.policy_status_parent_key = b.policy_status_key
        """
        spark.sql(update_parent_key_query)
        logger.info(f"Updated policy_status_parent_key in {schema_name}.dim_policy_status")
    except Exception as e:
        logger.error(f"Error creating, seeding, or updating {schema_name}.dim_policy_status: {str(e)}")
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_and_seed_dim_digital_decision_status(schema_name: str):
    """Create, truncate, and seed seed dim_digital_decision_status table with defult and main data, and update parent keys."""
    try:
        logger.info(f"Creating and seeding {schema_name}.dim_digital_decision_status table")
        # Define the dim_digital_decision_status table DDL
        dim_digital_decision_status_ddl = f"""
        CREATE TABLE IF NOT EXISTS dim_digital_decision_status (            
              digital_decision_status_key INT
            , digital_decision_status_level STRING
            , digital_decision_status_cd_bus_key STRING
            , digital_decision_status_desc STRING
            , digital_decision_status_parent_cd_bus_key STRING
            , digital_decision_status_parent_key INT
            , dd_l0_level STRING
            , dd_l1_level STRING
            , dd_l2_level STRING
            , dl_eltid STRING
            , dl_runid STRING
            , dl_row_insert_agent STRING
            , dl_row_hash STRING
            , dl_is_current_flag BOOLEAN
            , dl_row_expiration_date DATE
            , dl_row_effective_date DATE
            , dl_row_update_timestamp TIMESTAMP
            , dl_row_insert_timestamp TIMESTAMP
            , dl_is_deleted_flag BOOLEAN
        ) USING DELTA COMMENT "list of dim_digital_decision_status";
        """
        spark.sql(dim_digital_decision_status_ddl)
        logger.info(f"Table {schema_name}.dim_digital_decision_status created successfully")

        # Truncate dim_digital_decision_status to ensure idempotency
        spark.sql(f"TRUNCATE TABLE {schema_name}.dim_digital_decision_status")
        logger.info(f"Table {schema_name}.dim_digital_decision_status truncated")

        # Insert default rows into dim_digital_decision_status
        default_dim_digital_decision_status_query = f"""
        INSERT INTO dim_digital_decision_status
        SELECT
            -1 AS digital_decision_status_key,
            'unknown' AS digital_decision_status_level,
            'unknown' AS digital_decision_status_cd_bus_key,
            'unknown' AS digital_decision_status_desc,
            'unknown' AS digital_decision_status_parent_cd_bus_key,
            -1 AS digital_decision_status_parent_key,
            'unknown' AS dd_l0_level,
            'unknown' AS dd_l1_level,
            'unknown' AS dd_l2_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        UNION ALL
        SELECT
            -2 AS digital_decision_status_key,
            'not applicable' AS digital_decision_status_level,
            'not applicable' AS digital_decision_status_cd_bus_key,
            'not applicable' AS digital_decision_status_desc,
            'not applicable' AS digital_decision_status_parent_cd_bus_key,
            -2 AS digital_decision_status_parent_key,
            'not applicable' AS dd_l0_level,
            'not applicable' AS dd_l1_level,
            'not applicable' AS dd_l2_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        """
        spark.sql(default_dim_digital_decision_status_query)
        logger.info(f"Default rows inserted into {schema_name}.dim_digital_decision_status")

        # Seed the dim_digital_decision_status table using UNION ALL
        seed_dim_digital_decision_status_query = f"""
        INSERT INTO dim_digital_decision_status (
            digital_decision_status_key,
            digital_decision_status_level,
            digital_decision_status_cd_bus_key,
            digital_decision_status_desc,
            digital_decision_status_parent_cd_bus_key,
            dd_l0_level,
            dd_l1_level,
            dd_l2_level,
            dl_eltid,
            dl_runid,
            dl_row_insert_agent,
            dl_row_hash,
            dl_is_current_flag,
            dl_row_expiration_date,
            dl_row_effective_date,
            dl_row_update_timestamp,
            dl_row_insert_timestamp,
            dl_is_deleted_flag
        )
        SELECT
            row_number() OVER (ORDER BY digital_decision_status_level) AS digital_decision_status_key,
            digital_decision_status_level,
            digital_decision_status_cd_bus_key,
            digital_decision_status_desc,
            digital_decision_status_parent_cd_bus_key,
            dd_l0_level,
            dd_l1_level,
            dd_l2_level,
            'data-seed' AS dl_eltid,
            'data-seed' AS dl_runid,
            'data-seed' AS dl_row_insert_agent,
            'data-seed' AS dl_row_hash,
            True AS dl_is_current_flag,
            current_date() AS dl_row_expiration_date,
            current_date() AS dl_row_effective_date,
            current_timestamp() AS dl_row_update_timestamp,
            current_timestamp() AS dl_row_insert_timestamp,
            False AS dl_is_deleted_flag
        FROM (
            SELECT 'LC0' AS digital_decision_status_level, 'Completed Digital Decisioned Journey' AS digital_decision_status_cd_bus_key, 'Completed Digital Decisioned Journey' AS digital_decision_status_desc, NULL AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, NULL AS dd_l1_level, NULL AS dd_l2_level
            UNION ALL
            SELECT 'LI0' AS digital_decision_status_level, 'Incomplete' AS digital_decision_status_cd_bus_key, 'Incomplete' AS digital_decision_status_desc, NULL AS digital_decision_status_parent_cd_bus_key, 'Incomplete' AS dd_l0_level, NULL AS dd_l1_level, NULL AS dd_l2_level
            UNION ALL
            SELECT 'LO0' AS digital_decision_status_level, 'Excluded From Digital Decisioning' AS digital_decision_status_cd_bus_key, 'Excluded From Digital Decisioning' AS digital_decision_status_desc, NULL AS digital_decision_status_parent_cd_bus_key, 'Excluded From Digital Decisioning' AS dd_l0_level, NULL AS dd_l1_level, NULL AS dd_l2_level
            UNION ALL
            SELECT 'LC1' AS digital_decision_status_level, 'System Can Make First Decision (Qualifies For Digital Decision)' AS digital_decision_status_cd_bus_key, 'System Can Make First Decision (Qualifies For Digital Decision)' AS digital_decision_status_desc, 'Completed Digital Decisioned Journey' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'System Can Make First Decision (Qualifies For Digital Decision)' AS dd_l1_level, NULL AS dd_l2_level
            UNION ALL
            SELECT 'LC1_1' AS digital_decision_status_level, 'Digitally Decisioned' AS digital_decision_status_cd_bus_key, 'Digitally Decisioned' AS digital_decision_status_desc, 'System Can Make First Decision (Qualifies For Digital Decision)' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'System Can Make First Decision (Qualifies For Digital Decision)'  AS dd_l1_level, 'Digitally Decisioned' AS dd_l2_level
            UNION ALL
            SELECT 'LC1_2' AS digital_decision_status_level, 'Mitigating Circumstances' AS digital_decision_status_cd_bus_key, 'Mitigating Circumstances' AS digital_decision_status_desc, 'System Can Make First Decision (Qualifies For Digital Decision)' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'System Can Make First Decision (Qualifies For Digital Decision)' AS dd_l1_level, 'Mitigating Circumstances' AS dd_l2_level
            UNION ALL
            SELECT 'LC2' AS digital_decision_status_level, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS digital_decision_status_cd_bus_key, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS digital_decision_status_desc, 'Completed Digital Decisioned Journey' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS dd_l1_level, NULL AS dd_l2_level
            UNION ALL
            SELECT 'LC2_1' AS digital_decision_status_level, 'Digitally Assisted' AS digital_decision_status_cd_bus_key, 'Digitally Assisted' AS digital_decision_status_desc, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS dd_l1_level, 'Digitally Assisted' AS dd_l2_level
            UNION ALL
            SELECT 'LC2_2' AS digital_decision_status_level, 'Manual / Supplemental' AS digital_decision_status_cd_bus_key, 'Manual / Supplemental' AS digital_decision_status_desc, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS digital_decision_status_parent_cd_bus_key, 'Completed Digital Decisioned Journey' AS dd_l0_level, 'UW Is Required For First Decision (Not Qualified For Digital Decision)' AS dd_l1_level, 'Manual / Supplemental' AS dd_l2_level

        ) AS data
        """
        spark.sql(seed_dim_digital_decision_status_query)
        logger.info(f"Table {schema_name}.dim_digital_decision_status seeded successfully")

        # Update policy_status_parent_key
        update_parent_key_query = f"""
        MERGE INTO dim_digital_decision_status AS a
        USING dim_digital_decision_status AS b
        ON a.digital_decision_status_parent_cd_bus_key = b.digital_decision_status_cd_bus_key
        WHEN MATCHED AND a.digital_decision_status_key > 0 THEN
            UPDATE SET a.digital_decision_status_parent_key =  b.digital_decision_status_key
        """
        spark.sql(update_parent_key_query)
        logger.info(f"Updated policy_status_parent_key in {schema_name}.dim_digital_decision_status")
    except Exception as e:
        logger.error(f"Error creating, seeding, or updating {schema_name}.dim_digital_decision_status: {str(e)}")
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

        # Create and seed dim_date
        create_and_seed_dim_date(SCHEMA_NAME)

        # Create and seed dim_policy_status
        create_and_seed_dim_policy_status(SCHEMA_NAME)

        # Create and seed dim_digital_decision_status
        create_and_seed_dim_digital_decision_status(SCHEMA_NAME)

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
