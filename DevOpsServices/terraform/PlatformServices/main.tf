
provider "azurerm" {
  
  features {}
}

terraform {


  backend "azurerm" { 
  }
  
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

provider "fabric" {
  alias   = "sp_auth"
  use_cli = false

  preview = true
}

# module "fabric_connections" {
#   source = "./../modules/fabric/list-fabric-connections"

#   providers = {
#     fabric = fabric.sp_auth
#   }
# }

module "fabric_workspace" {
  source = "./../modules/fabric/workspace"

  providers = {
    fabric = fabric.sp_auth
  }
  workspace_names           = var.workspace_names
  capacity_id               = var.capacity_id
  admin_group_principal_ids = var.admin_group_principal_ids
  viewer_group_principal_ids = var.viewer_group_principal_ids  
  admin_sp_principal_ids    = var.admin_sp_principal_ids
  contributor_group_principal_ids = var.contributor_group_principal_ids
  admin_user_principal_ids  = var.admin_user_principal_ids
  workspace_id = var.workspace_id
  force_deletion_ppe = var.force_deletion_ppe
  peps = var.peps
}

locals {
  base_path      = "${path.root}/../../../src/fabric"
  platform_files = try(fileset(local.base_path, "**/*.Environment/.platform"), [])
  has_platform_files = length(local.platform_files) > 0

  # Check for Ellie files
  ellie_base_path        = "${path.root}/../../../src/ellie"
  all_ellie_platform_files = try(fileset(local.ellie_base_path, "**/*.Notebook/*.platform"), [])
  ellie_platform_files = [
    for platform_file in local.all_ellie_platform_files : 
      "${jsondecode(file("${path.root}/../../../src/ellie/${platform_file}")).metadata.displayName}.Notebook" # Add .Notebook to the name
  ]
  
  has_ellie_files        = length(local.ellie_platform_files) > 0
}

output "ellie_platform_files" {
  value = local.ellie_platform_files
  
}


# module "spark_workspace_settings" {
#   count = local.has_platform_files ? 1 : 0

#  source = "./../modules/fabric/environment-workspace-settings"
#   providers = {
#     fabric = fabric.sp_auth
#   }
#   workspace_ids = module.fabric_workspace.workspace_ids
#   default_spark_environment_name = var.default_spark_environment_name
#   default_spark_runtime = var.default_spark_runtime
#   depends_on = [
#       module.fabric_workspace
#     ]  
# }

module "lakehouse_names" {
  source = "./../modules/fabric/lakehouse"

  providers = {
    fabric = fabric.sp_auth
  }

  shortcuts = var.shortcuts
  workspace_ids   = module.fabric_workspace.workspace_ids
  folder_hierarchy = var.folder_hierarchy

  depends_on = [ module.fabric_workspace ]
}


# module "ellie_notebooks" {
#   count = local.has_ellie_files ? 1 : 0
#   source = "./../modules/fabric/ellie_notebooks"
#   providers = {
#     fabric = fabric.sp_auth
#   }
#   workspace_ids   = module.fabric_workspace.workspace_ids
#   lakehouse_ids   = module.lakehouse_names.lakehouse_ids
#   depends_on = [
#     module.fabric_workspace,    
#     module.lakehouse_names
#   ]
# }
