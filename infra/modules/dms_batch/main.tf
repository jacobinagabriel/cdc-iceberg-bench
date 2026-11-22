# Pipeline dms_batch: DMS task → Parquet files in S3 (bronze) → scheduled Glue job →
# Iceberg (silver). It runs on the same replication instance and source endpoint as
# dms_stream, with its own task and replication slot.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  databases = {
    bronze = "${var.prefix}_bronze"
    silver = "${var.prefix}_silver"
  }

  landing_folder = "dms-landing"
  landing_path   = "s3://${var.bucket}/${local.landing_folder}"

  # Every DMS Parquet row also has the operation and DMS's timestamp.
  bronze_columns = [
    { name = "Op", type = "string" }, # I, U, D (full-load rows are I)
    { name = "_dms_ts", type = "string" },
  ]
}

# --- DMS task to S3 ------------------------------------------------------------------

resource "aws_iam_role" "dms_s3" {
  name                 = "${var.name}-dms-s3"
  description          = "Lets DMS write the dms_batch changes to the lake bucket"
  assume_role_policy   = var.dms_trust_policy_json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "dms_s3" {
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:PutObjectTagging"]
    resources = ["${var.bucket_arn}/${local.landing_folder}/*"]
  }

  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.bucket_arn]
  }
}

resource "aws_iam_role_policy" "dms_s3" {
  name   = "landing-write"
  role   = aws_iam_role.dms_s3.id
  policy = data.aws_iam_policy_document.dms_s3.json
}

resource "aws_dms_s3_endpoint" "this" {
  #checkov:skip=CKV_AWS_298:SSE-S3 like the rest of the lake; a customer managed key adds cost.
  endpoint_id             = "${var.name}-s3"
  endpoint_type           = "target"
  bucket_name             = var.bucket
  bucket_folder           = local.landing_folder
  service_access_role_arn = aws_iam_role.dms_s3.arn
  encryption_mode         = "SSE_S3"

  data_format     = "parquet"
  parquet_version = "parquet-2-0"
  # Every row says what happened (Op = I/U/D, full-load rows included) and when.
  include_op_for_full_load = true
  timestamp_column_name    = "_dms_ts"
  cdc_inserts_and_updates  = false # keep deletes
  # DMS closes a CDC file after this many seconds or this size, whichever first: the
  # DMS half of this pipeline's latency (the Glue schedule is the other).
  cdc_max_batch_interval = var.cdc_batch_seconds
  cdc_min_file_size      = var.cdc_min_file_kb

  depends_on = [aws_iam_role_policy.dms_s3]
}

resource "aws_dms_replication_task" "this" {
  replication_task_id      = var.name
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = var.replication_instance_arn
  source_endpoint_arn      = var.source_endpoint_arn
  target_endpoint_arn      = aws_dms_s3_endpoint.this.endpoint_arn
  # The deploy workflow starts it after db-setup has created the DMS user.
  start_replication_task = false

  table_mappings = jsonencode({
    rules = [{
      rule-type      = "selection"
      rule-id        = "1"
      rule-name      = "source-schema"
      object-locator = { schema-name = var.source_schema, table-name = "%" }
      rule-action    = "include"
    }]
  })

  replication_task_settings = jsonencode({
    Logging          = { EnableLogging = true }
    FullLoadSettings = { TargetTablePrepMode = "DO_NOTHING" }
    TargetMetadata   = { SupportLobs = true, FullLobMode = false, LobMaxSize = 32 }
  })

  lifecycle {
    # DMS fills in every default setting, which would show as a change on each plan.
    ignore_changes = [replication_task_settings]
  }
}

# --- Tables --------------------------------------------------------------------------

resource "aws_glue_catalog_database" "this" {
  for_each = local.databases

  name        = each.value
  description = "dms_batch pipeline, ${each.key} layer"
}

# Bronze is the DMS output as it lands: append-only Parquet, so it already holds every
# change. A plain table lets Athena query it.
resource "aws_glue_catalog_table" "bronze" {
  for_each = var.tables

  name          = each.key
  database_name = aws_glue_catalog_database.this["bronze"].name
  table_type    = "EXTERNAL_TABLE"
  parameters    = { classification = "parquet" }

  storage_descriptor {
    location      = "${local.landing_path}/${var.source_schema}/${each.key}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = concat(local.bronze_columns, each.value)

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

resource "aws_glue_catalog_table" "silver" {
  for_each = var.tables

  name          = each.key
  database_name = aws_glue_catalog_database.this["silver"].name
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
      version            = "2"
    }
  }

  storage_descriptor {
    location = "s3://${var.bucket}/warehouse/${local.databases.silver}/${each.key}"

    dynamic "columns" {
      for_each = each.value

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

# --- Glue job --------------------------------------------------------------------------

resource "aws_s3_object" "script" {
  bucket = var.bucket
  key    = "glue/${var.name}/batch_merge.py"
  source = var.merge_script_source
  etag   = filemd5(var.merge_script_source)
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "glue" {
  name                 = "${var.name}-glue"
  description          = "Runs the dms_batch merge job: reads the landing files, writes silver"
  assume_role_policy   = data.aws_iam_policy_document.glue_trust.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "glue" {
  statement {
    sid       = "ListLake"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.bucket_arn]
  }

  statement {
    sid       = "ReadLandingAndScript"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/${local.landing_folder}/*", "${var.bucket_arn}/glue/*"]
  }

  statement {
    sid       = "WriteSilverAndCheckpoints"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.bucket_arn}/warehouse/${local.databases.silver}/*", "${var.bucket_arn}/glue/*"]
  }

  statement {
    sid     = "IcebergCatalog"
    actions = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:UpdateTable"]
    resources = [
      "arn:aws:glue:${local.region}:${local.account_id}:catalog",
      aws_glue_catalog_database.this["silver"].arn,
      "arn:aws:glue:${local.region}:${local.account_id}:table/${local.databases.silver}/*",
    ]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws-glue/*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Glue"]
    }
  }
}

resource "aws_iam_role_policy" "glue" {
  name   = "merge-job"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

resource "aws_glue_job" "merge" {
  #checkov:skip=CKV_AWS_195:No Glue security configuration; the lake uses SSE-S3 and the logs hold no data.
  name              = "${var.name}-merge"
  description       = "Merges new DMS Parquet files into the dms_batch silver Iceberg tables"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = var.glue_workers
  timeout           = 30
  max_retries       = 0

  execution_property {
    max_concurrent_runs = 1
  }

  command {
    name            = "glueetl"
    script_location = "s3://${var.bucket}/${aws_s3_object.script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--datalake-formats"                 = "iceberg"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-bookmark-option"              = "job-bookmark-disable" # the stream checkpoints track progress
    "--landing_path"                     = local.landing_path
    "--checkpoint_path"                  = "s3://${var.bucket}/glue/${var.name}/checkpoints"
    "--warehouse_path"                   = "s3://${var.bucket}/warehouse/"
    "--source_schema"                    = var.source_schema
    "--silver_database"                  = local.databases.silver
    "--tables"                           = join(",", keys(var.tables))
  }

  depends_on = [aws_iam_role_policy.glue]
}

resource "aws_glue_trigger" "schedule" {
  name     = "${var.name}-schedule"
  type     = "SCHEDULED"
  schedule = var.schedule
  # The deploy workflow enables it once the full load has landed, and disables it on down.
  enabled = false

  actions {
    job_name = aws_glue_job.merge.name
  }

  lifecycle {
    ignore_changes = [enabled]
  }
}
