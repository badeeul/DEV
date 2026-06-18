# seems not to be used anymore, but keeping it commented out for reference
output "lakehouse_ids" {
  value = {
    for ws_name in keys(var.workspace_ids) : ws_name => {
      for lh_config in values(local.lakehouse_configs) : lh_config.display_name =>
      try( data.local_file.lakehouse_ids["${ws_name}-${lh_config.display_name}"].content, null)
    }
  }
}

# output "lakehouses" {
#   value =  data.fabric_lakehouses.all_lakehouses
# }

output "merged_shortcuts" {
  description = "List of merged shortcuts with configuration from both variable and file sources"
  value       = local.merged_shortcuts
}

output "lakehouse_map" {
  description = "Map of lakehouse names to workspace IDs"
  value       = local.lakehouse_map
}

output "lakehouse_configs" {
  description = "Lakehouse configurations"
  value       = local.lakehouse_configs
}

output "expected_keys" {
  description = "List of expected keys in the shortcuts variable"
  value       = keys(local.lakehouse_map)
}