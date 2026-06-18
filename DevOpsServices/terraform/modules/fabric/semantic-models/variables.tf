variable "workspace_ids" {
  type        = map(string)
  description = "Map of workspace names to IDs"
}

variable "model_name" {
  type = string
}

variable "enable_definition_updates" {
  type    = bool
  default = false
}

variable "model_tokens" {
  type    = map(string)
  default = {}
}
