#  Initializing and Seeding Common Policy Data Product Tables Notebook

## Overview
The `den_nbk_pdi_001_cicd_init_and_seed_policy_dp` is a Microsoft Fabric notebook designed to create physical Data model and seed dimension tables (`dim_date` and `dim_policy_status`) in a lakehouse for analytics purposes. It is executed as part of a deployment process for notebooks with "cicd" in their name. The notebook:
- Processes DDL scripts from a Data Modeler-supplied input file to generate database tables.
- Creates and seeds the `dim_date` table with ~20,819 date records (1983-01-01 to 2039-12-31) plus two default rows.
- Creates and seeds the `dim_policy_status` table with 41 policy status records plus two default rows.
- Ensures idempotent seeding by truncating tables before inserting data.
- Includes a `run_me` parameter to control execution.
- Validates table creation and row counts.

## Prerequisites
- **Microsoft Fabric Environment**: The notebook must be attached to a lakehouse named `den_lhw_dpr_001_policy_product`.
- **Input File**: A DDL file (`Product and Pricing Physical Data Model DDL.txt`) must be available at `abfss://<WORKSPACE_ID>@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/policy_dp/ellie_ddl/{DDL_FILE_NAME}`. The file should contain `CREATE TABLE` statements for data model tables.
- **Spark Runtime**: Compatible with Fabric's Spark runtime (PySpark).
- **Permissions**: Write access to the `policy` schema in the lakehouse.

## Configuration
The notebook uses the following constants defined at the top of `den_nbk_pdi_001_cicd_init_and_seed_policy_dp`:
- **`LAKEHOUSE_PROPERTIES`**: Set to `"den_lhw_pdi_001_metadata"`. Update if your lakehouse has a different name.
- **`WORKSPACE_ID`**: Dynamicaly set based on `LAKEHOUSE_PROPERTIES`
- **`LAKEHOUSE_ID`**: Dynamicaly set based on `LAKEHOUSE_PROPERTIES`
- **`SCHEMA_NAME`**: Set to `"policy"`. Update to target a different schema.
- **`DDL_FILE_NAME`**: Set to `"Product and Pricing Physical Data Model DDL.txt"`. Update to target a different file name.
- **`FILE_PATH`**: Set to `"abfss://<WORKSPACE_ID>@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/policy_dp/ellie_ddl/{DDL_FILE_NAME}"`. Ensure the DDL file is at this location.
- **`EXPECTED_DIM_DATE_ROWS`**: Set to `20821` (20,819 main rows + 2 default rows).
- **`EXPECTED_DIM_POLICY_STATUS_ROWS`**: Set to `43` (41 main rows + 2 default rows).
- **`run_me`**: Boolean parameter (default `True`) in the `if __name__ == "__main__":` block. Set to `False` to skip execution once tables initialized.

To modify these, edit the constants in the notebook or pass a different `run_me` value during deployment.

## Execution
The notebook is triggered automatically during the deployment process for notebooks with "cicd" in their name. It performs the following steps:
1. **Check `run_me`**: If `run_me = False`, the notebook logs a message and exits without executing.
2. **Create Schema**: Creates the `policy` schema if it doesn’t exist and sets it as the current context.
3. **Seed `dim_date`**:
   - Creates the `dim_date` table with columns for date attributes (e.g., `datekey`, `date`, `day`, `month`, etc.).
   - Truncates the table for idempotency.
   - Inserts two default rows: 
     - `datekey = -1`, numeric columns = `-1`, string columns = `"unknown"`, date columns = `NULL`.
     - `datekey = -2`, numeric columns = `-2`, string columns = `"not applicable"`, date columns = `NULL`.
   - Seeds ~20,819 rows for dates from 1983-01-01 to 2039-12-31.
4. **Seed `dim_policy_status`**:
   - Creates the `dim_policy_status` table with columns for policy status attributes (e.g., `policy_status_key`, `policy_status_level`, etc.).
   - Truncates the table for idempotency.
   - Inserts two default rows:
     - `policy_status_key = -1`, numeric columns = `-1`, string columns = `"unknown"`, date columns = `NULL`.
     - `policy_status_key = -2`, numeric columns = `-2`, string columns = `"not applicable"`, date columns = `NULL`.
   - Seeds 41 rows for policy statuses (e.g., "Re-write", "NB - New Submission", etc.).
   - Updates `policy_status_parent_key` using a `MERGE INTO` operation, excluding default rows (`policy_status_key > 0`).    
5. **Read DDL File**: Reads `Product and Pricing Physical Data Model DDL.txt` to extract `CREATE TABLE` statements.
6. **Extract table names**: Extracts table names from DDL text of the input file.
7. **Execute DDL Statements**: Parses and executes DDL statements from the input file.
8. **Validate Tables**: Checks table existence and row counts, logging warnings if counts don’t match expectations.

## Idempotency
The notebook ensures idempotent seeding by:
- Truncating `dim_date` and `dim_policy_status` before inserting data, preventing duplicates from multiple runs.
- Using fixed keys (`-1`, `-2`) for default rows and dynamic keys (`row_number()`) for main data in `dim_policy_status`.
- Maintaining consistent row counts: 20,821 for `dim_date`, 43 for `dim_policy_status`.

## Validation
After execution, the notebook validates tables:
- **Expected Row Counts**:
  - `dim_date`: 20,821 rows (20,819 main + 2 default).
  - `dim_policy_status`: 43 rows (41 main + 2 default).
  - Other tables: 0 rows.
- **Debugging**:
  - Check default rows in `dim_date`:
    ```sql
    SELECT * FROM policy.dim_date WHERE datekey IN (-1, -2);
    ```
  - Check default rows in `dim_policy_status`:
    ```sql
    SELECT * FROM policy.dim_policy_status WHERE policy_status_key IN (-1, -2);
    ```
  - Verify `policy_status_parent_key`:
    ```sql
    SELECT policy_status_level, policy_status_cd_bus_key, policy_status_parent_cd_bus_key, policy_status_parent_key
    FROM policy.dim_policy_status WHERE policy_status_key > 0;
    ```
  - Verify uniqueness of `policy_status_cd_bus_key`:
    ```sql
    SELECT policy_status_cd_bus_key, count(*)
    FROM policy.dim_policy_status GROUP BY policy_status_cd_bus_key HAVING count(*) > 1;
    ```  
- **Logs**: Review logs for errors or warnings about row counts. Logs include timestamps and operation details.

## Notes
- **File Path**: Ensure `Product and Pricing Physical Data Model DDL.txt` exists at the specified `abfss` path. If the path changes, update `FILE_PATH`.
- **Run Control**: Set `run_me = False` for testing or to skip execution in a deployment pipeline. For example, edit the notebook:
  ```python
  run_me = False
  ```
- **Performance**: Truncating is efficient for these tables (~20,821 and 42 rows). For larger datasets, consider `MERGE INTO` for deduplication.
- **Deployment**: Ensure the notebook name contains "_cicd_" to trigger execution in the deployment process. Rename if necessary (e.g., keep `den_nbk_pdi_001_cicd_init_and_seed_policy_dp`).

## Example Usage
1. Ensure `Product and Pricing Physical Data Model DDL.txt` is uploaded to `abfss://<WORKSPACE_ID>@onelake.dfs.fabric.microsoft.com/{LAKEHOUSE_ID}/Files/data_product/policy_dp/ellie_ddl/{DDL_FILE_NAME}`.
2. Attach the notebook to the `den_lhw_dpr_001_policy_product` lakehouse in Fabric.
3. Run the notebook manually or via the deployment process:
   - If `run_me = True`, the notebook executes all steps.
   - If `run_me = False`, it logs a message and skips execution.
4. Verify row counts and data using the debugging queries above.

For issues or modifications, contact the data engineering team.