# Azure Key Vault Secret Publisher via Lakehouse Files Directory

## What it does

This notebook scans all `.pub` / `.asc` files in the configured OneLake folder (`Files/key_vault_secrets`), reads its content and creates or updates key vault secret via REST API.

The notebook uses the **filename** (without extension) as the **secret name** in Key Vault.

Example:
- `claims-vip-public-key.asc` -> Secret name: `claims-vip-public-key`

## How it works

1. Retrieves the metadata lakehouse path dynamically using `notebookutils`
2. Uses `fsspec` with ABFSS to recursively walk the `key_vault_secrets` directory
3. Reads each `.pub` or `.asc` file
4. Calls Azure Key Vault REST API to add/update the secret
5. Logs success with Secret ID and Version

## Requirements

- Microsoft Fabric Notebook (Synapse Spark)
- Notebook identity must have **Key Vault Secrets Officer** permissions on the target Key Vault
- Lakehouse `den_lhw_pdi_001_metadata` must exist in the workspace

## Logging

The notebook uses Python's `logging` module with INFO level. All major steps and outcomes are clearly logged, including:
- Files discovered and read
- Success/failure of each Key Vault operation
- Total execution time