# Dataset Query File Generator

## Overview
This Python notebook (`den_nbk_pdi_001_cicd_generate_dataset_query_file`) is designed to generate or update JSON query files for datasets based on STTM (Source To Target Mapping) changes as part of a CI/CD post-deployment process. It supports full, watermark-based and CDC (Change Data Capture) ingestion types.

## Purpose
The notebook:
- Scans a specified OneLake directory for dataset configuration files
- Generates SQL queries based on dataset configurations
- Creates watermark JSON files for incremental data processing
- Handles both watermark and CDC ingestion types
- Supports dynamic query filtering

## Prerequisites
- Python 3.8+
- Required libraries:
  - `notebookutils`
  - `fsspec`
- Access to OneLake storage
- Valid workspace and lakehouse IDs
- Properly formatted dataset configuration files in JSON format

## Usage
1. Ensure all prerequisites are met and configuration is updated.
2. Place (manual or cicd) dataset file(s) in the appropriate OneLake directory.
3. The notebook will be **automatically run as part of the CI/CD process** if its name contains the string `_cicd_`.