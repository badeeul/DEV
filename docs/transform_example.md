# Testing Transform YAML Config
Testing a YAML config file can be done outside of a pipeline run by using the platform services python library.

Create a notebook and attach the spark environment `den_env_pdi_001_spark_runtime_environment`

```py
from spark_engine.transform.transform import Transform

# path to transform yaml config
transform_config_path = "abfss://5e49f81d-f646-4bb3-8785-cbb0699886ef@onelake.dfs.fabric.microsoft.com/1c7f88d2-cb5a-4172-b5f9-818c56338818/Files/data_product/mgahop/ho_policy_data.yaml"

# initialize the transform class
transform = (
    Transform(transform_config_path)
    .configure_transform(
        # needed only if using incremental sources
        product_name,
        feed_name,
        dataset_name
    )
)
```

```py
# view sources
print(transform.sources)

# generate the temp views for each source
transform._generate_source_views()
```

```py
# view queries
print(transform.queries)
```

```py
# run query and save to temp view
# source views must be generated first
# queries can be run one-by-one like this to help debug
# queries must be run in order due to dependencies or will get the error message "Spark SQL queries are only possible in the context of a lakehouse".
query_num = 0
spark.sql(transform.queries[query_num]["sql"]).createOrReplaceTempView(transform.queries[query_num]["name"])
```

```py
# execute the queries in order to create the final dataframe
transform_df = transform._execute_queries()
display(transform_df)
```

```py
# run transformation and load target table
metrics = (
    transform.start_transform(elt_id="1", run_id="1")
    .metrics()
)
print(metrics)
```