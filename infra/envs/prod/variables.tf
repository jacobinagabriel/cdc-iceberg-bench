variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "contract_prefix" {
  description = "Where source-app publishes its contract"
  type        = string
  default     = "/source-app/prod"
}

variable "base_ssm_prefix" {
  description = "Where main-terraform publishes the shared layer"
  type        = string
  default     = "/main-terraform/prod"
}

variable "dms_instance_class" {
  description = "DMS replication instance class, shared by both DMS tasks"
  type        = string
  default     = "dms.t3.medium"
}

variable "firehose_buffer_seconds" {
  description = "dms_stream: Firehose buffer interval before each Iceberg commit"
  type        = number
  default     = 60
}

variable "dms_s3_batch_seconds" {
  description = "dms_batch: how often DMS writes a CDC file"
  type        = number
  default     = 60
}

variable "batch_schedule" {
  description = "dms_batch: when the Glue merge job runs (Glue cron, UTC)"
  type        = string
  default     = "cron(0/15 * * * ? *)"
}
