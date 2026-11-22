variable "name" {
  description = "Name prefix for the ops resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC of the source database"
  type        = string
}

variable "db" {
  description = "The source database, from the contract"
  type = object({
    endpoint          = string
    port              = number
    name              = string
    schema            = string
    security_group_id = string
    admin_secret_arn  = string
    app_secret_arn    = string
  })
}

variable "dms_user" {
  description = "Database user the DMS tasks connect as"
  type        = string
}

variable "dms_secret_arn" {
  description = "Secret holding the DMS user's password"
  type        = string
}

variable "scripts" {
  description = "SQL scripts to run as one-off tasks: name => SQL"
  type        = map(string)
}

variable "image" {
  description = "Image with psql"
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17-alpine"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the execution role"
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the task logs"
  type        = number
  default     = 7
}
