terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

data "fabric_semantic_models" "existing" {
  for_each     = var.workspace_ids
  provider     = fabric
  workspace_id = each.value
}

locals {
  model_path = "src/audit.SemanticModel"

  existing_models = flatten([
    for ws_name, ws_id in var.workspace_ids : [
      for sm in data.fabric_semantic_models.existing[ws_name].values : {
        workspace_name = ws_name
        model_name     = sm.display_name
      }
    ]
  ])

  models_to_create = {
    for ws_name, ws_id in var.workspace_ids : ws_name => ws_id
    if !contains([for m in local.existing_models : m.model_name if m.workspace_name == ws_name], var.model_name)
  }
}

resource "fabric_semantic_model" "this" {
  for_each                  = local.models_to_create
  provider                  = fabric
  workspace_id              = each.value
  display_name              = var.model_name
  definition_update_enabled = var.enable_definition_updates

  definition = {
    "model.bim" = {
      source = "${local.model_path}/model.bim"
      tokens = var.model_tokens
    }
    "definition.pbism" = {
      source = "${local.model_path}/definition.pbism"
    }
  }
}