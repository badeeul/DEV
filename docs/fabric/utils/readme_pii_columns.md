# YAML PII Columns Scanner  

## What it does

This notebook scans all `.yaml` / `.yml` files in the configured OneLake folder (`Files/data_product`) and extracts:

- `target.lakehouse`
- `target.schema`
- `target.table`
- `target.pii_columns` (when declared)

It then explodes the PII columns into one row per column and merges the result into a Delta table in the observability lakehouse.

**Output table**  
`den_lhw_pdi_001_observability.audit.yaml_pii_columns_config`

**Table columns**  
- `workspace`  
- `lakehouse`  
- `schema`  
- `table`  
- `pii_column` (exploded - one per row)  
- `yaml_file_path` (relative path under `Files/`)  
- `yaml_file_name`  
- `loaded_timestamp`

## Features

- Dynamic lakehouse/workspace detection using `notebookutils`
- Recursive ABFSS scan with `fsspec`
- Merge-based upsert (deduplicates by workspace+lakehouse+schema+table+pii_column)
- Structured logging with file & record counts
- Relative path storage (human-readable)
- Spark-managed timestamp (`current_timestamp()`)

## How to Run

1. Open in a **Microsoft Fabric notebook** attached to a lakehouse
2. (Optional) Override scan path by setting `DEFAULT_YAML_ROOT`
3. Execute all cells

```python
# Example override
# DEFAULT_YAML_ROOT = "abfss://.../Files/other_folder"