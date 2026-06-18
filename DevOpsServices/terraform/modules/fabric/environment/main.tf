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
  debug_root     = path.root
  src_fabric_path = "${path.root}/../../../src/fabric"
 
  # Find platform services default environment, .platform file for environment
  platform_files = fileset(local.src_fabric_path, "**/den_env_pdi_001_spark_runtime_environment.Environment/.platform")
  platform_file_list = tolist(local.platform_files)
 
  # Get the actual file paths (first and only element if found)
  platform_path = length(local.platform_file_list) > 0 ? "${local.src_fabric_path}/${local.platform_file_list[0]}" : ""
 
  # Check if files exist
  files_exist = length(local.platform_file_list) > 0 ? fileexists(local.platform_path) : false
 
  # Parse platform file
  platform_json = local.files_exist ? jsondecode(file(local.platform_path)) : null
 
  # Parse spark settings
  spark_settings = jsondecode(var.spark_compute)
 
  # Map workspace names to IDs
  workspace_map = {
    for name, id in var.workspace_ids : name => id
  }
 
  # Parse folder hierarchy
  folder_hierarchy = var.folder_hierarchy == "" ? [] : jsondecode(var.folder_hierarchy)
 
  folder_hierarchy_config = [
    for folder in local.folder_hierarchy :
    {
      path               = folder.Path
      display_name       = folder.DisplayName
      id                 = folder.Id
      parent_folder_id   = folder.ParentFolderId
      workspace_id       = folder.WorkspaceId
    }
  ]
 
  # Create folder lookup map by path for easier matching
  folder_lookup = {
    for folder in local.folder_hierarchy_config :
    folder.path => folder
  }
 
  # Get folder path from platform file if it exists
  environment_folder_path = local.platform_json != null ? dirname(local.platform_file_list[0]) : ""
 
  # Environment map will be empty if files don't exist
  environment_map = local.files_exist ? {
    for ws_name, ws_id in var.workspace_ids : "${ws_name}-${local.platform_json.metadata.displayName}" => {
      workspace_name = ws_name
      workspace_id   = ws_id
      display_name   = local.platform_json.metadata.displayName
      logical_id     = local.platform_json.config.logicalId
      folder_path    = local.environment_folder_path
      spark_settings  = local.spark_settings
    }
  } : {}
}

# Create environments using null_resource with PowerShell script
resource "null_resource" "environment" {
  for_each = local.environment_map

  triggers = {

    timestamp = timestamp() # Force this to always run
  }

  # Single provisioner that handles both create and update logic
  provisioner "local-exec" {
    command = join(" ", compact([
      "& {",
      "$result = & '${path.root}/../../pipelines/scripts/Invoke-EnvironmentManagement.ps1'",
      "-Action 'CreateOrUpdate'",
      "-WorkspaceId '${each.value.workspace_id}'",
      "-DisplayName '${each.value.display_name}'",
      var.folder_hierarchy != null ? "-FolderHierarchy '${var.folder_hierarchy}'" : "",
      each.value.folder_path != null ? "-FolderPath '${each.value.folder_path}'" : "",
      "; if ($result) { $first_result = if ($result -is [array]) { $result[0] } else { $result }; $env_id = ($first_result | ConvertFrom-Json).id.Trim(); Set-Content -Path '${path.root}/.terraform/environment_${replace(replace(each.key, "-", "_"), " ", "_")}_id.txt' -Value $env_id -NoNewline -Force }",
      "}"
    ]))
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.root
  }

  provisioner "local-exec" {
    when = destroy
    command = "Write-Host 'removed from Terraform state but left intact in Fabric workspace for incremental process'"
    interpreter = ["PowerShell", "-Command"]
    on_failure = continue
  }

}

# Data source to read the environment IDs from files
data "local_file" "environment_ids" {
  for_each = local.environment_map
  filename = "${path.root}/.terraform/environment_${replace(replace(each.key, "-", "_"), " ", "_")}_id.txt"

  # depends_on = [null_resource.environment]
}

# Configure Spark settings for each environment
resource "null_resource" "spark_environment_settings" {
  for_each = local.environment_map

  triggers = {
 
    timestamp = timestamp()  # Force this to always run
  }

  provisioner "local-exec" {
    command = join(" ", compact([
      "& {",
      "& '${path.root}/../../pipelines/scripts/Invoke-SparkEnvironmentSettings.ps1'",
      "-WorkspaceId '${each.value.workspace_id}'",
      "-EnvironmentName '${each.value.display_name}'",
      "-DriverCores ${local.spark_settings.driver_cores}",
      "-DriverMemory '${local.spark_settings.driver_memory}'",
      "-ExecutorCores ${local.spark_settings.executor_cores}",
      "-ExecutorMemory '${local.spark_settings.executor_memory}'",
      "-RuntimeVersion '${local.spark_settings.runtime_version}'",
      "-MinExecutors ${local.spark_settings.min_executors}",
      "-MaxExecutors ${local.spark_settings.max_executors}",
      "}"
    ]))
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.root
  }

  depends_on = [
    null_resource.environment
  ]
}