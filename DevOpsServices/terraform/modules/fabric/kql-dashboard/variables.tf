variable "workspace_ids" {
  type        = map(string)
  description = "Map of workspace names to IDs"
}

variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}
