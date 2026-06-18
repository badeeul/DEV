# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "aec951bf-ac04-42c4-8f46-d7871ba38b3e",
# META       "default_lakehouse_name": "den_lhw_pdi_001_observability",
# META       "default_lakehouse_workspace_id": "576daab2-755c-48e5-9567-7583c3efb1b0",
# META       "known_lakehouses": [
# META         {
# META           "id": "aec951bf-ac04-42c4-8f46-d7871ba38b3e"
# META         }
# META       ]
# META     },
# META     "environment": {
# META       "environmentId": "eccb61a4-306f-40f8-a7e1-53e1b34b5b1a",
# META       "workspaceId": "00000000-0000-0000-0000-000000000000"
# META     }
# META   }
# META }

# CELL ********************

%run den_nbk_pdi_001_workspace_parameters

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

%run den_nbk_pde_001_shared_utils

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# PARAMETERS CELL ********************

email_template_name = 'dq_rule_failure_msg.json'
sql_query_name = 'dq_rule_failures.sql'

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Get current date
from datetime import datetime
current_date = datetime.now().strftime("%Y-%m-%d")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Get WorkspaceName
workspace_name = get_workspace_name()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

workspace_name = get_workspace_name()
key_vault_name = secretsScope 
replacement_tokens = {
        'workspace_name': workspace_name,
        'run_date': current_date        
        }
email_template_name_location = get_template_location_url(file_name=email_template_name)
email_value = read_json_file(email_template_name_location)
email_dict = replace_tokens_in_json_object(email_value, replacement_tokens)


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Load SQL template
sql_template_location = get_template_location_url(file_name=sql_query_name,notification_type='sqls')
sql_query = read_sql_template(sql_template_location)


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Execute the DQ Error Report SQL Query using template
dq_error_report_df = spark.sql(sql_query)


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Generate HTML content with the data quality table
def calculate_widths(pandas_df):
    widths = {}
    base_font_size = 12 
    min_width = 80  
    max_width = 300
    
    for column in pandas_df.columns:
        max_content_length = pandas_df[column].astype(str).apply(len).max()
        header_length = len(str(column))
        
        max_length = __builtins__.max(max_content_length, header_length)
        
        calculated_width = max_length * base_font_size
        final_width = __builtins__.max(min_width, __builtins__.min(calculated_width, max_width))
        
        widths[column] = final_width
    
    return widths

def create_html_table(df1,table1_title=""):
    
    
    def process_dataframe(df):
        pandas_df = df.toPandas()
        widths = calculate_widths(pandas_df)
                
        if 'Match (%)' in pandas_df.columns and pandas_df['Match (%)'].dtype in ['int64', 'float64']:
            pandas_df['Match (%)'] = pandas_df['Match (%)'].apply(
                lambda x: f"{x:.4f}%" if pd.notna(x) else "N/A"
            )
        if 'Difference (%)' in pandas_df.columns and pandas_df['Difference (%)'].dtype in ['int64', 'float64']:
            pandas_df['Difference (%)'] = pandas_df['Difference (%)'].apply(
                lambda x: f"{x:.4f}%" if pd.notna(x) else "N/A"
            )
            
        return pandas_df, widths
    
    def generate_table_html(pandas_df, widths):
        html_table = pandas_df.to_html(
            index=False, 
            classes='dynamic-table', 
            escape=False
        )
        
        css_styles = ""
        for i, column in enumerate(pandas_df.columns, 1):
            css_styles += """
                th:nth-child(%d), td:nth-child(%d) { 
                    width: %dpx; 
                    max-width: %dpx;
                    %s
                    border: 1px solid #3498db !important;
                }
                """ % (
                i, i, widths[column], widths[column],
                'text-align: right;' if column != 'LOB' else ''
            )

        return html_table, css_styles
    
    # Process first dataframe
    pandas_df1, widths1 = process_dataframe(df1)
    html_table1, css_styles1 = generate_table_html(pandas_df1, widths1)
    
    # Generate HTML content
    html_content = """
    <html>
    <head>
    <style>
        .dynamic-table {
            border: 2px solid #2980b9;
            border-collapse: collapse;
            width: auto;
            margin: 20px 0;
            font-family: Arial, sans-serif;
            font-size: 12px;
            table-layout: fixed;
            box-shadow: 0 2px 6px rgba(52, 152, 219, 0.2);
        }
        .dynamic-table th, .dynamic-table td {
            border: 1px solid #3498db;
            padding: 10px 8px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .dynamic-table th {
            background: linear-gradient(135deg, #3498db, #2980b9);
            background-color: transparent;
            color: inherit;
            font-weight: bold;
            border-bottom: 2px solid #2471a3;
            text-align: center;
        }
        .dynamic-table td {
            background-color: transparent;
            color: inherit;
        }
        .dynamic-table tr:nth-child(even) td {
            background-color: transparent;
            color: inherit;
        }
        .dynamic-table tr:hover td {
            background-color: transparent;
            color: inherit;
        }
    """
    html_content += css_styles1
    html_content += """

        .dynamic-table thead th {
            border-bottom: 2px solid #2471a3;
        }
        .dynamic-table tbody tr:last-child td {
            border-bottom: 1px solid #3498db;
        }
        
        .numeric {
            text-align: right; 
            font-family: 'Courier New', monospace;
            font-weight: bold;
        }
        .positive-diff { color: #27ae60; }
        .negative-diff { color: #e74c3c; }
        .zero-diff { color: #3498db; font-weight: bold; }
        
        th:nth-child(1), td:nth-child(1) {
            text-align: left !important;
            font-weight: bold;
            border-left: 1px solid #3498db !important;
        }
        
        
        th:last-child, td:last-child {
            border-right: 1px solid #3498db !important;
        }
        
        .table-title {
            color: #2980b9;
            font-size: 16px;
            font-weight: bold;
            margin: 20px 0 10px 0;
            padding-bottom: 5px;
            border-bottom: 2px solid #3498db;
        }
        
        .table-container {
            margin-bottom: 30px;
        }
    </style>
    </head>
    <body>
        <h4 style="color: #2980b9; border-bottom: 2px solid #3498db; padding-bottom: 5px;">
            Common Product and Pricing data product DQ Rules Failures. Please find the summary below:
        </h4>
        
        <!-- First Table -->
        <div class="table-container">
            <div class="table-title">"""
    html_content += table1_title + "</div>" if table1_title else ''
    html_content += """<div style="overflow-x: auto; padding: 5px; background-color: #f8fbfd; border-radius: 5px;">"""
    html_content += html_table1
    html_content += """
        </div>
            </div>
    """
    html_content +="""
    </body>
        </html>"""
    return html_content
    
html_body = create_html_table(
    dq_error_report_df,
    table1_title="DPR DQ Rules Failures"
    )


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# set parameters and send email
input_params = {
    "subject" : email_dict["subject"],
    "body" : html_body,  # Use the generated HTML instead of raw template
    "to_email" : email_dict["emailRecipient"],
    "cc_email" : email_dict["emailCc"],
    "from_account" : email_dict["emailSender"],
    "key_vault_name" : secretsScope
}

send_email(**input_params)


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
