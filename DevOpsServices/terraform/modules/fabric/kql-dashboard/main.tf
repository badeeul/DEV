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
  platform_files = fileset("${path.root}/../../../src/fabric", "**/*.KQLDashboard/.platform")
 
  # debug_info = {
  #   root_path   = local.debug_root
  #   found_files = toset(local.platform_files)
  # }
 
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
 
  # Read and parse dashboard platform files
  dashboard_configs = {
    for platform_file in local.platform_files : dirname(platform_file) => {
      content_file = "${path.root}/../../../src/fabric/${dirname(platform_file)}/RealTimeDashboard.json"
      platform_file = "${path.root}/../../../src/fabric/${platform_file}"
      display_name = jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).metadata.displayName
      description = try(
        jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).metadata.description,
        ""
      )
      folder_path = dirname(platform_file)
    }
  }
 
  # Create dashboard map for each workspace
  dashboard_map = {
    for pair in setproduct(keys(var.workspace_ids), keys(local.dashboard_configs)) :
    "${pair[0]}-${basename(pair[1])}" => {
      workspace_name = pair[0]
      workspace_id   = var.workspace_ids[pair[0]]
      display_name   = local.dashboard_configs[pair[1]].display_name
      description    = local.dashboard_configs[pair[1]].description
      content_file   = local.dashboard_configs[pair[1]].content_file
      platform_file  = local.dashboard_configs[pair[1]].platform_file
      folder_path    = local.dashboard_configs[pair[1]].folder_path
      dashboard_content = try(
        fileexists(local.dashboard_configs[pair[1]].content_file)
          ? file(local.dashboard_configs[pair[1]].content_file)
          : null,
        null
      )
    }
  }
}

# Create KQL dashboards using null_resource with PowerShell script
resource "null_resource" "kql_dashboard" {
  for_each = local.dashboard_map

  triggers = {

    timestamp       = timestamp() # Force recreation on every apply
  }

  # Single provisioner that handles both create and update logic
  provisioner "local-exec" {
    command = join(" ", compact([
      "& {",
      "& '${path.root}/../../pipelines/scripts/Invoke-KQLDashboardManagement.ps1'",
      "-Action 'CreateOrUpdate'",
      "-WorkspaceId '${each.value.workspace_id}'",
      "-DisplayName '${each.value.display_name}'",
      each.value.description != null && each.value.description != "" ? "-Description '${each.value.description}'" : "",
      each.value.dashboard_content != null ? "-ContentFile '${each.value.content_file}'" : "",
      "-PlatformFile '${each.value.platform_file}'",
      var.folder_hierarchy != null ? "-FolderHierarchy '${var.folder_hierarchy}'" : "",
      each.value.folder_path != null ? "-FolderPath '${each.value.folder_path}'" : "",
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

