# Everything this repo takes from outside: source-app's contract (the database and
# the network it lives in) and main-terraform's permissions boundary, both read from
# SSM so this repo never depends on another stack's state. source-app must be up.

locals {
  contract_keys = [
    "contract_version",
    "logical_replication_enabled",
    "vpc_id",
    "db_instance_id",
    "db_instance_arn",
    "db_endpoint",
    "db_port",
    "db_name",
    "db_schema",
    "db_engine",
    "db_security_group_id",
    "db_admin_secret_arn",
    "db_app_secret_arn",
  ]

  contract = { for k, p in data.aws_ssm_parameter.contract : k => p.insecure_value }
}

data "aws_ssm_parameter" "contract" {
  for_each = toset(local.contract_keys)

  name = "${var.contract_prefix}/${each.key}"
}

data "aws_ssm_parameter" "public_subnet_ids" {
  name = "${var.contract_prefix}/public_subnet_ids"
}

data "aws_ssm_parameter" "app_role_boundary_arn" {
  name = "${var.base_ssm_prefix}/iam/app_role_boundary_arn"
}

# Fails the plan, before anything is created, when source-app publishes a contract
# this repo wasn't written for.
resource "terraform_data" "contract_check" {
  input = local.contract.contract_version

  lifecycle {
    precondition {
      condition     = local.contract.contract_version == var.contract_version
      error_message = "source-app publishes contract v${local.contract.contract_version}; this repo expects v${var.contract_version}."
    }

    precondition {
      condition     = local.contract.logical_replication_enabled == "true" && local.contract.db_engine == "postgres"
      error_message = "The source must be RDS for PostgreSQL with logical replication enabled."
    }
  }
}
