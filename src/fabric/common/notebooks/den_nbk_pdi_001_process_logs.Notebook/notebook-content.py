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

# PARAMETERS CELL ********************

elt_id = "4298a058-a256-49df-adcc-5eb2e4449dcf"
update_elt_log = False

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from pyspark.sql.functions import input_file_name, col, lit
from spark_engine.common.lakehouse import LakehouseManager, SchemaManager
from spark_engine.common.error_and_retry_handlers import delta_operations_handler
from spark_engine.common.observability import GDAPObservability
import json

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_current_user():
    return delta_operations_handler(lambda: spark.sql("select current_user as current_user").collect()[0].current_user)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_raw_zone_start_time(file_content):
    if "executionDetails" in file_content["metadata"]:
        return file_content["metadata"]["executionDetails"][0]["start"]
    return None

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_curated_data_size(events_list):
    data_size = 0
    # iterate raw zone messages of a run
    for event in events_list:
        if "runOutput" in event.get("metadata", {}):
            run_output = event["metadata"]["runOutput"]
            if isinstance(run_output, str):
                run_output = json.loads(run_output)
            # calculate data size
            try:
                data_size += run_output["ingestion"]["sourceDataCount"]
            except KeyError:
                pass
    return data_size

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_curated_zone_start_time(file_content):
    if "runOutput" in file_content["metadata"]:
        run_output = file_content["metadata"]["runOutput"]
    if isinstance(run_output, dict):
        return run_output["ingestion"]["startTime"]
    else:
        run_output = json.loads(run_output)
        return run_output["ingestion"]["startTime"]
    return None

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def read_json_file(file_location):
    jsonDf = spark.read.text(file_location, wholetext=True)
    content = jsonDf.first()["value"]
    if content.startswith("\ufeff"):
            content = content[1:]
    return json.loads(content)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def add_curated_metadata_columns(file_content, df_ingestion_log_append):
    run_output = file_content["metadata"]["runOutput"]
    if not isinstance(run_output, dict):
        run_output = json.loads(run_output)
    status = "Succeeded"
    if "error_message" in run_output["ingestion"]:
        status = "Failed"
    try:
        total_rows_read = run_output["ingestion"]["sourceDataCount"]
    except KeyError:
        total_rows_read = -1
    try:
        total_rows_written = run_output["ingestion"]["recordUpdates"]
    except KeyError:
        total_rows_written = -1

    source_file_path = file_content.get("source_file_path")
    return (df_ingestion_log_append.withColumn("data_read", lit(total_rows_read).cast("bigint"))
                  .withColumn("data_written", lit(total_rows_written).cast("bigint"))
                  .withColumn("source_file_path", lit(source_file_path))
                  .withColumn("status", lit(status)))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def add_raw_metadata_columns(file_content, df_ingestion_log_append):
    file_content = file_content["metadata"]
    status = "Succeeded"
    files_read = None
    files_written = None
    throughput = None
    data_read = None
    data_written = None
    copy_duration = None
    if "errors" in file_content and len(file_content["errors"]) > 0 or file_content["executionDetails"][0]["status"] == "Canceled":
        status = "Failed"
    if "filesRead" in file_content: # for file source
        files_read = file_content["filesRead"]
    elif "rowsRead" in file_content: #for database source
        files_read = file_content["rowsRead"]
    if "filesWritten" in file_content: # for file source
        files_written = file_content["filesWritten"]
    elif "rowsCopied" in file_content: #for database source
        files_written = file_content["rowsCopied"]
    if "throughput" in file_content: 
        throughput = file_content["throughput"]
    if "dataRead" in file_content:
        data_read = file_content["dataRead"]
    if "dataWritten" in file_content:
        data_written = file_content["dataWritten"]
    if "copyDuration" in file_content:
        copy_duration = file_content["copyDuration"]
    return (df_ingestion_log_append.withColumn("data_read", lit(data_read).cast("bigint"))
                         .withColumn("data_written", lit(data_written).cast("bigint"))
                         .withColumn("files_read", lit(files_read))
                         .withColumn("files_written", lit(files_written))
                         .withColumn("status", lit(status))
                         .withColumn("throughput", lit(throughput).cast("double"))
                         .withColumn("copy_duration", lit(copy_duration).cast("integer")))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_raw_data_size(events_list):
    data_size = 0
    # iterate raw zone messages of a run
    for event in events_list:
        # calculate data size
        try:
            data_size += event["metadata"]["dataWritten"]
        except KeyError:
            pass
    return data_size # in bytes

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_curated_zone_final_status(events_list):
    # iterate raw zone messages of a run
    for event in events_list:
        # check if any curated zone copy activity is failed
        run_output = event.get('metadata', {}).get('runOutput', {})
        if isinstance(run_output, str):
            run_output = json.loads(run_output)
        if 'error_message' in run_output.get('ingestion', {}):
                return "Failed"
    return "Succeeded"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def insert_zone_level_log(log_dict, elt_id, zone, is_existing_id):
    data_size = 0
    zone_start_date_time = "1900-01-01T00:00:00.0000000Z"
    table_path = get_table_location_url(table_name="elt_zone_log")
    stage = None
    if(zone == "Raw"):
        # get raw zone final status
        status = get_raw_zone_final_status(log_dict[elt_id]["Raw"])
        # get the first item in the list which is raw zone"s latest record of a
        # run id
        res = log_dict[elt_id]["Raw"][0]
        zone_start_date_time = get_raw_zone_start_time(log_dict[elt_id]["Raw"][-1])
        stage = "Ingestion"
        if status == "Succeeded":
            data_size = get_raw_data_size(log_dict[elt_id]["Raw"])
    elif(zone == "Curated"):
        # get curated zone final status
        status = get_curated_zone_final_status(log_dict[elt_id]["Curated"])
        zone_start_date_time = get_curated_zone_start_time(log_dict[elt_id]["Curated"][-1])
        # get the first item in the list which is curated zone"s latest record
        # of a run id
        res = log_dict[elt_id]["Curated"][0]
        stage = res["stage"]
        if status == "Succeeded":
            data_size = get_curated_data_size(log_dict[elt_id]["Curated"])
    elif(zone == "Product"):
        # get curated zone final status
        status = get_curated_zone_final_status(log_dict[elt_id]["Product"])
        zone_start_date_time = get_curated_zone_start_time(log_dict[elt_id]["Product"][-1])
        # get the first item in the list which is curated zone"s latest record
        # of a run id
        res = log_dict[elt_id]["Product"][0]
        stage = res["stage"]
        if status == "Succeeded":
            data_size = get_curated_data_size(log_dict[elt_id]["Product"])      
    elif(zone == "Integration"):
        # get curated zone final status
        status = get_curated_zone_final_status(log_dict[elt_id]["Integration"])
        zone_start_date_time = get_curated_zone_start_time(log_dict[elt_id]["Integration"][-1])
        # get the first item in the list which is curated zone"s latest record
        # of a run id
        res = log_dict[elt_id]["Integration"][0]
        stage = res["stage"]
        if status == "Succeeded":
            data_size = get_curated_data_size(log_dict[elt_id]["Integration"])    
    elif(zone == "Extract"):
        # get raw zone final status
        status = get_extract_zone_final_status(log_dict[elt_id]["Extract"])
        # get the first item in the list which is raw zone"s latest record of a
        # run id
        res = log_dict[elt_id]["Extract"][0].copy()
        res["zone"] = "Raw"
        zone_start_date_time = get_extract_zone_start_time(log_dict[elt_id]["Extract"][-1])
        stage = "Ingestion"
        if status == "Succeeded":
            data_size = get_extract_data_size(log_dict[elt_id]["Extract"])
    if not is_existing_id:
        # prepare the value to be inserted
        rows = [[elt_id,
                 res["run_id"],
                 zone_start_date_time,
                 res["product_name"],
                 res["feed_name"],
                 res["zone"],
                 stage,
                 res["zone_end_date_time"],
                 status,
                 data_size]]
        elt_zone_log_df = spark.createDataFrame(rows,
                                           ["elt_id",
                                            "run_id",
                                            "zone_start_date_time",
                                            "product_name",
                                            "feed_name",
                                            "zone",
                                            "stage",
                                            "zone_end_date_time",
                                            "zone_status",
                                            "total_data_size"])
        # prepare dataframe with extended columns
        elt_zone_log_df = (elt_zone_log_df
                                .withColumn("zone_start_date_time", col("zone_start_date_time").cast("timestamp"))
                                .withColumn("zone_end_date_time", col("zone_end_date_time").cast("timestamp")))
        # write to elt_log table
        elt_zone_log_df.coalesce(1).write.format("delta").mode("append").partitionBy("product_name", "feed_name", "zone", "stage").save(table_path),
    else:
        input_params = {
            "zone_end_date_time": res["zone_end_date_time"],
            "status": status,
            "zone": res["zone"],
            "elt_id": res["elt_id"],
            "total_data_size": data_size,
            "stage": stage
        }
        # Update status for elt zone log table
        gdapo.update_status_for_elt_zone_log(**input_params)
    if status == "Failed":
        gdapo.update_elt_log(master_run_id=elt_id)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_raw_zone_final_status(events_list):
    # iterate raw zone messages of a run
    for event in events_list:
        # check if any raw zone copy activity is failed
        if "errors" in event['metadata']:
            # This key may exist but be empty
            if len(event['metadata']['errors']) > 0 or event['metadata']['executionDetails'][0]['status'] == 'Canceled':
                return 'Failed'
    return 'Succeeded'

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def insert_elt_zone_log(log_dict, gdapo):
    # iterate log messages
    for elt_id in log_dict:
        already_recorded = gdapo.get_zone_log_data(elt_id=elt_id)
        for key, value in log_dict[elt_id].items():
            already_raw_recorded = already_recorded.filter(col("zone") == key)
            is_existing_id = len(already_raw_recorded.take(1)) == 1
            insert_zone_level_log(log_dict, elt_id, key, is_existing_id)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def get_table_location_url(lakehouse_name="den_lhw_pdi_001_observability",table_schema="audit",table_name="") -> str:
    lakehouse_manager = LakehouseManager(lakehouse_name=lakehouse_name)
    tables_path = f"{lakehouse_manager.lakehouse_path}/Tables"
    table_schema,table_name = (table_schema,table_name)
    return f"{tables_path}/{table_schema}/{table_name}"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

def add_extract_metadata_columns(file_content, df_ingestion_log_append):
    metadata = file_content["metadata"]
    status = "Succeeded"
    if metadata.get("error"):
        status = "Failed"
        data_read = None
        data_written = None
        copy_duration = None
    else:
        data_read = metadata["outputBytes"]
        data_written = data_read
        copy_duration = metadata["extractDuration"] + metadata["copyDuration"]
    return (df_ingestion_log_append
        .withColumn("data_read", lit(data_read).cast("bigint"))
        .withColumn("data_written", lit(data_written).cast("bigint"))
        .withColumn("status", lit(status))
        .withColumn("copy_duration", lit(copy_duration).cast("integer"))
        .withColumn("zone", lit("Raw"))
    )

def get_extract_data_size(events_list):
    data_size = 0
    # iterate raw zone messages of a run
    for event in events_list:
        # calculate data size
        try:
            data_size += event["metadata"].get("outputBytes", 0)
        except KeyError:
            pass
    return data_size # in bytes

def get_extract_zone_final_status(events_list):
    # iterate raw zone messages of a run
    for event in events_list:
        # check if any raw zone copy activity is failed
        if event['metadata'].get("error"):
            return 'Failed'
    return 'Succeeded'

def get_extract_zone_start_time(file_content):
    return file_content["metadata"]["extractStartTime"]

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Start processing log files

lakehouse_manager = LakehouseManager(lakehouse_name="den_lhw_pdi_001_observability")
json_log_path = f"{lakehouse_manager.lakehouse_path}/Files/Metadata_Logs"
log_dict = {}

gdapo = GDAPObservability(spark)

current_user = get_current_user()
files = notebookutils.fs.ls(json_log_path)
table_path = get_table_location_url(table_name="source_ingestion_log")

for file_info in files:
    try:
        file_location = f"{json_log_path}/{file_info.name}"
        file_content = read_json_file(file_location) # transform to dictionary
        # Check and handle error property in the file
        # 
        if file_content["metadata"] == "Error: Unable to parse JSON metadata":
            # We"ll use the elt_start_date_time for the logging
            file_content["metadata"] = {"errors": [file_content["metadata"]], "executionDetails": [{"status": "Failed", "start": res["elt_start_date_time"], "comment": "start time has been reset to elt_start_date_time!"}]}
        metadata = json.dumps(file_content["metadata"])

        # filter the logs assosiated with the pipeline run id wich got triggered
        # Zones Curated & Modelled should follow the same path
        if "Raw" == file_content["zone"]:
            zone_start_date_time = get_raw_zone_start_time(file_content)
        elif file_content["zone"] in ["Curated", "Product", "Integration"]:
            zone_start_date_time = get_curated_zone_start_time(file_content)
        elif file_content["zone"] == "Extract":
            zone_start_date_time = get_extract_zone_start_time(file_content)

        # cast values to string to avoid type inference issue with NULL when creating the dataframe
        row_values = [(
            str(file_content["run_id"]),
            str(file_content["elt_id"]),
            str(file_content["product_name"]),
            str(file_content["feed_name"]),
            str(file_content["source_system"]),
            str(file_content["dataset_name"]),
            metadata,
            str(zone_start_date_time),
            str(file_content["zone_end_date_time"]),
            str(current_user),
            str(current_user)
        )]
        df_ingestion_log_append = spark.createDataFrame(row_values, [
        "run_id", "elt_id","product_name","feed_name","source_system","dataset_name","metadata","start_date_time","end_date_time","inserted_by","modified_by"
        ])
        df_ingestion_log_append = (df_ingestion_log_append.withColumn("start_date_time", col("start_date_time").cast("timestamp"))
                                                        .withColumn("end_date_time", col("end_date_time").cast("timestamp"))
                                                        .withColumn("zone", lit(file_content["zone"]))
        )

        if file_content["zone"] == "Raw":
            df_ingestion_log_append = add_raw_metadata_columns(file_content, df_ingestion_log_append)
        elif file_content["zone"] == "Extract":
            df_ingestion_log_append = add_extract_metadata_columns(file_content, df_ingestion_log_append)
        else:
            df_ingestion_log_append = add_curated_metadata_columns(file_content, df_ingestion_log_append)    

        # TO DO: use Delta operation handler with retry
        df_ingestion_log_append.write.format("delta").mode("append").partitionBy(
            "product_name",
            "feed_name",
            "source_system",
            "dataset_name").save(table_path) 
        # remove processed file    
        notebookutils.fs.rm(file_location)
        # process elt log
        if file_content["elt_id"] not in log_dict:
            log_dict[file_content["elt_id"]] = {file_content["zone"]: []}
        elif file_content["zone"] not in log_dict[file_content["elt_id"]]:
            log_dict[file_content["elt_id"]][file_content["zone"]] = []
        log_dict[file_content["elt_id"]][file_content["zone"]].append(file_content)
        log_dict[file_content["elt_id"]][file_content["zone"]].sort(
        key=lambda x: x["zone_end_date_time"], reverse=True)

        print(f"Adding records to elt log table for elt id: {elt_id}")
        # process elt zone log 
        insert_elt_zone_log(log_dict, gdapo)
    except Exception as e:
        print(f"Exception occured while processing log file {file_location}; for elt id: {elt_id}.")
        print(f"Please check the file and clear if necessary then rerun this notebook to process the event messages. Exception type: {type(e)}; Exception Message: {e}")
        raise e       
# update elt_log table if requested
if update_elt_log:
    print('updating elt_log table...')
    gdapo.update_elt_log(master_run_id=elt_id)
    print('elt_log table was updated.')

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
