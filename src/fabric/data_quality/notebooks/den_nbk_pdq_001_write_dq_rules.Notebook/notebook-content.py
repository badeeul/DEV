# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark",
# META     "jupyter_kernel_name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# CELL ********************

from spark_engine.common.lakehouse import LakehouseManager
metadata_lakehouse = LakehouseManager("den_lhw_pdi_001_metadata")
observability_lakehouse = LakehouseManager("den_lhw_pdi_001_observability")

if observability_lakehouse.check_if_table_exists("dim_dq_rule_master", "data_quality"):
    (
        spark.read
        .option("multiLine", True)
        .json(f"{metadata_lakehouse.lakehouse_path}/Files/data_quality/dim_dq_rule_master.json")
        .selectExpr(
            "cast(dq_rule_master_key as int) as dq_rule_master_key",
            "dq_rule_id",
            "data_product_name",
            "sub_domain_name",
            "dq_rule_description",
            "to_json(dq_rule_constraint) as dq_rule_constraint",
            "dq_rule_dimension",
            "dq_screen_type",
            "dq_rule_applicable_lakehouse",
            "dq_rule_applicable_schema",
            "dq_rule_applicable_object",
            "dq_rule_applicable_attribute",
            "dq_rule_failure_action",
            "dq_rule_severity_score",
            "cast(1 as boolean) as is_current_flag",
            "cast('1900-01-01' as timestamp) as row_effective_date",
            "cast('9999-12-31' as timestamp) as row_expiration_date"
        )
        .write.mode("overwrite")
        .save(f"{observability_lakehouse.lakehouse_path}/Tables/data_quality/dim_dq_rule_master")
    )

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
