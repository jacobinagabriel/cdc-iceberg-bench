# Pipeline dms_stream: DMS task → Kinesis → two Firehose streams → Iceberg.
#
# Both Firehose streams read the same Kinesis stream and call the same transform
# Lambda (src/cdc_bench/transform.py) in a different mode:
# - bronze: every change appended to <prefix>_bronze.<table>, with its metadata;
# - silver: every change applied by primary key to <prefix>_silver.<table>.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  databases = {
    bronze = "${var.prefix}_bronze"
    silver = "${var.prefix}_silver"
  }

  # Bronze adds the change's metadata to the source columns.
  bronze_columns = [
    { name = "_op", type = "string" }, # L (full load), I, U, D
    { name = "_commit_ts", type = "timestamp" },
    { name = "_dms_ts", type = "timestamp" },
    { name = "_txid", type = "string" },
    { name = "_before", type = "string" }, # JSON of the row before an update or delete
    { name = "_transform_ts", type = "timestamp" },
  ]

  columns = {
    bronze = { for t, cols in var.tables : t => concat(cols, local.bronze_columns) }
    silver = var.tables
  }

  tables = merge([
    for layer, db in local.databases : {
      for t, cols in local.columns[layer] : "${layer}.${t}" => { layer = layer, database = db, table = t, columns = cols }
    }
  ]...)
}

# --- Iceberg tables ----------------------------------------------------------------

resource "aws_glue_catalog_database" "this" {
  for_each = local.databases

  name        = each.value
  description = "dms_stream pipeline, ${each.key} layer"
}

# Created through Glue's Iceberg API, the only tables Firehose writes to.
resource "aws_glue_catalog_table" "this" {
  for_each = local.tables

  name          = each.value.table
  database_name = aws_glue_catalog_database.this[each.value.layer].name
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
      version            = "2"
    }
  }

  storage_descriptor {
    location = "s3://${var.bucket}/warehouse/${each.value.database}/${each.value.table}"

    dynamic "columns" {
      for_each = each.value.columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }

  lifecycle {
    # Every Iceberg commit updates the table's parameters (metadata location); a
    # schema change means recreating the table.
    ignore_changes = [parameters, storage_descriptor, open_table_format_input]
  }
}

# --- Kinesis and the DMS task ---------------------------------------------------------

resource "aws_kinesis_stream" "this" {
  name             = var.name
  shard_count      = var.kinesis_shards
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_iam_role" "dms_kinesis" {
  name                 = "${var.name}-dms-kinesis"
  description          = "Lets DMS write the dms_stream changes to Kinesis"
  assume_role_policy   = var.dms_trust_policy_json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "dms_kinesis" {
  statement {
    actions   = ["kinesis:DescribeStream", "kinesis:PutRecord", "kinesis:PutRecords"]
    resources = [aws_kinesis_stream.this.arn]
  }

  statement {
    actions   = ["kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["kinesis.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "dms_kinesis" {
  name   = "kinesis-write"
  role   = aws_iam_role.dms_kinesis.id
  policy = data.aws_iam_policy_document.dms_kinesis.json
}

resource "aws_dms_endpoint" "kinesis" {
  #checkov:skip=CKV_AWS_296:AWS managed key; a customer managed key adds cost and nothing for a synthetic database.
  #checkov:skip=CKV2_AWS_49:Kinesis endpoints use the AWS API over TLS; ssl_mode applies to database endpoints.
  endpoint_id   = "${var.name}-kinesis"
  endpoint_type = "target"
  engine_name   = "kinesis"

  kinesis_settings {
    stream_arn              = aws_kinesis_stream.this.arn
    service_access_role_arn = aws_iam_role.dms_kinesis.arn
    # One JSON object per line: {"data": ..., "before": ..., "metadata": ...}
    message_format                 = "json-unformatted"
    include_transaction_details    = true # commit timestamp and transaction id
    include_partition_value        = true
    partition_include_schema_table = true
    include_null_and_empty         = true
  }

  depends_on = [aws_iam_role_policy.dms_kinesis]
}

resource "aws_dms_replication_task" "this" {
  replication_task_id      = var.name
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = var.replication_instance_arn
  source_endpoint_arn      = var.source_endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.kinesis.endpoint_arn
  # The deploy workflow starts it after db-setup has created the DMS user.
  start_replication_task = false

  table_mappings = jsonencode({
    rules = [
      {
        rule-type      = "selection"
        rule-id        = "1"
        rule-name      = "source-schema"
        object-locator = { schema-name = var.source_schema, table-name = "%" }
        rule-action    = "include"
      },
      {
        # Partitioning by primary key keeps each row's changes in order (one shard).
        rule-type          = "object-mapping"
        rule-id            = "2"
        rule-name          = "partition-by-primary-key"
        rule-action        = "map-record-to-record"
        object-locator     = { schema-name = var.source_schema, table-name = "%" }
        mapping-parameters = { partition-key-type = "primary-key" }
      },
    ]
  })

  replication_task_settings = jsonencode({
    Logging = { EnableLogging = true }
    # The source logs full old rows (rds.replica_identity_full=1), so updates and
    # deletes carry the whole row before the change.
    BeforeImageSettings = {
      EnableBeforeImage = true
      FieldName         = "before"
      ColumnFilter      = "all"
    }
    FullLoadSettings = { TargetTablePrepMode = "DO_NOTHING" }
    TargetMetadata   = { SupportLobs = true, FullLobMode = false, LobMaxSize = 32 }
  })

  lifecycle {
    # DMS fills in every default setting, which would show as a change on each plan.
    ignore_changes = [replication_task_settings]
  }
}

# --- Transform Lambda -------------------------------------------------------------------

data "archive_file" "transform" {
  type        = "zip"
  source_file = var.transform_source
  output_path = "${path.root}/.build/dms-stream-transform.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "transform" {
  name                 = "${var.name}-transform"
  description          = "Execution role of the dms_stream transform Lambda (logs only)"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "transform_logs" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "transform" {
  #checkov:skip=CKV_AWS_158:Logs of a synthetic workload; the default AWS-owned encryption is enough.
  #checkov:skip=CKV_AWS_338:Short retention on purpose; the stack is destroyed after each benchmark.
  for_each = local.databases

  name              = "/aws/lambda/${var.name}-transform-${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "transform" {
  #checkov:skip=CKV_AWS_50:No X-Ray tracing; Firehose and CloudWatch metrics cover the benchmark.
  #checkov:skip=CKV_AWS_115:Concurrency follows Firehose; a reserved limit would only throttle it.
  #checkov:skip=CKV_AWS_116:Firehose retries and sends failed records to its error prefix; no DLQ needed.
  #checkov:skip=CKV_AWS_117:Needs no VPC: it only transforms the records Firehose passes in.
  #checkov:skip=CKV_AWS_173:Environment holds table schemas, not secrets.
  #checkov:skip=CKV_AWS_272:No code signing for a single-file function deployed by Terraform.
  for_each = local.databases

  function_name    = "${var.name}-transform-${each.key}"
  description      = "Flattens DMS changes for the dms_stream ${each.key} Firehose stream"
  role             = aws_iam_role.transform.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "transform.handler"
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      MODE          = each.key
      DATABASE      = each.value
      SOURCE_SCHEMA = var.source_schema
      TABLE_SCHEMAS = jsonencode({ for t, cols in var.tables : t => { for c in cols : c.name => c.type } })
    }
  }

  depends_on = [aws_cloudwatch_log_group.transform, aws_iam_role_policy_attachment.transform_logs]
}

# --- Firehose -------------------------------------------------------------------------

data "aws_iam_policy_document" "firehose_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name                 = "${var.name}-firehose"
  description          = "Lets Firehose read Kinesis, call the transform and write the Iceberg tables"
  assume_role_policy   = data.aws_iam_policy_document.firehose_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid       = "ReadKinesis"
    actions   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
    resources = [aws_kinesis_stream.this.arn]
  }

  statement {
    sid       = "DecryptKinesis"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["kinesis.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid     = "InvokeTransform"
    actions = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
    resources = flatten([
      for f in aws_lambda_function.transform : [f.arn, "${f.arn}:*"]
    ])
  }

  statement {
    sid     = "IcebergCatalog"
    actions = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:UpdateTable"]
    resources = concat(
      ["arn:aws:glue:${local.region}:${local.account_id}:catalog"],
      [for db in aws_glue_catalog_database.this : db.arn],
      [for db in aws_glue_catalog_database.this : "arn:aws:glue:${local.region}:${local.account_id}:table/${db.name}/*"],
    )
  }

  statement {
    sid       = "LakeBucket"
    actions   = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject", "s3:DeleteObject"]
    resources = [var.bucket_arn, "${var.bucket_arn}/*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "dms-stream-delivery"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_cloudwatch_log_group" "firehose" {
  #checkov:skip=CKV_AWS_158:Logs of a synthetic workload; the default AWS-owned encryption is enough.
  #checkov:skip=CKV_AWS_338:Short retention on purpose; the stack is destroyed after each benchmark.
  name              = "/aws/kinesisfirehose/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_stream" "firehose" {
  for_each = local.databases

  name           = each.key
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  #checkov:skip=CKV_AWS_240:A Kinesis-sourced stream inherits the source stream's encryption; Firehose server-side encryption only applies to Direct PUT.
  #checkov:skip=CKV_AWS_241:Same as above.
  for_each = local.databases

  name        = "${var.name}-${each.key}"
  destination = "iceberg"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.this.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  iceberg_configuration {
    role_arn           = aws_iam_role.firehose.arn
    catalog_arn        = "arn:aws:glue:${local.region}:${local.account_id}:catalog"
    buffering_interval = var.buffer_seconds
    buffering_size     = var.buffer_mb
    append_only        = each.key == "bronze"

    s3_configuration {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = var.bucket_arn
      error_output_prefix = "firehose-errors/${var.name}-${each.key}/!{firehose:error-output-type}/"
    }

    dynamic "destination_table_configuration" {
      for_each = var.tables

      content {
        database_name = each.value
        table_name    = destination_table_configuration.key
        # Silver applies updates and deletes by primary key; bronze only appends.
        unique_keys = each.key == "silver" ? ["id"] : null
      }
    }

    processing_configuration {
      enabled = true

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform[each.key].arn}:$LATEST"
        }

        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = tostring(min(var.buffer_seconds, 60))
        }
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose[each.key].name
    }
  }

  depends_on = [aws_iam_role_policy.firehose, aws_glue_catalog_table.this]
}
