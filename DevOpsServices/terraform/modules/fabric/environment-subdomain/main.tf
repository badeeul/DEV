terraform {
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

locals {
  debug_root     = path.root
  platform_files = fileset("${path.root}/../../../src/fabric", "**/*.Environment/.platform")
 
  # Filter out main spark runtime environment
  filtered_platform_files = [
    for file in local.platform_files : file
    if !can(regex(".*(den_env_pdi_001_spark_runtime_environment\\.Environment)", file))
  ]

  spark_settings = jsondecode(var.spark_compute)

  # Parse folder hierarchy
  folder_hierarchy = var.folder_hierarchy == "" ? [] : jsondecode(var.folder_hierarchy)
  
  # Read and parse environment platform files
  environment_configs = {
    for platform_file in local.filtered_platform_files : dirname(platform_file) => {
      display_name = jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).metadata.displayName
      logical_id = jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).config.logicalId
      folder_path = dirname(platform_file)
    }
  }

  # Map for environments to create
  subdomain_environment_map = {
    for pair in setproduct(keys(var.workspace_ids), keys(local.environment_configs)) :
    "${pair[0]}-${local.environment_configs[pair[1]].display_name}" => {
      workspace_id = var.workspace_ids[pair[0]]
      display_name = local.environment_configs[pair[1]].display_name
      logical_id = local.environment_configs[pair[1]].logical_id
      spark_settings = jsondecode(var.spark_compute)
      folder_path = local.environment_configs[pair[1]].folder_path
    }
  }
}

# Create environments using null_resource with PowerShell script
resource "null_resource" "environment_subdomain" {
  for_each = local.subdomain_environment_map

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
  for_each = local.subdomain_environment_map
  filename = "${path.root}/.terraform/environment_${replace(replace(each.key, "-", "_"), " ", "_")}_id.txt"

}


# Configure Spark settings for each environment
resource "null_resource" "spark_environment_settings_subdomain" {
  for_each = local.subdomain_environment_map

  triggers = {

    # when local spark settings changes
    spark_settings = jsondecode(var.spark_compute)
  

    # timestamp = timestamp() # Force this to always run
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
    null_resource.environment_subdomain
  ]
}