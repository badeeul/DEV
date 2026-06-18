
output "workspace_ids" {
  value = module.fabric_workspace.workspace_ids
}

# output "fabric_connections" {
#   value = module.fabric_connections.connections

# }

# output "environment_ids" {
#   value = module.environment.environment_ids
# }

# output "subdomain_environment_ids" {
#   value = module.environment_subdomain[0].subdomain_environment_ids
# }

# output "ellie_notebook_ids" {
#   value = length(module.ellie_notebooks) > 0 ? (try(module.ellie_notebooks[0].notebook_ids_list, [])) : [] 
# }


output "merged_shortcuts" {
  description = "List of merged shortcuts"
  value       = module.lakehouse_names.merged_shortcuts  
}

output "lakehouse_map" {
  description = "Map of lakehouse names to workspace IDs"
  value       = module.lakehouse_names.lakehouse_map
}

output "lakehouse_configs" {
  description = "Lakehouse configurations"
  value       = module.lakehouse_names.lakehouse_configs
}

output "expected_keys" {
  description = "List of expected keys in the shortcuts variable"
  value       = module.lakehouse_names.expected_keys
}