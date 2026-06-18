variable "workspace_ids" {
  type        = map(string)
  description = "Map of workspace names to IDs"
}

variable "default_spark_environment_name" {
  description = "Default Spark environment name"
  type        = string 
}

variable "default_spark_runtime" {
  description = "Default Spark runtime"
  type        = string 
}
