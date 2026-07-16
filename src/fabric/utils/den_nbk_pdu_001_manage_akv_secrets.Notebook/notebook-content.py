# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# ###### Notebook: Manages key vault secrets from lakehouse files
# ###### Purpose:  Scan OneLake key files (.pub, .asc) -> read file -> create new secret or new version of existing one
# ###### Author:   skolpakov
# ###### Updated:  March 2026
# ###### Please refer to the [README file](https://dev.azure.com/BHGDataAndAnalytics/GDAP-Fluidity-PlatformServices/_git/PlatformServices-Fabric?path=/docs/fabric/utils/manage_akv_secrets.md&version=GBmain&_a=contents) for information.

# CELL ********************

import logging
import fsspec
import posixpath
from datetime import datetime
import requests
import os

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

# Configuration

WORKSPACE_NAME = notebookutils.runtime.context.get("currentWorkspaceName")  # Fabric context

# AKV name, version and URL
key_vault_name = secretsScope # comes from workspace_parameters notebook
KEY_VAULT_URL = f"https://{key_vault_name}.vault.azure.net"
API_VERSION   = "2025-07-01"   # Latest stable version as of 2026

# Default scan path (can be overridden)
DEFAULT_KEY_ROOT = None  # will be built dynamically below -> key_files_root variable

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(levelname)-8s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_lakehouse_paths():
    """Retrieve workspace/lakehouse identifiers from Fabric context."""

    metadata_lh = notebookutils.lakehouse.get("den_lhw_pdi_001_metadata")
    
    workspace_id = metadata_lh["workspaceId"]
    metadata_id  = metadata_lh["id"]
    
    key_files_root = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{metadata_id}/Files/key_vault_secrets"
    
    return key_files_root, workspace_id

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def send_key_vault_secret(secret_name: str, secret_content: str, access_token: str):
    """ Creates new secret or new version of existing one """

    # Prepare REST API call
    uri = f"{KEY_VAULT_URL}/secrets/{secret_name}?api-version={API_VERSION}"

    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }

    body = {
        "value": secret_content,
        "attributes": {
            "enabled": True
        },
        "contentType": "text/plain",
        "tags": {
            "source": "Fabric Metadata Lakehouse",
            "type": "pgp-key",
            "updated_by": "notebook",
            "updated_at": str(datetime.now())
        }
    }

    # Send to Key Vault (creates new secret or new version of existing one)
    response = requests.put(uri, headers=headers, json=body)

    if response.status_code in (200, 201):
        result = response.json()
        secret_id = result.get('id')
        version = secret_id.split('/')[-1] if secret_id else "N/A"
        
        logger.info("SUCCESS! Public key has been stored in Key Vault.")
        logger.info(f"   Secret Name : {secret_name}")
        logger.info(f"   Secret ID   : {secret_id}")
        logger.info(f"   Version     : {version}")
        logger.info(f"   URI         : {secret_id}")
    else:
        logger.error(f"FAILED - HTTP {response.status_code}")
        logger.info(response.text)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def manage_secrets_from_key_files(root_dir: str):
    """
    Recursively scan ABFSS path for KEY files and and calls key vault API.
    """
    fs = fsspec.filesystem("abfss", account_name="onelake", account_host="onelake.dfs.fabric.microsoft.com")
    file_count = 0
    
    # Get Microsoft Entra token for Key Vault (uses this notebook identity)
    access_token = notebookutils.credentials.getToken("keyvault")

    logger.info(f"Starting recursive scan of: {root_dir}")
    
    for dirpath, _, filenames in fs.walk(root_dir, detail=False):
        dirpath = dirpath.rstrip('/')
        for filename in filenames:
            if not filename.lower().endswith(('.pub', '.asc')):
                continue
                
            file_count += 1
            full_path = posixpath.join(dirpath, filename)
            
            try:
                with fs.open(full_path, "r", encoding="utf-8") as f:
                    key_content = f.read().strip()  # remove any trailing whitespace/newlines if needed
                    
                logger.info(f"PGP key file {filename} read successfully ({len(key_content)} characters)")
                # use secret name as file name
                secret_name = os.path.splitext(filename)[0]

                # Create or update secret in the key vault
                logger.info(f"Sending to the Key Vault...")
                send_key_vault_secret(secret_name=secret_name, secret_content=key_content, access_token=access_token)
                
            except FileNotFoundError:
                logger.error(f"File not found: {full_path}")
                raise
            except Exception as e:
                logger.error(f"Failed to read {full_path}: {type(e).__name__} - {str(e)}")
    
    logger.info(f"Scan complete. Files read: {file_count}")


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def main():
    start_time = datetime.now()
    
    # ─── Get dynamic paths ───
    key_files_root, workspace_id = get_lakehouse_paths()
    logger.info(f"Workspace: {WORKSPACE_NAME} | KEY root: {key_files_root}")
    
    # ─── Scan ───
    manage_secrets_from_key_files(key_files_root)
    
    duration = datetime.now() - start_time
    duration_seconds = duration.total_seconds()
    logger.info(f"Job completed successfully in {duration_seconds:.1f} seconds.")


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

if __name__ == "__main__":
    main()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }