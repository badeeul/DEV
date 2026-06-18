# Fabric Data Pipeline Orchestrator Notebook

## Overview
The `den_nbk_pdi_001_cicd_run_init_pipeline` is a Microsoft Fabric notebook designed to orchestrate the execution of a data pipeline in Microsoft Fabric environment. It performs the following key tasks:
- Checks if a specified `.whl` package (e.g., `spark_engine-0.1.0-py3-none-any.whl`) is installed in the Spark environment, with retry logic.
- If the package is installed, it retrieves lakehouse information, constructs pipeline parameters, and triggers a data pipeline run.
- Monitors the pipeline run status and logs the outcome.
- Raises errors if the package is not found or if the pipeline fails.

The script is intended for use in environments like Microsoft Fabric notebooks or Spark sessions where `notebookutils` and `FabricInterface` are available.

## Prerequisites
- Microsoft Fabric environment with access to lakehouses and data pipelines.
- The `FabricInterface` class must be defined or imported (%run den_nbk_pde_001_common).
- Required lakehouses must exist:
  - `den_lhw_pdi_001_metadata`
  - `den_lhw_dpr_001_raw_files`
  - `den_lhw_pdi_001_observability`
- The target pipeline (e.g., `dfa_pln_dpr_001_policy_dp_scheduled`) must exist in the workspace.
- Authentication headers for Fabric API must be handled by `FabricInterface`.
- Installed libraries: `requests`, `pkg_resources`, etc. (most are standard or environment-provided).

## Usage
1. Run it in a Python environment (Fabric notebook).
2. Customize parameters in `main()` if needed (e.g., `whl_name`, `pipeline_name`).
3. Set `run_me=False` in `main()` to skip execution for testing.
4. The notebook will be **automatically run as part of the CI/CD process** if its name contains the string `_cicd_`.

## Functions
- `check_whl_published(whl_name, max_attempts, sleep_interval_seconds)`: Verifies if a `.whl` package is installed with retries.
- `get_pipeline_id_by_name(workspace_id, pipeline_name, headers)`: Fetches the pipeline ID by name using Fabric API.
- `get_lakehouse_info(lakehouse_name)`: Retrieves lakehouse details using `notebookutils`.
- `create_pipeline_run(pipeline_name, feed_name, product_name)`: Triggers a pipeline run and returns the run ID.
- `main(run_me, whl_name)`: Orchestrates the entire process.

## Logging
- Uses Python's `logging` module at INFO level.
- Logs key events, errors, and timings.

## Error Handling
- Retries for package checks.
- Raises `ValueError` if pipeline not found.
- Raises `RuntimeError` if package not installed or pipeline fails.
- Catches and logs general exceptions.

## Limitations
- Environment-specific (Microsoft Fabric).
- Assumes `FabricInterface` handles API interactions correctly.