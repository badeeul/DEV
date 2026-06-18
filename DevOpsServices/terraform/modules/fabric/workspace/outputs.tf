output "workspace_ids" {
  value = {
    for name in var.workspace_names : name => var.workspace_id
  }
}