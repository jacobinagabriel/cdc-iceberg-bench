# What both DMS pipelines share: one replication instance (each pipeline runs its own
# task on it) and one source endpoint. Each task opens its own replication slot.
#
# DMS also needs the account's fixed-name roles dms-vpc-role and
# dms-cloudwatch-logs-role, which main-terraform's bootstrap stack creates.

data "aws_region" "current" {}

# --- Source credentials -------------------------------------------------------------

# Generated at apply time and written write-only: the password never lands in the
# Terraform state or plan. db-setup sets the user's password from this secret.
ephemeral "random_password" "dms" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "source" {
  #checkov:skip=CKV_AWS_149:AWS managed key; a customer managed key adds cost and nothing for a synthetic database.
  #checkov:skip=CKV2_AWS_57:No rotation; the secret is recreated with the stack on every up.
  name                    = "${var.name}/dms-source"
  description             = "Connection of the DMS tasks to the source database (user ${var.dms_user})"
  recovery_window_in_days = 0 # lets the next up recreate the same name right after a down
}

resource "aws_secretsmanager_secret_version" "source" {
  secret_id = aws_secretsmanager_secret.source.id
  # The keys DMS reads from a source endpoint secret.
  secret_string_wo = jsonencode({
    username = var.dms_user
    password = ephemeral.random_password.dms.result
    host     = var.db.endpoint
    port     = var.db.port
  })
  # Bump to set a new password; db-setup picks it up on the next up.
  secret_string_wo_version = 1
}

data "aws_iam_policy_document" "dms_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      # Secrets Manager access goes through the regional DMS principal.
      identifiers = ["dms.amazonaws.com", "dms.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "secrets" {
  name                 = "${var.name}-dms-secrets"
  description          = "Lets DMS read the source endpoint's secret"
  assume_role_policy   = data.aws_iam_policy_document.dms_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.source.arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "source-secret"
  role   = aws_iam_role.secrets.id
  policy = data.aws_iam_policy_document.secrets.json
}

# --- Network ---------------------------------------------------------------------

# In the public subnets with a public IP and no inbound rules, like source-app's
# tasks: DMS reaches Kinesis, S3 and Secrets Manager through the internet gateway, so
# there is no NAT or interface endpoint to pay for.
resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id          = var.name
  replication_subnet_group_description = "Public subnets for the ${var.name} replication instance"
  subnet_ids                           = var.subnet_ids
}

resource "aws_security_group" "dms" {
  name        = "${var.name}-dms"
  description = "DMS replication instance: no inbound, outbound to the database and AWS APIs"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-dms" }
}

resource "aws_vpc_security_group_egress_rule" "dms_all" {
  #checkov:skip=CKV_AWS_382:DMS reaches Kinesis, S3 and Secrets Manager through the internet gateway (no NAT or endpoints, to keep idle cost at zero).
  security_group_id = aws_security_group.dms.id
  description       = "The database, Kinesis, S3 and Secrets Manager"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_dms" {
  security_group_id            = var.db.security_group_id
  description                  = "PostgreSQL from the ${var.name} DMS replication instance"
  ip_protocol                  = "tcp"
  from_port                    = var.db.port
  to_port                      = var.db.port
  referenced_security_group_id = aws_security_group.dms.id
}

# --- Replication instance and source endpoint -----------------------------------------

resource "aws_dms_replication_instance" "this" {
  #checkov:skip=CKV_AWS_89:Public IP with no inbound rules, so DMS reaches AWS APIs without a NAT; the security group admits nothing.
  #checkov:skip=CKV_AWS_212:AWS managed key; a customer managed key adds cost and nothing for a synthetic database.
  replication_instance_id     = var.name
  replication_instance_class  = var.instance_class
  allocated_storage           = var.allocated_storage
  publicly_accessible         = true
  multi_az                    = false
  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]
  auto_minor_version_upgrade  = true
  apply_immediately           = true
}

resource "aws_dms_endpoint" "source" {
  #checkov:skip=CKV_AWS_296:AWS managed key; a customer managed key adds cost and nothing for a synthetic database.
  endpoint_id                     = "${var.name}-source"
  endpoint_type                   = "source"
  engine_name                     = "postgres"
  database_name                   = var.db.name
  ssl_mode                        = "require" # the source sets rds.force_ssl=1
  secrets_manager_arn             = aws_secretsmanager_secret.source.arn
  secrets_manager_access_role_arn = aws_iam_role.secrets.arn

  postgres_settings {
    # Built into PostgreSQL, so the source needs no extension.
    plugin_name = "test-decoding"
    # No DDL capture: it would need an event trigger in the source database.
    capture_ddls = false
    # A WAL heartbeat keeps the slots moving while the source is idle, so they never
    # hold back WAL (on RDS, WAL a slot holds fills the disk).
    heartbeat_enable    = true
    heartbeat_schema    = "cdc_bench"
    heartbeat_frequency = 1
  }

  depends_on = [aws_iam_role_policy.secrets]
}
