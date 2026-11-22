variable "name" {
  description = "Name prefix for this pipeline's resources"
  type        = string
}

variable "prefix" {
  description = "Prefix of the Glue databases (<prefix>_bronze, <prefix>_silver); no hyphens"
  type        = string
  default     = "dms_stream"
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

variable "transform_source" {
  description = "Path of the transform Lambda's source file"
  type        = string
}

variable "kinesis_shards" {
  description = "Shards of the Kinesis stream (1 MB/s or 1000 records/s of writes each)"
  type        = number
  default     = 1
}

variable "buffer_seconds" {
  description = "Firehose buffer interval: how long changes wait before an Iceberg commit (the main latency knob)"
  type        = number
  default     = 60
}

variable "buffer_mb" {
  description = "Firehose buffer size in MiB; a full buffer is delivered before the interval ends"
  type        = number
  default     = 64
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every IAM role"
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the Lambda and Firehose logs"
  type        = number
  default     = 7
}
