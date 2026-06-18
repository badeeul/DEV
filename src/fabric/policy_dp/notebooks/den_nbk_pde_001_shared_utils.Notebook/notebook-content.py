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

import datetime
from delta.tables import DeltaTable
from spark_engine.common.lakehouse import LakehouseManager, SchemaManager
import pandas as pd
from pyspark.sql import DataFrame as SparkDataFrame
import json
import warnings
from spark_engine.common.email_util import * 
warnings.filterwarnings("ignore", category=DeprecationWarning)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_table_location_url(lakehouse_name:str, table_schema:str, table_name:str) -> str:

    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    tables_path = f"{lakehouse_manager.lakehouse_path}/Tables"
    
    return f"{tables_path}/{table_schema}/{table_name}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_file_location_url(lakehouse_name:str, file_relative_path:str) -> str:

    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    lakehouse_files_path = f"{lakehouse_manager.lakehouse_path}/Files"

    return f"{lakehouse_files_path}/{file_relative_path}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_csv_file_from_table(table_path: str, file_path: str, file_name: str, approx_size_per_row:int=1000, target_file_size_mb:int=200) -> str:

    base_file_name = file_name.replace(".csv","")
    output_path = file_path + "/" + base_file_name
    # if "csv" not in output_path:
    #     output_path = output_path + ".csv"
    
    # Perform the query using DataFrame API
    df = DeltaTable.forPath(spark, table_path).toDF()

    # Calculate estimated number of partitions (files)
    rows_per_partition = (target_file_size_mb * 1024 * 1024) // approx_size_per_row

    # Partition the DataFrame
    partition_count = df.count() // rows_per_partition
    partition_count = max(1,partition_count)
    df = df.repartition(partition_count)

    # Write CSV files with compression for efficient storage
    df.write.mode("overwrite").option("header", "true").csv(output_path)

    i = 0
    for file in notebookutils.fs.ls(output_path):
        org_file = file.name
        org_file_full_path = output_path + "/" + org_file

        if ".csv" in org_file:
            new_file = base_file_name + "_" + str(i).rjust(3, '0') + ".csv"
            destination_path = output_path + "/" + new_file
            notebookutils.fs.mv(org_file_full_path, destination_path, overwrite=True)
            i += 1
        else:
            notebookutils.fs.rm(output_path + "/" + org_file)

    return output_path

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_csv_file_from_table_pandas(table_path: str, file_path: str, file_name: str) -> str:

    output_path = file_path + "/" + file_name
    if "csv" not in output_path:
        output_path = output_path + ".csv"
    
    # Perform the query using DataFrame API
    output_table_df = DeltaTable.forPath(spark, table_path).toDF()

    # Use Pandas to make a single file with specific name    
    output_table_df.toPandas().to_csv(output_path, index=False)
    
    return output_path

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_csv_file_from_dataframe(_df:SparkDataFrame, file_path: str, file_name: str) -> str:

    output_path = file_path + "/" + file_name + ".csv"
    
    # Use Pandas to make a single file with specific name    
    _df.toPandas().to_csv(output_path, index=False)
    
    return output_path

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_workspace_info(lakehouse_name):
    # Get the current workspace
    WorkspaceID = notebookutils.runtime.context["currentWorkspaceId"]
    # Get the name of the default lakehouse
    DefaultLakehouseName = notebookutils.runtime.context["defaultLakehouseName"]
    # Get the id of the same lakehouse in the new workspace
    LakehouseID = notebookutils.lakehouse.get(lakehouse_name, WorkspaceID)["id"]
    return {"WorkspaceID": WorkspaceID, "DefaultLakehouseName": DefaultLakehouseName, "LakehouseID": LakehouseID}

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_lakehouse_abfs_path(lakehouse_name:str, verbose:bool=False):
    if verbose:
        print("Looking up abfsPath for:", lakehouse_name)
    for item in mssparkutils.lakehouse.list():
        if item["type"] == "Lakehouse":
            if verbose:
                print("Found Lakehouse:", item["displayName"], item["properties"]["abfsPath"])
            if item["displayName"] == lakehouse_name:
                return item["properties"]["abfsPath"]

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_template_location_url(lakehouse_name="den_lhw_pdi_001_metadata",notification_type="emails",file_name="") -> str:
    """
    Constructs the full file path URL for template files stored in a lakehouse.
    
    This function builds a standardized path to template files by combining the lakehouse
    base path with a predefined folder structure for organizing different types of templates.
    
    Parameters:
    -----------
    lakehouse_name : str, optional
        The name of the lakehouse where templates are stored.
        Default: "den_lhw_pdi_001_metadata"
        
    notification_type : str, optional  
        The type/category of template (e.g., "emails", "sql", "reports").
        This creates a subfolder under /Files/templates/ for organization.
        Default: "emails"
        
    file_name : str, optional
        The specific template file name to retrieve.
        Default: "" (empty string)
    
    Returns:
    --------
    str
        Complete file path URL in the format:
        "{lakehouse_path}/Files/templates/{notification_type}/{file_name}"
    
    Example Usage:
    --------------
    # Get email template location
    email_template_url = get_template_location_url(
        lakehouse_name="den_lhw_pdi_001_metadata",
        notification_type="emails", 
        file_name="dq_failure_msg.json"
    )

    # Get SQL template location  
    sql_template_url = get_template_location_url(
        notification_type="sqls",
        file_name="dq_rule_failures.sql"
    )
    
    Path Structure:
    ---------------
    The function assumes templates are organized as:
    {lakehouse_path}/Files/templates/
    â”œâ”€â”€ emails/
    â”‚   â””â”€â”€ dq_failure_msg.json
    â”œâ”€â”€ sqls/
    â”‚   â””â”€â”€ dq_rule_failures.sql
    â””â”€â”€ reports/
        â””â”€â”€ other_templates...
    
    Dependencies:
    -------------
    - Requires LakehouseManager class to be imported and available
    - LakehouseManager must have lakehouse_path property
    """
    
    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    template_path = f"{lakehouse_manager.lakehouse_path}/Files/templates/{notification_type}"
    return f"{template_path}/{file_name}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_json_file(file_location):
    """
    Reads a JSON file from a distributed file system using Spark and returns it as a Python dictionary.
    
    This function uses Spark to read JSON files from distributed storage systems like lakehouse. It reads the entire file content as text and then parses it as JSON.
    
    Parameters:
    -----------
    file_location : str
        The full path to the JSON file to be read.
        Can be a local path or distributed storage path 
    
    Returns:
    --------
    dict
        The parsed JSON content as a Python dictionary
    
    Example Usage:
    --------------
    # Read email template
    template_path = "/lakehouse/Files/templates/emails/dq_rule_failure_msg.json"    
    """
    jsonDf = spark.read.text(file_location, wholetext=True)
    content = jsonDf.first()["value"]
    return json.loads(content)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def replace_tokens_in_json_object(json_object: dict, param_dict: dict):
    """
    Replaces placeholder tokens in a JSON object with actual values from a parameter dictionary.
    
    This function performs string-based token replacement by converting the entire JSON object
    to a string, replacing all occurrences of {token_name} with corresponding values, and then
    converting back to a JSON object. This is commonly used for email templating and configuration
    file parameterization.
    
    Returns:
    --------
    dict
        A new JSON object with all tokens replaced by their corresponding values
    
    Example Usage:
    --------------
    # Load email template
    email_template = {
        "subject": "ðŸš¨ Data Quality Rule Failures Detected - {workspace_name}",
        "body": {
            "content": "<p>Workspace: {workspace_name}</p><p>Run Date: {run_date}</p>"
        },
        "emailRecipient": "larry.edlin@guard.com;venkata.gari@guard.com"
    }
    
    # Define replacement parameters
    params = {
        "workspace_name": "Claims Processing",
        "run_date": "2025-11-10"
    }
    
    # Replace tokens
    final_email = replace_tokens_in_json_object(email_template, params)
    
    # Result:
    # {
    #     "subject": "ðŸš¨ Data Quality Rule Failures Detected - Claims Processing",
    #     "body": {
    #         "content": "<p>Workspace: Claims Processing</p><p>Run Date: 2025-11-10</p>"
    #     },
    #     "emailRecipient": "larry.edlin@guard.com;venkata.gari@guard.com"
    # }
    """
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

def calculate_widths(pandas_df, sample_rows=3):
    widths = {}
    base_font_size = 12  # Increased for 28px font size
    min_width = 80       # Minimum column width
    max_width = 150      # Reduced maximum width to fit more columns
    
    for column in pandas_df.columns:
        # Get header length
        header_length = len(str(column))
        
        # Get max content length from first few rows (sample_rows)
        sample_data = pandas_df[column].head(sample_rows)
        max_content_length = sample_data.astype(str).apply(len).max() if not sample_data.empty else 0
        
        # Use the maximum of header length and sample data length
        if max_content_length > header_length:
            max_length = max_content_length
        else:
            max_length = header_length
        
        # Calculate width based on content length
        calculated_width = max_length * base_font_size
        
        # Apply min/max limits
        if calculated_width < min_width:
            final_width = min_width
        elif calculated_width > max_width:
            final_width = max_width
        else:
            final_width = calculated_width
        
        widths[column] = final_width
    
    return widths

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def create_simple_html_table(df, template_body):
    try:
        # Convert DataFrame to pandas if it's a Spark DataFrame
        if hasattr(df, 'toPandas'):
            pandas_df = df.toPandas()
        else:
            pandas_df = df
        
        # Calculate dynamic widths based on first 3 rows
        column_widths = calculate_widths(pandas_df, sample_rows=3)
        
        # Generate HTML table with proper structure
        html_table = pandas_df.to_html(
            index=False, 
            escape=False,
            classes='data-table',
            table_id='dq-failures',
            border=0
        )
        
        # Generate dynamic CSS for all columns based on calculated widths
        dynamic_css = ""
        for i, column in enumerate(pandas_df.columns, 1):
            width = column_widths[column]
            dynamic_css += (
                ".data-table th:nth-child(" + str(i) + "), " +
                ".data-table td:nth-child(" + str(i) + ") {\n" +
                "    width: " + str(width) + "px;\n" +
                "    min-width: " + str(width) + "px;\n" +
                "    max-width: " + str(width) + "px;\n" +
                "}\n"
            )
        
        # Create complete HTML with dynamic CSS
        html_content = (
            "<!DOCTYPE html>\n"
            "<html>\n"
            "<head>\n"
            "    <meta charset=\"UTF-8\">\n"
            "    <style>\n"
            "        body {\n"
            "            font-family: Calibri, sans-serif;\n"
            "            margin: 10px;\n"
            "            font-size: 14px;\n"
            "        }\n"
            "        .data-table {\n"
            "            border-collapse: collapse;\n"
            "            width: auto;\n"
            "            margin: 10px 0;\n"
            "            table-layout: fixed;\n"
            "            border: 2px solid #000;\n"
            "            font-size: 28px !important;\n"
            "            font-family: Calibri, sans-serif;\n"
            "        }\n"
            "        .data-table th, .data-table td {\n"
            "            border: 1px solid #000;\n"
            "            padding: 8px 5px;\n"
            "            text-align: left;\n"
            "            word-wrap: break-word;\n"
            "            overflow: hidden;\n"
            "            text-overflow: ellipsis;\n"
            "            vertical-align: top;\n"
            "            font-size: 28px !important;\n"
            "            line-height: 1.2;\n"
            "            font-family: Calibri, sans-serif;\n"
            "        }\n"
            "        .data-table th {\n"
            "            background-color: #f2f2f2;\n"
            "            font-weight: bold;\n"
            "            font-size: 28px !important;\n"
            "            font-family: Calibri, sans-serif;\n"
            "        }\n"
            "        .data-table tr:nth-child(even) {\n"
            "            background-color: #f9f9f9;\n"
            "        }\n" +
            dynamic_css +
            "        .table-container {\n"
            "            overflow-x: auto;\n"
            "            max-width: 100%;\n"
            "        }\n"
            "        h3 {\n"
            "            font-size: 28px;\n"
            "            margin: 10px 0;\n"
            "        }\n"
            "    </style>\n"
            "</head>\n"
            "<body>\n" +
            template_body +
            "    <br>\n"
            "    <h3>Data Quality Rule Failures:</h3>\n"
            "    <div class=\"table-container\">\n" +
            html_table +
            "    </div>\n"
            "</body>\n"
            "</html>\n"
        )
        return html_content
        
    except Exception as e:
        return (
            "<html>\n"
            "<body>\n"
            "    <h3>Error generating table: " + str(e) + "</h3>\n"
            "    <p>Please check your DataFrame structure and try again.</p>\n"
            "</body>\n"
            "</html>\n"
        )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_workspace_name():
    return notebookutils.runtime.context.get("currentWorkspaceName")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_sql_template(file_location):
    """Read SQL template file and return as string"""
    sql_df = spark.read.text(file_location, wholetext=True)
    sql_content = sql_df.first()["value"]
    return sql_content

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
