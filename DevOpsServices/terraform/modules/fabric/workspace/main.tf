terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

# Get existing workspaces
data "fabric_workspaces" "existing" {
  provider = fabric
}

locals {

  pep_list = var.peps == null ? [] : jsondecode(var.peps)

  # Dynamically build endpoints based on resource references
  private_endpoints_config = [
    for pep in local.pep_list :
      {
        name               = pep.subresourceType
        target_resource_id = pep.resourceId
        target_subresource = pep.subresourceType
        allowed            = pep.allowed
      } if pep.resourceId != null && pep.subresourceType != null && pep.resourceId != "" && pep.subresourceType != ""
  ]

  # Create a map of endpoints to create for each workspace
private_endpoints_map = flatten([
  for workspace_name in var.workspace_names : [
    for endpoint in local.private_endpoints_config : {
      workspace_name     = workspace_name
      endpoint_name      = substr(
        "${replace(replace(workspace_name, " ", "-"), "/", "-")}-${element(split("/", endpoint.target_resource_id), length(split("/", endpoint.target_resource_id)) - 1)}",
        0,
        64
      )
      target_resource_id = endpoint.target_resource_id
      target_subresource = endpoint.target_subresource
      request_message    = "Please approve this Fabric managed private endpoint subresource type ${element(split("/", endpoint.target_resource_id), length(split("/", endpoint.target_resource_id)) - 1)}"
      allowed            = endpoint.allowed
      force_deletion_ppe = var.force_deletion_ppe
    }
  ]
])

  # Create an ordered list of endpoints instead of a map
  private_endpoints_list = [
    for endpoint in local.private_endpoints_map : {
      workspace_name       = endpoint.workspace_name
      endpoint_name        = endpoint.endpoint_name
      target_resource_id   = endpoint.target_resource_id
      target_subresource   = endpoint.target_subresource
      request_message      = endpoint.request_message
      key                  = "${endpoint.workspace_name}-${endpoint.endpoint_name}"
      allowed              = endpoint.allowed
      force_deletion_ppe   = endpoint.force_deletion_ppe
    }
  ]  

 # Create a map of workspaces to their IDs (without duplicates)
  workspace_id_map = {
    for name in var.workspace_names : name => (
        var.workspace_id
    )
  }
}

# Create workspaces that don't exist
# resource "fabric_workspace" "this" {
#   for_each = local.workspaces_to_create
#   provider     = fabric
#   display_name = each.key
#   capacity_id  = var.capacity_id

#    lifecycle {
#     ignore_changes = [ 
#       display_name,
#       capacity_id
#     ]  # Ignore changes to these fields
#     prevent_destroy = false   # Protected in production
#     create_before_destroy = true
#   }
# }

# resource "fabric_workspace_role_assignment" "admins-group" {
#   for_each = {
#     for pair in setproduct(var.workspace_names, var.admin_group_principal_ids) :
#     "${pair[0]}-${pair[1]}" => {
#       workspace_name = pair[0]
#       principal_id   = pair[1]
#     }
#   }

#   workspace_id   =  var.workspace_id
#   principal = {
#     id   = each.value.principal_id
#     type = var.group_principal_type
#   }
#   role           = "Admin"
# }

# resource "fabric_workspace_role_assignment" "viewers-group" {
#   for_each = length(var.viewer_group_principal_ids) > 0 ? {
#     for pair in setproduct(var.workspace_names, var.viewer_group_principal_ids) :
#     "${pair[0]}-${pair[1]}" => {
#       workspace_name = pair[0]
#       principal_id   = pair[1]
#     }
#   } : {}

#   workspace_id   =  var.workspace_id
#   principal = {
#     id   = each.value.principal_id
#     type = var.group_principal_type
#   }
#   role           = "Viewer"
# }

# resource "fabric_workspace_role_assignment" "contributor-group" {
#   for_each = length(var.contributor_group_principal_ids) > 0 ? {
#     for pair in setproduct(var.workspace_names, var.contributor_group_principal_ids) :
#     "${pair[0]}-${pair[1]}" => {
#       workspace_name = pair[0]
#       principal_id   = pair[1]
#     }
#   } : {}

#   workspace_id   =  var.workspace_id
#   principal = {
#     id   = each.value.principal_id
#     type = var.group_principal_type
#   }
#   role           = "Contributor"
# }


# resource "fabric_workspace_role_assignment" "admins-sp" {
#   for_each = {
#     for pair in setproduct(var.workspace_names, var.admin_sp_principal_ids) :
#     "${pair[0]}-${pair[1]}" => {
#       workspace_name = pair[0]
#       principal_id   = pair[1]
#     }
#   }

#   workspace_id   =  var.workspace_id
#   principal = {
#     id   = each.value.principal_id
#     type = var.contributor_principal_type
#   }
#   role           = "Admin"
# }

# resource "fabric_workspace_role_assignment" "user-sp" {
#   for_each = {
#     for pair in setproduct(var.workspace_names, var.admin_user_principal_ids) :
#     "${pair[0]}-${pair[1]}" => {
#       workspace_name = pair[0]
#       principal_id   = pair[1]
#     }
#   }

#   workspace_id   = var.workspace_id
#   principal = {
#     id   = each.value.principal_id
#     type = var.user_principal_type
#   }
#   role           = "Admin"
# }

# Create all private endpoints using a single script execution that handles the sequencing internally
resource "null_resource" "create_all_private_endpoints" {
  count = length(local.private_endpoints_list) > 0 ? 1 : 0
 
  triggers = {
    # Include all endpoint details as JSON in a single trigger
    endpoints_json = jsonencode(local.private_endpoints_list)
    # Add workspace IDs as a separate map
    workspace_ids_json = jsonencode(local.workspace_id_map)
    # Add a timestamp to ensure the resource is always evaluated
    eval_time = timestamp()
  }

  # Create private endpoints using PowerShell script
  provisioner "local-exec" {
    command = <<-EOT
      # Create a temporary JSON file with all endpoint data
      $endpointsJson = '${jsonencode(local.private_endpoints_list)}'
      $endpointsData = $endpointsJson | ConvertFrom-Json
     
      $workspaceIdsJson = '${jsonencode(local.workspace_id_map)}'
      $workspaceIds = $workspaceIdsJson | ConvertFrom-Json
     
      # Process endpoints sequentially
      foreach ($endpoint in $endpointsData) {
          Write-Host "Processing endpoint: $($endpoint.endpoint_name) for workspace: $($endpoint.workspace_name)"
         
          $workspaceId = $workspaceIds."$($endpoint.workspace_name)"
         
          if ($endpoint.allowed -eq $true) {
            # Create/Update endpoint if allowed is true
            Write-Host "Creating/updating endpoint: $($endpoint.endpoint_name) for workspace: $($endpoint.workspace_name)"

            # Call the script for each endpoint, waiting for completion before moving to the next one
            & "${path.root}/../../pipelines/scripts/Create-ManagedPrivateEndpoints.ps1" `
              -WorkspaceId $workspaceId `
              -EndpointName $endpoint.endpoint_name `
              -TargetResourceId $endpoint.target_resource_id `
              -TargetSubresourceType $endpoint.target_subresource `
              -RequestMessage $endpoint.request_message `
              -Delete:$endpoint.force_deletion_ppe `
              -Verbose
          } else {
              # Delete endpoint if allowed is false
              Write-Host "Deleting endpoint: $($endpoint.endpoint_name) from workspace: $($endpoint.workspace_name) (allowed=false)"
             
              & "${path.root}/../../pipelines/scripts/Create-ManagedPrivateEndpoints.ps1" `
                -WorkspaceId $workspaceId `
                -EndpointName $endpoint.endpoint_name `
                -TargetResourceId $endpoint.target_resource_id `
                -TargetSubresourceType $endpoint.target_subresource `
                -RequestMessage "Delete request - allowed set to false" `
                -Delete `
                -Verbose                    
          }
          # Add a brief pause between endpoints to avoid API contention
          Start-Sleep -Seconds 5
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.root
  }
}

