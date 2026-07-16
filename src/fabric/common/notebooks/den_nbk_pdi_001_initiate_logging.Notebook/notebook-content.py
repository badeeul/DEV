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

# ## Purpose # 
# # 
# # 
# # 
# # 
# # 
# The purpose of this notebook is to create tables (if they don't exist) in the observability lakehouse.


# PARAMETERS CELL ********************

# Mandatory parameters, passed from DFA pipeline
run_id = '8a839755-1ff5-4fb0-a368-6c955cb44676'
feed_name = 'mga_hop'
elt_start_date_time ='2024-10-25T15:28:25.1332696Z'
product_name='HOP'

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# Import modules/libraries


# CELL ********************

from spark_engine.common.observability import GDAPObservability
gdap_observability = GDAPObservability(spark)
gdap_observability.create_observability_tables()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# The code cell below inserts a new row in audit.elt_log table


# CELL ********************

gdap_observability.initialize_elt_log(master_run_id=run_id, product_name=product_name
            , feed_name=feed_name, elt_start_date_time=elt_start_date_time)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
