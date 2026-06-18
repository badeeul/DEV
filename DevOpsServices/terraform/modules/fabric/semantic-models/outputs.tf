
# This file contains sample output values for the workspace to view model_ids format
# workspace_names = ["Sales", "Marketing"]

# model_ids = {
#   "Sales" = "33333333-3333-3333-3333-333333333333"      # ID of Audit Model in Sales workspace
#   "Marketing" = "44444444-4444-4444-4444-444444444444"  # ID of Audit Model in Marketing workspace
# }


output "model_ids" {
  value = {
    for ws_name, ws_id in var.workspace_ids : ws_name =>
    contains([for m in local.existing_models : m.model_name if m.workspace_name == ws_name], var.model_name) ?
    [for sm in data.fabric_semantic_models.existing[ws_name].values : sm.id if sm.display_name == var.model_name][0] :
    fabric_semantic_model.this[ws_name].id
  }
}
