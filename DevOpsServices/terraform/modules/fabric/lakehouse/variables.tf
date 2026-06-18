
variable "workspace_ids" {
  type        = map(string)
  description = "Map of workspace names to IDs"
}

variable "shortcuts" { 
  description = "List of shortcut definitions for lakehouse items" 
  type = string 
  default = "[]"
}

variable "enable_lakehouse_schemas" {
  type        = bool
  description = "Enable lakehouse schemas"
  default     = true
}

variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}