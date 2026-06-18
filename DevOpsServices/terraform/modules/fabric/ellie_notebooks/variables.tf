variable "workspace_ids" {
  description = "Map of workspace names to workspace IDs"
  type        = map(string)
}

variable "lakehouse_ids" {
  description = "Map of workspace names to lakehouse names to lakehouse IDs"
  type        = map(map(string))
  default     = {}
}
