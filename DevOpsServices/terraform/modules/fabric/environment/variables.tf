variable "workspace_ids" {
  type        = map(string)
  description = "Map of workspace names to IDs"
}

variable "spark_compute" {
  description = "Spark compute configuration"
  type = string
}

 variable "folder_hierarchy" {
  description = "Folder hierarchy for the workspace"
  type        = string
  default     = "[]"
}