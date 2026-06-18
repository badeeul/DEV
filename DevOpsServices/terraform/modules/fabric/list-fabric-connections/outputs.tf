
locals {
  # Clean up the raw JSON by removing BOM, extra spaces and newlines
  connections_raw_clean = replace(
    replace(
      replace(
        replace(local.connections_raw, "\ufeff", ""), # Remove BOM
        "\r\n", ""                                    # Remove Windows newlines
      ),
      "\n", "" # Remove Unix newlines
    ),
    "\\s+", " " # Collapse multiple spaces
  )

  # Parse the cleaned JSON
  connections_parsed = jsondecode(local.connections_raw_clean)

  # Create array
  connections = local.connections_parsed
}

# Debug outputs
output "connections" {
  description = "List of all Fabric connections"
  value       = local.connections
}

output "connections_raw_clean" {
  description = "Cleaned JSON string"
  value       = local.connections_raw_clean
}


# output "connection_names" {
#   description = "List of Fabric connection display names"
#   value       = [for conn in local.connections : conn.displayName]
#   depends_on  = [null_resource.get_fabric_connections]
# }

# output "connection_ids" {
#   description = "Map of connection display names to IDs"
#   value       = { for conn in local.connections : conn.displayName => conn.id }
#   depends_on  = [null_resource.get_fabric_connections]
# }

# output "connection_list" {
#   description = "Formatted list of connections with their IDs"
#   value = [
#     for conn in local.connections : {
#       display_name = conn.displayName
#       id          = conn.id
#     }
#   ]
#   depends_on  = [null_resource.get_fabric_connections]
# }


