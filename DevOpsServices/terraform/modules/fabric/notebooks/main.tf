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
  # Get all platform files
  all_platform_files = fileset("${path.root}/../../../src/fabric", "**/*.Notebook/.platform")
 
  # Filter out excluded notebooks
  platform_files = [
    for file in local.all_platform_files :
    file if !contains(var.excluded_notebooks, dirname(file))
  ]

  # Read and parse platform files with environment check
  notebook_configs = {
    for platform_file in local.platform_files : dirname(platform_file) => {
      content_file = coalesce(
        fileexists("${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.py") ? "${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.py" : "",
        fileexists("${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.scala") ? "${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.scala" : "",
        fileexists("${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.sql") ? "${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.sql" : "",
        "${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.py" # Default fallback
      )
      ipynb_file   = "${path.root}/../../../src/fabric/${dirname(platform_file)}/notebook-content.ipynb"
      platform_file = "${path.root}/../../../src/fabric/${platform_file}"
      display_name = "${jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).metadata.displayName}"
      folder_path  = dirname(platform_file)
    }
  }

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

  notebook_map = {
    for pair in setproduct(keys(var.workspace_ids), keys(local.notebook_configs)) :
    "${pair[0]}-${basename(pair[1])}" => {
      workspace_name = pair[0]
      workspace_id   = var.workspace_ids[pair[0]]
      notebook_path  = pair[1]
      display_name   = local.notebook_configs[pair[1]].display_name
      content_file   = local.notebook_configs[pair[1]].content_file
      ipynb_file     = local.notebook_configs[pair[1]].ipynb_file
      platform_file  = local.notebook_configs[pair[1]].platform_file
      folder_path    = local.notebook_configs[pair[1]].folder_path
      content        = file(local.notebook_configs[pair[1]].content_file)
    }
  }

  # First extract data lakehouse content
  raw_metadata = {
    for k, v in local.notebook_map : k => (
      can(regex("(?m)^\\s*# META\\s+\"default_lakehouse_name\":\\s*\"([^\"]+)\"", v.content)) ?
      regex("(?m)^\\s*# META\\s+\"default_lakehouse_name\":\\s*\"([^\"]+)\"", v.content)[0] :
      can(regex("(?m)^\\s*-- META\\s+\"default_lakehouse_name\":\\s*\"([^\"]+)\"", v.content)) ?
      regex("(?m)^\\s*-- META\\s+\"default_lakehouse_name\":\\s*\"([^\"]+)\"", v.content)[0] :
      "null"
    )
  }

  # Extract environment ID from notebook content
  environment_metadata = {
    for k, v in local.notebook_map : k => (
      can(regex("(?m)^\\s*# META\\s+\"environmentId\":\\s*\"([^\"]+)\"", v.content)) ?
      regex("(?m)^\\s*# META\\s+\"environmentId\":\\s*\"([^\"]+)\"", v.content)[0] :
      can(regex("(?m)^\\s*-- META\\s+\"environmentId\":\\s*\"([^\"]+)\"", v.content)) ?
      regex("(?m)^\\s*-- META\\s+\"environmentId\":\\s*\"([^\"]+)\"", v.content)[0] :
      "null"
    )
  }

  # Parse JSON and get lakehouse name
  notebook_metadata_map = {
    for k, v in local.notebook_map : k => {
      notebook_metadata = local.raw_metadata[k]
      lakehouse_name = try(
        local.raw_metadata[k],
        "null"
      )
    }
  }

  # Create combined environment lookup
  all_environments = {
    for k, v in local.notebook_map : k => {
      # Get subdomain environments for this workspace
      subdomain_envs = {
        for env_key, env in var.subdomain_environment_ids :
        env.logical_id => env.id
        if startswith(env_key, v.workspace_name)
      }
      # Get main environment
      main_env = {
        (var.environment_ids[v.workspace_name].logical_id) = var.environment_ids[v.workspace_name].id
      }
    }
  }

  final_notebook_map = {
    for k, v in local.notebook_map : k => merge(v, local.notebook_metadata_map[k], {
      environment_id = try(
        # First try to find matching environment from combined environments
        lookup(
          merge(
            local.all_environments[k].subdomain_envs,
            local.all_environments[k].main_env
          ),
          local.environment_metadata[k],
          # If no match found, default to workspace default environment
          "00000000-0000-0000-0000-000000000000"
        )
      )
    })
  }
}

output "notebook_platform_files" {
    value = local.platform_files
}
output "ellie_excluded_notebooks" {
    value = var.excluded_notebooks
}

# resource "null_resource" "create_notebooks" {
#   for_each = local.final_notebook_map

#   triggers = {

#     timestamp  = timestamp()
#   }
 
#   provisioner "local-exec" {
#     command = join(" ", compact([
#       "& '${path.root}/../../pipelines/scripts/Update-NotebookDependencies.ps1'",
#       "-KeyVaultName '${var.keyvault_name}'",
#       each.value.lakehouse_name != "null" ? "-LakehouseName '${each.value.lakehouse_name}'" : null,
#       each.value.lakehouse_name != "null" ? "-LakehouseId '${var.lakehouse_ids[each.value.workspace_name][each.value.lakehouse_name]}'" : null,
#       "-WorkspaceId '${each.value.workspace_id}'",
#       "-EnvironmentId '${each.value.environment_id}'",
#       "-EnvironmentIdPython '${var.environment_ids[each.value.workspace_name].id}'",
#       "-NotebookPath '${each.value.content_file}'"
#     ]))
#     interpreter = ["PowerShell", "-Command"]
#     working_dir = path.root
#   }

# }

# # Create notebooks using null_resource with PowerShell script
# resource "null_resource" "notebook" {
#   for_each = local.final_notebook_map

#   triggers = {
#     timestamp  = timestamp()
#   }

#   # Single provisioner that handles both create and update logic
#   provisioner "local-exec" {
#     command = join(" ", compact([
#       "& {",
#       "& '${path.root}/../../pipelines/scripts/Invoke-NotebookManagement.ps1'",
#       "-Action 'CreateOrUpdate'",
#       "-WorkspaceId '${each.value.workspace_id}'",
#       "-DisplayName '${each.value.display_name}'",
#       "-IpynbFile '${each.value.ipynb_file}'",
#       "-PlatformFile '${each.value.platform_file}'",
#       var.folder_hierarchy != null ? "-FolderHierarchy '${var.folder_hierarchy}'" : "",
#       each.value.folder_path != null ? "-FolderPath '${each.value.folder_path}'" : "",
#       each.value.environment_id != "00000000-0000-0000-0000-000000000000" ? "-EnvironmentId '${each.value.environment_id}'" : "",
#       each.value.lakehouse_name != "null" ? "-LakehouseName '${each.value.lakehouse_name}'" : "",
#       each.value.lakehouse_name != "null" ? "-LakehouseId '${var.lakehouse_ids[each.value.workspace_name][each.value.lakehouse_name]}'" : "",
#       "}"
#     ]))
#     interpreter = ["PowerShell", "-Command"]
#     working_dir = path.root
#   }

#   provisioner "local-exec" {
#     when = destroy
#     command = "Write-Host 'removed from Terraform state but left intact in Fabric workspace for incremental process'"
#     interpreter = ["PowerShell", "-Command"]
#     on_failure = continue
#   }

#   depends_on = [
#     null_resource.create_notebooks
#   ]
# }