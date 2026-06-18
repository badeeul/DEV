output "ellie_notebook_configs" {
  description = "Raw configuration details for Ellie notebooks"
  value       = local.notebook_configs
}

output "notebook_ids_list" {
  description = "List of all created notebook IDs"
  value = [
    for notebook in fabric_notebook.this : notebook.id
  ]
}