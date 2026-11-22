output "vpc_id" {
  description = "VPC of the source database"
  value       = local.contract.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets (DMS and ECS tasks, public IP and no inbound rules)"
  value       = split(",", data.aws_ssm_parameter.public_subnet_ids.insecure_value)
}

output "db" {
  description = "The source database, from the contract"
  value = {
    instance_id       = local.contract.db_instance_id
    instance_arn      = local.contract.db_instance_arn
    endpoint          = local.contract.db_endpoint
    port              = tonumber(local.contract.db_port)
    name              = local.contract.db_name
    schema            = local.contract.db_schema
    security_group_id = local.contract.db_security_group_id
    admin_secret_arn  = local.contract.db_admin_secret_arn
    app_secret_arn    = local.contract.db_app_secret_arn
  }
}

output "app_role_boundary_arn" {
  description = "Permissions boundary every aws_iam_role in this repo must set"
  value       = data.aws_ssm_parameter.app_role_boundary_arn.insecure_value
}
