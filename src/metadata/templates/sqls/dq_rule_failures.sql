WITH cte AS (
    SELECT dp_processing_batch_key, error_event_timestamp
    FROM den_lhw_pdi_001_observability.data_quality.fact_dq_error_event 
    WHERE dp_processing_batch_key <> '1'
    ORDER BY error_event_timestamp DESC
    LIMIT 1
), 
cte2 AS (
    SELECT
        CAST(CURRENT_TIMESTAMP AS DATE) AS stats_as_of_date,
        r.dq_rule_master_key,
        r.dq_rule_id,
        REPLACE(r.dq_rule_description, CHAR(10), ' ') AS dq_rule_description,
        r.dq_rule_constraint,
        r.dq_rule_applicable_object,
        r.dq_screen_type,
        r.dq_rule_failure_action,
        ee.severity_score,
        ee.error_event_timestamp,
        ee.dp_processing_batch_key,
        COUNT(*) AS failed_dq_count,
        CASE WHEN r.dq_rule_constraint LIKE '%"quarantine":true%' 
             THEN 'True' 
             ELSE 'False' 
        END AS quarantined
    FROM den_lhw_pdi_001_observability.data_quality.fact_dq_error_event ee
    JOIN den_lhw_pdi_001_observability.data_quality.dim_dq_rule_master r
        ON r.dq_rule_master_key = ee.dq_rule_master_key
    JOIN den_lhw_pdi_001_observability.data_quality.fact_dq_error_event_detail ed
        ON ee.dq_error_event_key = ed.dq_error_event_key
    JOIN cte c ON c.dp_processing_batch_key = ee.dp_processing_batch_key
    GROUP BY
        r.dq_rule_master_key,
        r.dq_rule_id,
        r.dq_rule_description,
        r.dq_rule_constraint,
        r.dq_rule_applicable_object,
        r.dq_screen_type,
        r.dq_rule_failure_action,
        ee.severity_score,
        ee.error_event_timestamp,
        ee.dp_processing_batch_key
),
cteAll AS (
    SELECT *, 
        ROW_NUMBER() OVER(PARTITION BY dq_rule_master_key ORDER BY error_event_timestamp DESC) AS row_num
    FROM cte2 
)
SELECT 
    stats_as_of_date,
    dq_rule_id,
    dq_rule_description,
    dq_rule_applicable_object,
    dq_screen_type,
    dq_rule_failure_action,
    error_event_timestamp,
    failed_dq_count,
    quarantined
FROM cteAll
WHERE row_num = 1
ORDER BY dq_rule_applicable_object, failed_dq_count DESC