terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

locals {
  # Debug path and files found
  debug_root     = path.root
  platform_files = fileset("${path.root}/../../../src/ellie", "**/*.Notebook/.platform")


  notebook_configs = {
    for platform_file in local.platform_files : dirname(platform_file) => {
      default_lakehouse_name = "${jsondecode(file("${path.root}/../../../src/ellie/${platform_file}")).metadata.default_lakehouse_name}"
      display_name = "${jsondecode(file("${path.root}/../../../src/ellie/${platform_file}")).metadata.displayName}"
      # Get all SQL files in the directory
      sql_query_files = [
        for f in fileset("${path.root}/../../../src/ellie/${dirname(platform_file)}", "*.sql") :
          "${path.root}/../../../src/ellie/${dirname(platform_file)}/${f}"
      ]
    }
  }

  notebook_map = {
    for pair in setproduct(keys(var.workspace_ids), keys(local.notebook_configs)) :
    "${pair[0]}-${basename(pair[1])}" => {
      workspace_name = pair[0]
      workspace_id = var.workspace_ids[pair[0]]
      # Take the first SQL file if available
      display_name = local.notebook_configs[pair[1]].display_name
      content_file = length(local.notebook_configs[pair[1]].sql_query_files) > 0 ? local.notebook_configs[pair[1]].sql_query_files[0] : ""
      default_lakehouse_name = local.notebook_configs[pair[1]].default_lakehouse_name
      content = length(local.notebook_configs[pair[1]].sql_query_files) > 0 && fileexists(local.notebook_configs[pair[1]].sql_query_files[0]) ? file(local.notebook_configs[pair[1]].sql_query_files[0]) : ""

    }
  }

  # Filter out entries without lakehouse names or SQL content if required
  filtered_notebook_map = {
    for k, v in local.notebook_map : k => v
    if v.default_lakehouse_name != "" && v.content != "" && v.display_name != ""
  }

 
# Generate notebook content for each entry
  notebook_contents = {
    for k, v in local.filtered_notebook_map : k => jsonencode({
      cells = [{
        cell_type = "code"
        source = [v.content]
        metadata = {
          microsoft = {
            language = "sparksql"
            language_group = "synapse_pyspark"
          }
        }
        outputs = []
      }]
      metadata = {
        kernel_info = {
          name = "synapse_pyspark"
        }
        language_info = {
          name = "sql"
        }
        dependencies = {
          lakehouse = {
            default_lakehouse = var.lakehouse_ids[v.workspace_name][v.default_lakehouse_name]
            default_lakehouse_name = v.default_lakehouse_name
            default_lakehouse_workspace_id = v.workspace_id
          }
        }
      }
      nbformat = 4
      nbformat_minor = 2
    })
  }
}

# First create the notebook files
resource "local_file" "notebook_ipynb" {
  for_each = local.filtered_notebook_map
 
  content  = local.notebook_contents[each.key]
  filename = "${dirname(each.value.content_file)}/notebook-content.ipynb"  
}

resource "fabric_notebook" "this" {
  for_each = local.filtered_notebook_map

  provider     = fabric
  workspace_id = each.value.workspace_id
  display_name = each.value.display_name
  format       = "ipynb"
  definition = {
    "notebook-content.ipynb" = {
      source   = local_file.notebook_ipynb[each.key].filename
      encoding = "UTF-8"
    }
  }
  
  depends_on = [ local_file.notebook_ipynb ]
}
