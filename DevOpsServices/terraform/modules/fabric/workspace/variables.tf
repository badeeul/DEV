variable "workspace_names" {
  description = "List of workspaces"
  type        = list(string)
}

variable "system_assigned_identity" {
  description = "Flag to enable system assigned identity"
  type        = bool
  default     = false
}

variable "capacity_id" {
  description = "Fabric Capacity ID"
  type        = string
}

variable "admin_group_principal_ids" {
  type        = list(string)
  description = "List of principal IDs to assign Admin role"
}

variable "viewer_group_principal_ids" {
  description = "List of Azure AD Object IDs of the users who will be added as viewer to the workspace type Group"
  type        = list(string) 
}

variable "admin_sp_principal_ids" {
  type        = list(string)
  description = "List of principal IDs to assign Admin role"
}

variable "admin_user_principal_ids" {
  type        = list(string)
  description = "List of principal IDs to assign Admin role"
}

variable "contributor_group_principal_ids" {
  type        = list(string)
  description = "List of principal IDs to assign Contributor role"
}

variable "group_principal_type" {
  type        = string
  description = "Type of principals for admin role (User, Group, or ServicePrincipal)"
  default     = "Group"
}

variable "contributor_principal_type" {
  type        = string
  description = "Type of principals for member role (User, Group, or ServicePrincipal)"
  default     = "ServicePrincipal"
}

variable "user_principal_type" {
  type        = string
  description = "Type of principals for member role (User, Group, or ServicePrincipal)"
  default     = "User"
}

variable "peps" { 
  description = "List of PEP definitions for resource id and subresource type" 
  type = string
  default = "[]"
}

variable "force_deletion_ppe" {
  description = "Force deletion of Managed Private Endpoint"
  type        = bool
  default     = false  
}

variable "workspace_id" {
  description = "Workspace ID to be used in the module"
  type        = string
}

variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}