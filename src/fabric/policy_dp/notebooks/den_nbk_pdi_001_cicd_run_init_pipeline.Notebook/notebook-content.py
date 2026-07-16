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
# # 
# Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/DnA%20Pdt%20and%20Prc/_git/DnA%20Pdt%20and%20Prc%20-%20Comn%20Pdt%20Lyr?path=%2Fdocs%2Fpolicy_dp%2Ffabric%2Fcicd_run_init_pipeline.md&version=GBmain&_a=contents) for detailed instructions and information


# CELL ********************

import pkg_resources
import logging
import os
import time
from datetime import datetime
from typing import Dict
import requests
import notebookutils

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

%run den_nbk_pde_001_common

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def check_whl_published(whl_name: str = 'spark_engine-0.1.1-py3-none-any.whl', 
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

def get_pipeline_id_by_name(workspace_id: str, pipeline_name: str, headers: Dict[str, str]) -> str:
    """
    Retrieve the ID of a data pipeline by its name in the given workspace.
    
    Args:
        workspace_id (str): The ID of the workspace.
        pipeline_name (str): The name of the pipeline.
        headers (Dict[str, str]): HTTP headers for authentication.
    
    Returns:
        str: The ID of the pipeline.
    
    Raises:
        ValueError: If the pipeline is not found.
    """
    url = f"https://api.fabric.microsoft.com/v1/workspaces/{workspace_id}/items?type=DataPipeline"
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    items = response.json().get("value", [])
    for item in items:
        if item.get("displayName") == pipeline_name:
            return item.get("id")
    raise ValueError(f"Pipeline '{pipeline_name}' not found.")

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

def create_pipeline_run(pipeline_name: str = 'dfa_pln_dpr_001_orchestrator', 
                        feed_name: str = 'PRODUCT & PRICING', 
                        product_name: str = 'PRODUCT & PRICING') -> str:
    """
    Create and trigger a data pipeline run with specified parameters.
    
    Args:
        pipeline_name (str): The name of the pipeline.
        feed_name (str): The feed name parameter.
        product_name (str): The product name parameter.
    
    Returns:
        str: The run ID of the triggered pipeline.
    """
    # Define lakehouse names
    lh_metadata_name = "den_lhw_pdi_001_metadata"
    lh_raw_name = "den_lhw_dpr_001_raw_files"
    lh_observability_name = "den_lhw_pdi_001_observability"
    
    # Get workspace ID from metadata lakehouse
    workspace_id = get_lakehouse_info(lh_metadata_name)["workspaceId"]
    
    # Define pipeline parameters
    pipeline_parameters = {
        'feed_name': feed_name,
        'product_name': product_name,
        'lh_metadata_id': get_lakehouse_info(lh_metadata_name)["id"],
        'workspace_id': workspace_id,
        'lh_raw_id': get_lakehouse_info(lh_raw_name)["id"],
        'lh_observability_id': get_lakehouse_info(lh_observability_name)["id"],
        'skip_database_restore': False
    }
    
    # Instantiate the Fabric interface
    fabric = FabricInterface(workspace_id)
    
    # Get headers with authorization token
    headers = fabric._get_headers()
    
    # Get the pipeline's GUID
    try:
        pipeline_id = get_pipeline_id_by_name(
            workspace_id=workspace_id,
            pipeline_name=pipeline_name,
            headers=headers
        )
        logger.info(f"Pipeline ID for '{pipeline_name}': {pipeline_id}")
    except ValueError as e:
        logger.error(str(e))
        raise
    
    # Trigger the pipeline run
    run_response = fabric.create_run(pipeline_item_id=pipeline_id, pipeline_parameters=pipeline_parameters)
    
    # Output the run ID
    logger.info(f"Pipeline run started with ID: {run_response.run_id}")
    return run_response.run_id

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def main(run_me: bool = True, whl_name: str = 'spark_engine-0.1.1-py3-none-any.whl'):
    """
    Main function to orchestrate the script execution.
    
    Args:
        run_me (bool): Flag to determine if the pipeline should be run.
        whl_name (str): The .whl file to check for installation.
    """
    start_time = datetime.now()
    logger.info(f"Starting script execution at {start_time}")
    
    if not run_me:
        logger.info("run_me is False, skipping execution")
        return
    
    # Check if the .whl file is published
    logger.info(f'Checking if {whl_name} is published in the Spark environment...')
    if check_whl_published(whl_name):
        logger.info(f'{whl_name} is published. Proceeding with pipeline run.')
        
        # Create and run the pipeline
        pipeline_name = 'dfa_pln_dpr_001_orchestrator'
        feed_name = 'PRODUCT & PRICING'
        product_name = 'PRODUCT & PRICING'
        
        logger.info(f'Starting pipeline run for {pipeline_name} with feed: {feed_name}, product: {product_name}')
        run_id = create_pipeline_run(pipeline_name, feed_name, product_name)
    else:
        logger.error(f'Failed to verify {whl_name} is published. Aborting pipeline run.')
        raise RuntimeError(f'{whl_name} is not published in the Spark environment.')
    
    end_time = datetime.now()
    logger.info(f"Script execution completed at {end_time}. Duration: {end_time - start_time}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    try:
        main(run_me=False)
    except Exception as e:
        logger.error(f'An error occurred during execution: {str(e)}')
        raise

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
