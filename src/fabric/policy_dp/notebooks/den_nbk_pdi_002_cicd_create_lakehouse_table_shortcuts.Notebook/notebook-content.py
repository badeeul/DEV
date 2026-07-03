# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   }
# META }

# CELL ********************

def get_workspace_info(lakehouse_name):
    # Get the current workspace
    WorkspaceID = notebookutils.runtime.context["currentWorkspaceId"]
    # Get the id of the same lakehouse in the new workspace
    LakehouseID = notebookutils.lakehouse.get(lakehouse_name, WorkspaceID)["id"]
    return {"WorkspaceID": WorkspaceID, "LakehouseID": LakehouseID}
    

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Target lakehouse where shortcuts will be created
target_lakehouse_name = 'den_lhw_dpr_001_cauto_product'

TARGET_WORKSPACE_ID = get_workspace_info(target_lakehouse_name)['WorkspaceID']
TARGET_ITEM_ID = get_workspace_info(target_lakehouse_name)['LakehouseID']

# Source lakehouse where actual tables exist
source_lakehouse_name = 'den_lhw_dpr_001_policy_product'
SOURCE_WORKSPACE_ID = get_workspace_info(source_lakehouse_name)['WorkspaceID']
SOURCE_ITEM_ID = get_workspace_info(source_lakehouse_name)['LakehouseID']

base_url = f"https://api.fabric.microsoft.com/v1/workspaces/{TARGET_WORKSPACE_ID}/items/{TARGET_ITEM_ID}/shortcuts"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# src/fabric/policy_dp/lakehouses/den_lhw_dpr_001_policy_product.Lakehouse/shortcuts.metadata.json

shortcuts = [
{
    "name": "Territory Manager",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_employee",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Producer Relations Advisor",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_employee",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Trans Written Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Trans Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Submission Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Issue Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Effective Start Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Effective End Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Decision Underwriter",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_employee",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Coverage Start Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Coverage End Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Cancel Date",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_date",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  },
  {
    "name": "Policy Underwriter",
    "path": "/Tables/policy",
    "target": {
      "type": "OneLake",
      "oneLake": {
        "path": "Tables/policy/dim_employee",
        "itemId": "00000000-0000-0000-0000-000000000000",
        "workspaceId": "00000000-0000-0000-0000-000000000000"
      }
    }
  }  
]

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

import requests

def get_fabric_token():
    from notebookutils import mssparkutils
    return mssparkutils.credentials.getToken("https://api.fabric.microsoft.com")

access_token = get_fabric_token()

headers = {
    "Authorization": f"Bearer {access_token}",
    "Content-Type": "application/json"
}

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_existing_shortcuts():
    url = base_url
    response = requests.get(url, headers=headers)
    
    if response.status_code == 200:
        data = response.json()
        return {s["name"]: s for s in data.get("value", [])}
    else:
        print("Failed to fetch existing shortcuts")
        return {}

existing_shortcuts = get_existing_shortcuts()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

created = []
skipped = []
failed = []

for shortcut in shortcuts:

    shortcut["target"]["oneLake"]["itemId"] = SOURCE_ITEM_ID
    shortcut["target"]["oneLake"]["workspaceId"] = SOURCE_WORKSPACE_ID

    name = shortcut["name"]
    if name in existing_shortcuts:
        print(f"Skipped (exists): {name}")
        skipped.append(name)
        continue

    payload = {
        "name": shortcut["name"],
        "path": shortcut["path"],
        "target": shortcut["target"]
    }

    response = requests.post(base_url, headers=headers, json=payload)

    if response.status_code in [200, 201]:
        print(f"Created: {shortcut['name']}")
    else:
        print(f"Failed: {shortcut['name']} → {response.text}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
