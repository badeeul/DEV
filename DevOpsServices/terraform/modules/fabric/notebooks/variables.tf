
variable "workspace_ids" {
  type = map(string)
}

variable "keyvault_name" {
  type = string
}

variable "lakehouse_ids" {
  type        = map(map(string))
  description = "Map of workspace names to lakehouse names to IDs"
}

variable "environment_ids" {
  type = map(object({
    id = string
    display_name = string
    logical_id = string
  }))
  description = "Map of workspace names to environment IDs"
}

variable "subdomain_environment_ids" {
  description = "Map of workspace names to environment details including IDs and logical IDs"
  type = map(object({
    id = string
    display_name = string
    logical_id = string
  }))
}

variable "excluded_notebooks" {
  description = "List of notebook names to exclude from processing"
  type        = list(string)
}

variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}
