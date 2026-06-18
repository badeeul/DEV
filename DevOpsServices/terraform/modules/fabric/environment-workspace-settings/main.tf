
terraform {
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}
locals {

  environment_map = {
    for ws_name, ws_id in var.workspace_ids : ws_name => {
      workspace_id = ws_id
    }
  }

}

resource "fabric_spark_workspace_settings" "this" {
  for_each = local.environment_map

  provider     = fabric
  workspace_id = each.value.workspace_id

  automatic_log = {
    enabled = true
  }

  high_concurrency = {
    notebook_interactive_run_enabled = false
    notebook_pipeline_run_enabled   = true    
  }

  environment = {
    name            = var.default_spark_environment_name != "null" ? var.default_spark_environment_name : null
    runtime_version = var.default_spark_runtime != "null" ? var.default_spark_runtime : "1.3"
  }

}