# One-off psql tasks against the source database (db-setup, db-teardown,
# source-counts), run by the deploy workflow. They use the public postgres image, so
# this repo needs no image of its own yet.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_ecs_cluster" "this" {
  #checkov:skip=CKV_AWS_65:Container Insights costs extra; the one-off tasks only need their logs.
  name = var.name
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:Logs of one-off SQL scripts; the default AWS-owned encryption is enough.
  #checkov:skip=CKV_AWS_338:Short retention on purpose; the stack is destroyed after each benchmark.
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- Network ---------------------------------------------------------------------

resource "aws_security_group" "ops" {
  #checkov:skip=CKV2_AWS_5:Attached at run time: the deploy workflow passes it to aws ecs run-task.
  name        = "${var.name}-ops"
  description = "One-off psql tasks: no inbound, outbound to the database and AWS APIs"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-ops" }
}

resource "aws_vpc_security_group_egress_rule" "ops_all" {
  #checkov:skip=CKV_AWS_382:Tasks pull the image and read secrets through the internet gateway (no NAT or endpoints, to keep idle cost at zero).
  security_group_id = aws_security_group.ops.id
  description       = "Public ECR, Secrets Manager, CloudWatch Logs and the database"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_ops" {
  security_group_id            = var.db.security_group_id
  description                  = "PostgreSQL from the ${var.name} ops tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.db.port
  to_port                      = var.db.port
  referenced_security_group_id = aws_security_group.ops.id
}

# --- IAM ---------------------------------------------------------------------------

# Only an execution role (pull the image, write logs, read the secrets); psql itself
# doesn't call AWS.
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${var.name}-ops-execution"
  description          = "Pulls the psql image, writes its logs and reads the database secrets"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db.admin_secret_arn, var.db.app_secret_arn, var.dms_secret_arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "database-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secrets.json
}

# --- Tasks ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "script" {
  for_each = var.scripts

  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name                   = "psql"
    image                  = var.image
    essential              = true
    readonlyRootFilesystem = true
    # The script comes in an environment variable; the psql variables are the same
    # for every script, which uses the ones it needs.
    command = ["sh", "-c", join(" ", [
      "printf '%s\\n' \"$SQL\" | psql -X -v ON_ERROR_STOP=1",
      "-v dms_user=\"$DMS_USER\" -v dms_password=\"$DMS_PASSWORD\" -v app_user=\"$APP_USER\"",
      "-v db_name=\"$PGDATABASE\" -v db_schema=\"$DB_SCHEMA\"",
    ])]
    environment = [for k, v in {
      SQL        = each.value
      PGHOST     = var.db.endpoint
      PGPORT     = tostring(var.db.port)
      PGDATABASE = var.db.name
      PGSSLMODE  = "require" # the source sets rds.force_ssl=1
      DB_SCHEMA  = var.db.schema
      DMS_USER   = var.dms_user
    } : { name = k, value = v }]
    secrets = [
      { name = "PGUSER", valueFrom = "${var.db.admin_secret_arn}:username::" },
      { name = "PGPASSWORD", valueFrom = "${var.db.admin_secret_arn}:password::" },
      { name = "APP_USER", valueFrom = "${var.db.app_secret_arn}:username::" },
      { name = "DMS_PASSWORD", valueFrom = "${var.dms_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = each.key
      }
    }
  }])
}
