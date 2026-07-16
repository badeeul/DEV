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
# Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/DnA%20Pdt%20and%20Prc/_git/DnA%20Pdt%20and%20Prc%20-%20Comn%20Pdt%20Lyr?path=%2Fdocs%2Fpolicy_dp%2Ffabric%2Fprocess_alerting_events.md&version=GBmain&_a=contents) for detailed instructions and information


# CELL ********************

import json
import os
import logging
from typing import Dict, Optional
from spark_engine.common.email_util import send_email 
from spark_engine.common.lakehouse import LakehouseManager
from datetime import datetime

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

elt_id = "111"
template_name = "dp_pipeline_completed.json"
trigger_time = "2025-09-25T14:54:35.8116097Z"
pipeline_name = "test_notebook"
data_product = "POLICY"
database_names = "GIGINSDATA,PROSPECTHOLDINGARCHIVE"
workspace_id = "02c3d55e-485c-419b-b587-21a51aeb261e"
metadata_lakehouse_id = "6740d2cc-6489-41d9-af20-315d92df9c07"
pipeline_id = "562a842c-a809-4904-8623-8fa80e647a4b"
run_id = "84c194e6-944f-4e81-b560-ff40c0d1653c"
feed_name = "test"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

%run den_nbk_pdi_001_workspace_parameters

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Configure logging
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

def get_template_location_url(
    lakehouse_name: str = "den_lhw_pdi_001_metadata",
    notification_type: str = "emails",
    file_name: str = ""
) -> Optional[str]:
    """
    Get the URL for the template location in the lakehouse.
    
    Args:
        lakehouse_name: Name of the lakehouse
        notification_type: Type of notification (e.g., emails)
        file_name: Name of the template file
    
    Returns:
        String URL path or None if error occurs
    """
    try:
        lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
        template_path = f"{lakehouse_manager.lakehouse_path}/Files/templates/{notification_type}"
        return f"{template_path}/{file_name}"
    except Exception as e:
        logger.error(f"Failed to get template location URL: {str(e)}")
        return None

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def replace_tokens_in_json_object(json_object: Dict, param_dict: Dict) -> Optional[Dict]:
    """
    Replace tokens in JSON object with parameter values.
    
    Args:
        json_object: JSON object to process
        param_dict: Dictionary of token-value pairs
    
    Returns:
        Processed JSON dictionary or None if error occurs
    """
    try:
        value = json.dumps(json_object)
        for k, v in param_dict.items():
            # Ensure value is string and handle None values
            v = str(v) if v is not None else ""
            value = value.replace('{' + k + '}', v)
        return json.loads(value)
    except (json.JSONDecodeError, TypeError) as e:
        logger.error(f"Error replacing tokens in JSON: {str(e)}")
        return None

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_json_file(file_location: str) -> Optional[Dict]:
    """
    Read and parse JSON file from the specified location.
    
    Args:
        file_location: Path to the JSON file
    
    Returns:
        Parsed JSON dictionary or None if error occurs
    """
    try:    
        jsonDf = spark.read.text(file_location, wholetext=True)
        content = jsonDf.first()["value"]
        return json.loads(content)
    except (json.JSONDecodeError, Exception) as e:
        logger.error(f"Error reading JSON file {file_location}: {str(e)}")
        return None

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def process_alerts(
    elt_id: str,
    template_name: str,
    trigger_time: str,
    pipeline_name: str,
    data_product: str,
    database_names: str,
    workspace_id: str,
    pipeline_id: str,
    run_id: str,
    feed_name: str
) -> bool:
    """
    Main function to process alerts and send email notifications.
    
    Returns:
        True if email sent successfully, False otherwise
    """
    try:
        # Validate required parameters
        required_params = {
            'elt_id': elt_id,
            'template_name': template_name,
            'trigger_time': trigger_time,
            'pipeline_name': pipeline_name,
            'data_product': data_product,
            'database_names': database_names,
            'workspace_id': workspace_id,
            'pipeline_id': pipeline_id,
            'run_id': run_id,
            'feed_name': feed_name
        }
        
        for param, value in required_params.items():
            if not value:
                logger.error(f"Missing required parameter: {param}")
                raise ValueError(f"Missing required parameter: {param}")

        # Get workspace name and key vault
        try:
            workspace_name = notebookutils.runtime.context.get("currentWorkspaceName")
            key_vault_name = secretsScope
        except Exception as e:
            logger.error(f"Error getting workspace details: {str(e)}")
            raise ValueError("Failed to get workspace details")
        
        # Create replacement tokens dictionary
        replacement_tokens = {
            'elt_id': elt_id,
            'template_name': template_name,
            'trigger_time': trigger_time,
            'pipeline_name': pipeline_name,
            'data_product': data_product,
            'database_names': database_names,
            'workspace_id': workspace_id,
            'pipeline_id': pipeline_id,
            'run_id': run_id,
            'workspace_name': workspace_name,
            'feed_name': feed_name
        }

        # Get template location
        logger.info(f"Getting template location for: {template_name}")
        template_location = get_template_location_url(file_name=template_name)
        if not template_location:
            raise ValueError("Failed to get template location")
        logger.info(f"Template location: {template_location}")
        # Read and process template
        template_data = read_json_file(template_location)
        if not template_data:
            raise ValueError("Failed to read template file")

        # Replace tokens
        processed_template = replace_tokens_in_json_object(template_data, replacement_tokens)
        if not processed_template:
            raise ValueError("Failed to process template tokens")

        # Prepare email parameters
        input_params = {
            "subject": processed_template.get("subject", ""),
            "body": processed_template.get("body", {}).get("content", ""),
            "to_email": processed_template.get("emailRecipient", ""),
            "from_account": processed_template.get("emailSender", ""),
            "key_vault_name": secretsScope
        }

        # Validate email parameters
        for param in ["subject", "body", "to_email", "from_account"]:
            if not input_params[param]:
                logger.error(f"Missing email parameter: {param}")
                raise ValueError(f"Missing email parameter: {param}")

        # Send email
        logger.info("Sending mail ...")
        send_email(**input_params)
        return True

    except Exception as e:
        logger.error(f"Alert processing error: {str(e)}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error in alert processing: {str(e)}", exc_info=True)
        return False

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    # process alerts
    success = process_alerts(
        elt_id=elt_id,
        template_name=template_name,
        trigger_time=trigger_time,
        pipeline_name=pipeline_name,
        data_product=data_product,
        database_names=database_names,
        workspace_id=workspace_id,
        pipeline_id=pipeline_id,
        run_id=run_id,
        feed_name=feed_name
    )
if not success:
    logger.error("Alert processing failed")
    exit(1)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
