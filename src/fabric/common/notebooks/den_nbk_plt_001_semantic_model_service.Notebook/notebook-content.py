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

# # 🧱 Semantic Model Service — Automated Semantic Model Generation# 
#  # 
# This notebook generates and configures a Fabric Semantic Model using a 5-step pipeline:# 
#  # 
# 1. Generate Direct Lake model (optionally convert to Import mode)  # 
# 2. Create a "Metrics" measure table (calculated table)  # 
# 3. Hide technical/admin columns (_key, dl_, dq_, etc.)  # 
# 4. Apply business metadata from Excel mapping file  # 
# 5. (Future) Apply relationships, create shortcut tables for role-playing dimensions, rebind connections.


# MARKDOWN ********************

# # 🧭 Sub-Domain User Instructions (READ FIRST)
#  
# This notebook is designed so that **each sub-domain** can run it independently to build and enrich its own semantic models.
#  
# Follow the steps below.
#  
# ---
#  
# ## 1. Attach Your Metadata Lakehouse (Required)
# This notebook **does not require attaching the source lakehouse** where your data lives, as you will specify that in the **CONFIG** section.
#  
# But **you must attach the lakehouse that contains the Excel metadata mapping file**. In a future release, we will try to move away from the Excel file. For now, ensure your mapping file exists in the attached metadata lakehouse and update the **mapping_path** variable to point to your mapping file. This file is the one that stores the Business Table Names, Business Column/Field names and descriptions.
#  
# ### Steps:
# 1. Open the notebook  
# 2. In the left panel → **"Lakehouses" → "Add Lakehouse"**  
# 3. Choose your **metadata lakehouse**  
#    - Example: `den_lhw_pdi_001_metadata`
# 
#  
# ### 3. Usage
# Cells must be run **top to bottom**. Do NOT skip the `%pip install` cell. The install only needs to happen once per session. If your session ends, you'll need to run the install again. Alternatively, if you want to run a single step or cell block to ONLY perform a specific step, Ensure you run Steps 1 & 2 to install pre-requisites, then run the individual cells/steps you want to run.
# 
# For example, if you only need to rename fields/columns from the metadata file, you can run the first 2 cells to install the pre-requisites and set up variables, then run the cell/step you need. 
# 
# In some cases, automatic direct lake model generation can fail or not include all tables, as metadata can get out of sync with the API. If you encounter this, simply create the direct lake semantic model manually, then run cells after "Generate Direct Lake Semantic Model" to create the empty measure table, process renaming/hiding of columns.
#  
# ---
#  
# ### 4. Access Requirements
#  
# To run this notebook, you need:
#  
# ### **On Fabric Workspace**
# ✔ Build permission for the workspace  
# ✔ Permission to create semantic models  
# ✔ Permission to modify semantic models  
# ✔ Access to the source lakehouse (read only)  
# ✔ Access to the metadata lakehouse (read & write if updating mapping file)  
#  
#  
# - **Contributor** or **Admin** role on the workspace  
# - NOT Viewer  
# - NOT Member-only
#  
# ---
#  
# #


# MARKDOWN ********************

# #### Library Installation # 
# If you only need to run an individual step below (i.e. you already have a semantic model created, but just want to hide some fields in bulk, you must run the below cell first to install the required libraries, then proceed to the Step/Cell you wish to execute)


# CELL ********************

#Install semantic-link labs. Only needs to be installed once per active session. 
%pip install semantic-link-labs --quiet

#Required semantic link labs library.
import sempy_labs.directlake as dl
import sempy_labs.lakehouse as lakehouse
import sempy_labs.migration as migration
import sempy_labs as labs
from sempy_labs.tom import connect_semantic_model
import sempy.fabric as fabric
import pandas as pd
import re
import time

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ### CONFIG: UPDATE AS NEEDED


# CELL ********************

# ==============================
# CONFIGURATION (EDIT THESE)
# ==============================
 
workspace = None #None defaults to the current workspace. Cross workspace semantic model generation is not supported in this iteration.
lakehouse_name = "den_lhw_dpr_001_my_lakehouse" # Lakehouse containing the dim/fact tables you wish you include in your semantic model.
schema_name = "my_schema" # Schema within the Lakehouse data product containg the tables needed in the semantic model
dataset = "NEW_SEMANTIC_MODEL" # Desired name of the semantic model object
overwrite = False # Only set to True if you wish to overwrite a previous iteration of the semantic model with the same name
 
#Set the correct path to your Business Term Mapping file. Default lakehouse uses the attached lakehouse in the left hand side. The file must only contain 1 sheet with the correct column names.
mapping_path = "/lakehouse/default/Files/BusinessTerms.xlsx"

# None = Direct Lake by Default. Entering "Import" value below will convert Direct Lake → Import mode after creation
storage_mode = None
 
# If None → include all tables in schema (minus exclusions from excluded_patterns below)
# Or specify an specific list of tables you want if you only need a select few. Ex: ["dim_adjuster", "fact_claim"] 
selected_tables = None

#Tables containing these suffixes will be ignored during semantic model generation. You may adjust these as needed
exclude_patterns = ["_old", "_quarantine"]

#Specify the prefixes/suffixes of columns you wish to hide in the model, based on standard naming convetions. Optionally, add exceptions if needed. 
#These columns will still be part of the semantic model, but hidden from Report Designers in the UX for clarity. They may be unhidden at anytime.

hide_prefixes = ["dq_", "dl_"]
hide_suffixes = ["_key", "sort_order"]
exceptions = {"dl_row_effective_date", "dl_row_expiration_date", "dl_is_current_flag"} #These are SCD Type 2 columns, which may be  useful for reporting or data validation in some scenarios.

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# #### Generated Semantic Model Object


# CELL ********************

from notebookutils import mssparkutils
from pyspark.sql.types import *

 
# Physical location of files
scan_folder = schema_name
# Logical schema for the model
target_schema = schema_name
 

 
# 1. DISCOVERY (File System). Will include shorctus.
def get_clean_table_list(workspace, lakehouse_name, scan_folder):
    print("⚙️ Resolving IDs...")
    ws_id = fabric.resolve_workspace_id(workspace)
    lh_id = labs.resolve_lakehouse_id(lakehouse_name, workspace)
 
    # Base path for scanning
    base_path = f"abfss://{ws_id}@onelake.dfs.fabric.microsoft.com/{lh_id}/Tables/{scan_folder}"
    print(f"🔍 Scanning Base Path: {base_path}")
 
    try:
        files = mssparkutils.fs.ls(base_path)
        tables = [f.name for f in files if f.isDir and not f.name.startswith(("_", "."))]
        return tables, base_path
    except Exception as e:
        print(f"❌ Error scanning files: {e}")
        return [], None
 
# 2. HELPER: SPARK -> PBI TYPE MAPPER
def map_spark_type_to_tom(dtype):
    if isinstance(dtype, (IntegerType, LongType, ShortType, ByteType)):
        return "Int64"
    elif isinstance(dtype, (DoubleType, FloatType, DecimalType)):
        return "Double"
    elif isinstance(dtype, BooleanType):
        return "Boolean"
    elif isinstance(dtype, (DateType, TimestampType)):
        return "DateTime"
    else:
        return "String"
 
# 3. BUILDER (Explicit Tables + Columns)
def build_full_model_tom(dataset, workspace, lakehouse_name, table_list, base_path, target_schema):
 
    print(f"\n🚀 Starting Explicit Build for '{dataset}'...")
 
    # A. Filter Tables
    valid_tables = []
    for t in table_list:
        if exclude_patterns and any(p in t for p in exclude_patterns): continue
        if selected_tables and t not in selected_tables: continue
        valid_tables.append(t)
 
    if not valid_tables:
        print("⛔ No tables to process."); return
 
    
    # Use first table to initialize the model
    seed_table = valid_tables[0]
    print(f"1. Seeding model with: '{seed_table}'...")
 
    try:
        dl.generate_direct_lake_semantic_model(
            dataset=dataset,
            workspace=workspace,
            lakehouse=lakehouse_name,
            lakehouse_tables=[seed_table],
            schema=target_schema,
            overwrite=overwrite
        )
    except Exception as e:
        print(f"      ❌ CRITICAL: Shell creation failed. {e}"); return
 
 
    # C. Add Tables & Columns (TOM)
    print(f" 2. Adding {len(valid_tables)} tables with explicit columns...")
 
    with connect_semantic_model(dataset=dataset, workspace=workspace, readonly=False) as tom:
 
        for table_name in valid_tables:
            try:
                # 1. READ PHYSICAL SCHEMA (Trust OneLake, ignore SQL Endpoint)
                full_table_path = f"{base_path}/{table_name}"
                try:
                    df_schema = spark.read.format("delta").load(full_table_path).schema
                except Exception as spark_err:
                    print(f"      ⚠️ Spark could not read '{table_name}'. Skipping. ({spark_err})")
                    continue
 
                # 2. CREATE TABLE SHELL
                if not any(t.Name == table_name for t in tom.model.Tables):
                    tom.add_table(name=table_name)
 
                    # 3. BIND PARTITION
                    tom.add_entity_partition(
                        table_name=table_name,
                        entity_name=table_name,
                        schema_name=target_schema
                    )
 
                    # 4. ADD COLUMNS (Explicitly)
                    col_count = 0
                    for field in df_schema:
                        # Skip complex types
                        if isinstance(field.dataType, (ArrayType, MapType, StructType)):
                            continue
 
                        pbi_type = map_spark_type_to_tom(field.dataType)
 
                        tom.add_data_column(
                            table_name=table_name,
                            column_name=field.name,
                            source_column=field.name,
                            data_type=pbi_type
                        )
                        col_count += 1
 
                    print(f"      ✔ Added: {table_name} ({col_count} cols)")
                else:
                    # Note: You could add logic here to update columns for existing tables if needed
                    print(f"      ℹ Skipped: {table_name} (Exists)")
 
            except Exception as e:
                print(f"      ❌ FAILED: '{table_name}'")
                print(f"         Reason: {str(e)[:100]}...")
 
        print(f"   3. Saving & Refreshing.")
        tom.model.SaveChanges()
        labs.refresh_semantic_model(dataset=dataset, workspace=workspace)
 
    print(f"\n✅ Build and refresh complete.")
 
# --- EXECUTION ---
clean_tables, base_path = get_clean_table_list(workspace, lakehouse_name, scan_folder)
 
if clean_tables:
    build_full_model_tom(
        dataset=dataset,
        workspace=workspace,
        lakehouse_name=lakehouse_name,
        table_list=clean_tables,
        base_path=base_path,
        target_schema=target_schema
    )
else:
    print("⛔ No tables found.")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# #### Check Desired Storage Mode (Direct Lake by Default)


# CELL ********************

if storage_mode and storage_mode.lower() == "import":
    print(f"🔄 Converting Direct Lake → Import for '{dataset}'...")
    migration.migrate_direct_lake_to_import(
        dataset=dataset,
        workspace=workspace
    )
    print(f"✅ Model '{dataset}' migrated to Import mode. You must manually update the cloud connection and credentials in the semantic model settings after creation, then initiate a refresh to Import the data.")
else:
    print(f"ℹ StorageMode='{storage_mode}'. Direct Lake retained.")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# #### Create Empty Metrics Table in Semantic Model to store future Measures


# CELL ********************

# DAX expression for an empty one-column table
MEASURE_TABLE_NAME = "Metrics" #Update to desired name of table to store measures, note that "Measures" is a reserved word.
MEASURE_TABLE_EXPR = 'DATATABLE("_key", STRING, {{"Placeholder"}})' # Leave this as a palceholder, this will be hidden in subsequent code.
 
def table_exists(model, name: str) -> bool:
    """Return True if a table with the given name already exists (case-insensitive)."""
    return any(t.Name.lower() == name.lower() for t in model.Tables)
 
with connect_semantic_model(dataset=dataset, workspace=workspace, readonly=False) as tom:
    model = tom.model
 
    if table_exists(model, MEASURE_TABLE_NAME):
        print(f"'{MEASURE_TABLE_NAME}' table already exists — no action taken.")
    else:
        tom.add_calculated_table(
            name=MEASURE_TABLE_NAME,
            expression=MEASURE_TABLE_EXPR,
            description="Container table to organize measures (no data).",
            hidden=False  # set True if you want it hidden from report view
        )
        print(f"Created Metrics table in semantic model.")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# #### Hide Non-Essential Columns from Model (surrogate keys, data quality, sort-by and data engineering fields)


# CELL ********************

# Connect to the semantic model
with connect_semantic_model(dataset=dataset, workspace=workspace, readonly=False) as tom: #Set readonly=False only when ready to execute changes to model. 
    for table in tom.model.Tables:
        for col in table.Columns:
            name_lower = col.Name.lower()
 
            # Determine desired hide state
            # Exception first
            if name_lower in exceptions:
                continue
            
            hide = False
            
            # If prefix match or suffix match → hide, else visible
            if any(name_lower.startswith(p) for p in hide_prefixes) or any(name_lower.endswith(s) for s in hide_suffixes):
                hide = True
        
 
            if hide and not col.IsHidden:
                col.IsHidden = True
                print(f"HIDING: {table.Name}.{col.Name}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# #### Load Mapping File to Rename Tables, Columns with Business-Friendly names and Add Descriptions# 
# Note that mapping path variable is defined at the beginning of the notebook. Ensure the file path and name is correct and that the file only contains 1 sheet with the correct column names.


# CELL ********************

# Load mapping file
mapping_df = pd.read_excel(mapping_path)

       
# --- Pass 1: Rename columns and update descriptions ---
with connect_semantic_model(dataset=dataset, readonly=False, workspace=workspace) as tom:
    for idx, row in mapping_df.iterrows():
        table_name = row["Data Product Table Name"] # This column maps to the technical table name as it exists in the Data Product 
        original_col = row["Column"] # This is the technical column name within the table, as it exists in the data product (i.e. ins_obj)
        new_name = row["Business Term"] # This is the desired output / renaming of the field business friendly version. (i.e. Insurable Object)
        desc = row["Business Description"] # This adds a description to the column in the semantic model to provide more context about a particular fied
 
        # Find the table by its technical/original name
        table = next((t for t in tom.model.Tables if t.Name == table_name), None)
        if not table:
            print(f"[{idx}] Table not found: {table_name}")
            continue
 
        # Find column by original name
        col = next((c for c in table.Columns if c.Name == original_col), None)
        if not col:
            print(f"[{idx}] Column not found: {table_name}.{original_col}")
            continue
 
        try:
            # Rename column
            col.Name = new_name
 
            # Update column description
            tom.update_column(
                table_name=table_name,
                column_name=new_name,
                description=desc
            )
 
            print(f"[{idx}] Renamed '{original_col}' → '{new_name}' in table '{table_name}'.")
 
        except Exception as e:
            print(f"[{idx}] Error processing {table_name}.{original_col}: {e}")
 
    # --- Pass 2: Rename tables ---
    # Deduplicate table-level rename mappings
    table_mapping = (
        mapping_df[["Data Product Table Name", "Business Table Name"]] # This renames the Data Product Table Name to the Business Table Name (i.e. dim_cat --> Catastrophe)
        .dropna()
        .drop_duplicates()
    )
 
    for _, row in table_mapping.iterrows():
        old_name = row["Data Product Table Name"]
        new_name = row["Business Table Name"]
 
        if old_name == new_name:
            continue  # skip if no change needed
 
        table = next((t for t in tom.model.Tables if t.Name == old_name), None)
        if not table:
            print(f"Table not found for renaming: {old_name}")
            continue
 
        try:
            print(f"Renaming table '{old_name}' → '{new_name}'...")
            table.Name = new_name
        except Exception as e:
            print(f"Error renaming table {old_name}: {e}")
 

    print("✅ All column and table renames applied successfully.")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
