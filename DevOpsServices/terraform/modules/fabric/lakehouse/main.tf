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
  platform_files = fileset("${path.root}/../../../src/fabric", "**/*.Lakehouse/.platform")
 
  # Output for debugging
  # debug_info = {
  #   root_path   = local.debug_root
  #   found_files = toset(local.platform_files)
  # }

  # Filter out Curated and Product lakehouses
  filtered_platform_files = [
    for file in local.platform_files : file
    if !can(regex(".*(den_lhw_pdi_001_curated\\.Lakehouse|den_lhw_pdi_001_raw\\.Lakehouse)", file))
  ]

  # Read and parse lakehouse platform files
  lakehouse_configs = {
    for platform_file in local.filtered_platform_files : dirname(platform_file) => {
      display_name = "${jsondecode(file("${path.root}/../../../src/fabric/${platform_file}")).metadata.displayName}"
      folder_path = "${dirname(platform_file)}"
    }
  }

  # Map workspace names to IDs
  workspace_map = {
    for name, id in var.workspace_ids : name => id
  }

  # Create map keys for for_each using filtered platform files
  lakehouse_map = {
    for pair in setproduct(keys(local.workspace_map), values(local.lakehouse_configs)) :
    "${pair[0]}-${pair[1].display_name}" => {
      workspace_name = pair[0]
      workspace_id   = local.workspace_map[pair[0]]
      lakehouse_name = pair[1].display_name
      folder_path    = pair[1].folder_path
    }
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

  # Process shortcuts from variable - handle string or list input
  shortcuts_list = var.shortcuts == "" ? [] : jsondecode(var.shortcuts)

  # Create normalized variable shortcuts (all names lowercase for easier matching)
  normalized_variable_shortcuts = {
    for shortcut in local.shortcuts_list :
    lower(trimspace(shortcut.name)) => {
      original_name = trimspace(shortcut.name)
      shortcut_name = trimspace(shortcut.name)
      lakehouse_name = trimspace(shortcut.lakehouse)
      workspace_name = trimspace(shortcut.workspace)
    }
  }

  # Find all shortcuts.metadata.json files
  shortcut_files = fileset("${path.root}/../../../src/fabric", "**/*.Lakehouse/shortcuts.metadata.json")
 
  # Create a map of lakehouse to shortcuts
  lakehouse_shortcuts = {
    for shortcut_file in local.shortcut_files : dirname(shortcut_file) => {
      shortcuts = jsondecode(file("${path.root}/../../../src/fabric/${shortcut_file}")),
      lakehouse_path = dirname(shortcut_file),
      consumer_lakehouse_name = jsondecode(file("${path.root}/../../../src/fabric/${dirname(shortcut_file)}/.platform")).metadata.displayName,
      consumer_workspace_name = keys(var.workspace_ids)[0]
    }
  }

  # Extract all file shortcuts and normalize them by name
  all_file_shortcuts = flatten([
    for shortcut_lakehouse, shortcut_data in local.lakehouse_shortcuts : [
      for file_shortcut in shortcut_data.shortcuts : {
        shortcut_name = file_shortcut.name
        normalized_name = lower(file_shortcut.name)
        consumer_lakehouse_name = shortcut_data.consumer_lakehouse_name
        consumer_workspace_name = shortcut_data.consumer_workspace_name
        shortcut_path = file_shortcut.path
        target_type = file_shortcut.target.type
        target_path = file_shortcut.target.oneLake.path
        file_target_item_id = file_shortcut.target.oneLake.itemId
        file_target_workspace_id = file_shortcut.target.oneLake.workspaceId
        source = "file"
      }
    ]
  ])

  # Create a file shortcut lookup map by normalized name
  file_shortcut_lookup = {
    for shortcut in local.all_file_shortcuts :
    shortcut.normalized_name => shortcut
  }
 
  # Create merged shortcuts by matching variable shortcuts with file shortcuts
  merged_shortcuts = [
    for normalized_name, var_shortcut in local.normalized_variable_shortcuts :
    # Only include shortcuts that have a match in file_shortcut_lookup
    contains(keys(local.file_shortcut_lookup), normalized_name) ?
    {
      # Basic info from variable
      shortcut_name = var_shortcut.shortcut_name
      lakehouse_name = var_shortcut.lakehouse_name
      workspace_name = var_shortcut.workspace_name
   
      # Consumer information (where the shortcut will be created)
      consumer_lakehouse_name = local.file_shortcut_lookup[normalized_name].consumer_lakehouse_name
      consumer_workspace_name = local.file_shortcut_lookup[normalized_name].consumer_workspace_name
   
      # File configuration from the file shortcut
      shortcut_path = local.file_shortcut_lookup[normalized_name].shortcut_path
      target_type = local.file_shortcut_lookup[normalized_name].target_type
      target_path = local.file_shortcut_lookup[normalized_name].target_path
   
      # Target information - use variable shortcut values as per requirements
      # These represent the source lakehouse and workspace
      target_item_id = var_shortcut.lakehouse_name
      target_workspace_id = var_shortcut.workspace_name
   
      # Original file target IDs for reference
      file_target_item_id = local.file_shortcut_lookup[normalized_name].file_target_item_id
      file_target_workspace_id = local.file_shortcut_lookup[normalized_name].file_target_workspace_id
   
      # Track match status
      has_file_match = true
      source = "merged"
    } : null  # Return null for shortcuts without a match
  ]

  merged_shortcuts_simplicity =[
    for normalized_name, shortcut in local.file_shortcut_lookup :
    {
      shortcut_name = shortcut.shortcut_name

      lakehouse_name = shortcut.consumer_lakehouse_name
      workspace_name = shortcut.consumer_workspace_name

      consumer_lakehouse_name = shortcut.consumer_lakehouse_name
      consumer_workspace_name = shortcut.consumer_workspace_name

      shortcut_path = shortcut.shortcut_path
      target_type = shortcut.target_type
      target_path = shortcut.target_path
      target_item_id = shortcut.consumer_lakehouse_name
      target_workspace_id = shortcut.consumer_workspace_name
      file_target_item_id = shortcut.file_target_item_id
      file_target_workspace_id = shortcut.file_target_workspace_id
      has_file_match = true
      source = shortcut.source
    }
  ]

#  merge merged_shortcuts and merged_shortcuts_simplicity, giving precedence to merged_shortcuts

  combined_shortcuts = concat(local.merged_shortcuts, local.merged_shortcuts_simplicity)
  
  filtered_merged_shortcuts = [
    for item in local.combined_shortcuts :
    item if item != null
  ]

  all_shortcut_name = [
    for shortcut in local.filtered_merged_shortcuts : shortcut.shortcut_name
  ]

  shortcut_names_string = join(", ", local.all_shortcut_name)
}

# Create lakehouses using null_resource with PowerShell script
# resource "null_resource" "lakehouse" {
#   for_each = local.lakehouse_map

#   triggers = {

#     timestamp = timestamp()  # Force this to always run
#   }

#   # Single provisioner that handles both create and update logic
#   provisioner "local-exec" {
#     command = join(" ", compact([
#       "& {",
#       "$result = & '${path.root}/../../pipelines/scripts/Invoke-LakehouseManagement.ps1'",
#       "-Action 'CreateOrUpdate'",
#       "-WorkspaceId '${each.value.workspace_id}'",
#       "-DisplayName '${each.value.lakehouse_name}'",
#       var.folder_hierarchy != null ? "-FolderHierarchy '${var.folder_hierarchy}'" : "",
#       each.value.folder_path != null ? "-FolderPath '${each.value.folder_path}'" : "",
#       "; if ($result) { $first_result = if ($result -is [array]) { $result[0] } else { $result }; $env_id = ($first_result | ConvertFrom-Json).id.Trim(); Set-Content -Path '${path.root}/.terraform/lakehouse_${replace(replace(each.key, "-", "_"), " ", "_")}_id.txt' -Value $env_id -NoNewline -Force }",
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

# }

data "local_file" "lakehouse_ids" {
  for_each = local.lakehouse_map
  filename = "${path.root}/.terraform/lakehouse_${replace(replace(replace(each.key, "-", "_"), " ", "_"), "/", "_")}_id.txt"
}


resource "null_resource" "create_shortcuts" {
  # Create shortcuts using name-based lookup for better plan-time compatibility
  for_each = {
    for idx, shortcut in local.filtered_merged_shortcuts :
    "${idx}" => shortcut
  }

  triggers = {

    timestamp = timestamp()  # Force this to always run
  }

  provisioner "local-exec" {
    command = join(" ", compact([
      "& {",
      "$env:VALID_SHORTCUT_NAMES = '${local.shortcut_names_string}';",
      "& '${path.root}/../../pipelines/scripts/Invoke-ShortcutCreation.ps1'",
      "-ConsumerWorkspaceName '${each.value.consumer_workspace_name != null ? each.value.consumer_workspace_name : keys(var.workspace_ids)[0]}'",
      "-ConsumerLakehouseName '${each.value.consumer_lakehouse_name != null ? each.value.consumer_lakehouse_name : each.value.shortcut_name}'",
      "-ShortcutName '${each.value.shortcut_name}'",
      "-ShortcutPath '${each.value.shortcut_path}'",
      "-TargetWorkspaceName '${each.value.target_workspace_id}'",
      "-TargetLakehouseName '${each.value.target_item_id}'",
      "-TargetPath '${each.value.target_path}'",
      "}"
    ]))
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.root
  }

}