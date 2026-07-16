![Fluidity Logo](../../docs/media/FluidityLogo-small.png)

# Fabric Assets

This folder contains all Microsoft Fabric assets for the Fluidity platform, including notebooks, pipelines, semantic models, reports, lakehouses, and shared utilities.

## Subfolders

### common
Shared common assets including spark runtime environments, reusable notebooks, and baseline pipelines used across multiple services.

### data_quality
Data quality validation and monitoring assets including data quality notebooks and analytical reports for tracking data quality metrics.

### engineering_service
Engineering service assets including transformation notebooks and orchestration pipelines for data engineering workflows.

### ingestion_service
Ingestion service assets including data ingestion notebooks and pipelines for loading data from various sources.

### lakehouse
Fabric Lakehouse instance and related configurations for centralized data storage and management.

### pbi_dst_001_metadata_pii_columns.SemanticModel
Power BI semantic model for metadata and PII column definitions, providing data modeling and relationships for reporting.

### pbi_rpt_001_metadata_pii_columns.Report
Power BI report for displaying metadata and PII column information with visualizations and analytics.

### utils
Utility notebooks including Azure Key Vault secret management and PII column extraction tools for common operational tasks.