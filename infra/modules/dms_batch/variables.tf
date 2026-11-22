variable "name" {
  description = "Name prefix for this pipeline's resources"
  type        = string
}

variable "prefix" {
  description = "Prefix of the Glue databases (<prefix>_bronze, <prefix>_silver); no hyphens"
  type        = string
  default     = "dms_batch"
}

variable "tables" {
  description = "Source tables and their columns, from the lake module"
  type        = map(list(object({ name = string, type = string })))
}

variable "source_schema" {
  description = "PostgreSQL schema of the source tables"
  type        = string
}

variable "bucket" {
  description = "Lake bucket name"
  type        = string
}

variable "bucket_arn" {
  description = "Lake bucket ARN"
  type        = string
}

variable "replication_instance_arn" {
  description = "Shared DMS replication instance"
  type        = string
}

variable "source_endpoint_arn" {
  description = "Shared DMS source endpoint"
  type        = string
}

variable "dms_trust_policy_json" {
  description = "Trust policy for DMS service roles"
  type        = string
}

variable "merge_script_source" {
  description = "Path of the Glue job script"
  type        = string
}

variable "cdc_batch_seconds" {
  description = "DMS writes a CDC file at least this often (seconds)"
  type        = number
  default     = 60
}

variable "cdc_min_file_kb" {
  description = "DMS writes a CDC file once it reaches this size (KB), even before the interval"
  type        = number
  default     = 32000
}

variable "schedule" {
  description = "When the merge job runs (Glue cron, UTC); 5 minutes at the most often"
  type        = string
  default     = "cron(0/15 * * * ? *)"
}

variable "glue_workers" {
  description = "G.1X workers of the merge job"
  type        = number
  default     = 2
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every IAM role"
  type        = string
}
