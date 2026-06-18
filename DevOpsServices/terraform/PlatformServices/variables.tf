
variable "environment" {
  description = "Azure Environment"
  type        = string
}

variable "workspace_names" {
  description = "List of workspaces"
  type        = list(string)
}

variable "capacity_id" {
  description = "Fabric Capacity ID"
  type        = string
}

variable "default_spark_environment_name" {
  description = "Default Spark environment name"
  type        = string  
}

variable "default_spark_runtime" {
  description = "Default Spark runtime"
  type        = string 
}

variable "admin_group_principal_ids" {
  description = "List of Azure AD Object IDs of the users who will be added as admins to the workspace type Group"
  type        = list(string)
}

variable "viewer_group_principal_ids" {
  description = "List of Azure AD Object IDs of the users who will be added as viewer to the workspace type Group"
  type        = list(string) 
}

variable "contributor_group_principal_ids" {
  type        = list(string)
  description = "List of Azure AD Object IDs of the users who will be added as contributor to the workspace type Group"
}

variable "admin_sp_principal_ids" {
  description = "List of Azure AD Object IDs of the users who will be added as admins to the workspace type Service Principal"
  type        = list(string)
}

variable "admin_user_principal_ids" {
  description = "List of Azure AD Object IDs of the users who will be added as admins to the workspace type User"
  type        = list(string)
}

variable "keyvault_name" {
  description = "Keyvault name"
  type        = string
}

variable "parent_domain_name" {
  description = "Parent domain name"
  type        = string
  default     = "DnA Platform Services"
}

variable "child_domain_name" {
  description = "Child domain name"
  type        = string
  default     = "DevOps Services"
}

variable "shortcuts" { 
  description = "List of shortcut definitions for lakehouse items" 
  type = string
  default = "[]"
}

variable "peps" { 
  description = "List of PEP definitions for resource id and subresource type" 
  type = string
  default = "[]"
}

variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}

variable "force_deletion_ppe" {
  description = "Force deletion of Managed Private Endpoint"
  type        = bool
  default     = false  
}

variable "spark_compute" {
  description = "Spark compute configuration"
  type = string
}

variable "workspace_id" {
  description = "Workspace ID to be used in the module"
  type        = string
}
