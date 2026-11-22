variable "name" {
  description = "Name prefix for the DMS resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC of the source database"
  type        = string
}

variable "subnet_ids" {
  description = "Public subnets for the replication instance (two AZs)"
  type        = list(string)
}

variable "db" {
  description = "The source database, from the contract"
  type = object({
    endpoint          = string
    port              = number
    name              = string
    security_group_id = string
  })
}

variable "dms_user" {
  description = "Database user the DMS tasks connect as (created by db-setup)"
  type        = string
}

variable "instance_class" {
  description = "DMS replication instance class; both tasks share it"
  type        = string
  default     = "dms.t3.medium"
}

variable "allocated_storage" {
  description = "Storage of the replication instance in GiB (task logs and cached changes)"
  type        = number
  default     = 50
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every IAM role"
  type        = string
}
