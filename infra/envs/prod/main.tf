# The benchmark's pipelines against source-app's database. Today: two DMS pipelines on
# one replication instance (docs/PLAN.md, PR 1).
#
# - dms_stream: DMS → Kinesis → Firehose → Iceberg (bronze changelog + silver)
# - dms_batch:  DMS → Parquet in S3 (bronze) → scheduled Glue MERGE → Iceberg (silver)

locals {
  name     = "cdc-iceberg-bench"
  dms_user = "cdc_dms"
  repo     = "${path.root}/../../.."
}

module "shared" {
  source = "../../modules/shared"

  contract_prefix = var.contract_prefix
  base_ssm_prefix = var.base_ssm_prefix
}

module "lake" {
  source = "../../modules/lake"

  name = local.name
}

module "dms" {
  source = "../../modules/dms"

  name                     = local.name
  vpc_id                   = module.shared.vpc_id
  subnet_ids               = module.shared.public_subnet_ids
  db                       = module.shared.db
  dms_user                 = local.dms_user
  instance_class           = var.dms_instance_class
  permissions_boundary_arn = module.shared.app_role_boundary_arn
}

module "ops" {
  source = "../../modules/ops"

  name           = local.name
  vpc_id         = module.shared.vpc_id
  db             = module.shared.db
  dms_user       = local.dms_user
  dms_secret_arn = module.dms.source_secret_arn
  scripts = {
    db-setup      = file("${local.repo}/sql/db-setup.sql")
    db-teardown   = file("${local.repo}/sql/db-teardown.sql")
    source-counts = file("${local.repo}/sql/source-counts.sql")
  }
  permissions_boundary_arn = module.shared.app_role_boundary_arn
}

module "dms_stream" {
  source = "../../modules/dms_stream"

  name                     = "${local.name}-dms-stream"
  tables                   = module.lake.tables
  source_schema            = module.shared.db.schema
  bucket                   = module.lake.bucket
  bucket_arn               = module.lake.bucket_arn
  replication_instance_arn = module.dms.replication_instance_arn
  source_endpoint_arn      = module.dms.source_endpoint_arn
  dms_trust_policy_json    = module.dms.trust_policy_json
  transform_source         = "${local.repo}/src/cdc_bench/transform.py"
  buffer_seconds           = var.firehose_buffer_seconds
  permissions_boundary_arn = module.shared.app_role_boundary_arn
}

module "dms_batch" {
  source = "../../modules/dms_batch"

  name                     = "${local.name}-dms-batch"
  tables                   = module.lake.tables
  source_schema            = module.shared.db.schema
  bucket                   = module.lake.bucket
  bucket_arn               = module.lake.bucket_arn
  replication_instance_arn = module.dms.replication_instance_arn
  source_endpoint_arn      = module.dms.source_endpoint_arn
  dms_trust_policy_json    = module.dms.trust_policy_json
  merge_script_source      = "${local.repo}/src/cdc_bench/batch_merge.py"
  cdc_batch_seconds        = var.dms_s3_batch_seconds
  schedule                 = var.batch_schedule
  permissions_boundary_arn = module.shared.app_role_boundary_arn
}

# What's deployed, under the path source-app's down workflow checks: while anything is
# here, source-app refuses to destroy the database these pipelines read from.
resource "aws_ssm_parameter" "state" {
  for_each = {
    "dms_stream/replication_task_arn" = module.dms_stream.replication_task_arn
    "dms_stream/kinesis_stream"       = module.dms_stream.kinesis_stream_name
    "dms_stream/firehose_streams"     = join(",", values(module.dms_stream.firehose_stream_names))
    "dms_stream/glue_databases"       = join(",", values(module.dms_stream.databases))
    "dms_batch/replication_task_arn"  = module.dms_batch.replication_task_arn
    "dms_batch/glue_job"              = module.dms_batch.glue_job_name
    "dms_batch/glue_databases"        = join(",", values(module.dms_batch.databases))
    "lake/bucket"                     = module.lake.bucket
    "lake/athena_workgroup"           = module.lake.athena_workgroup
  }
  #checkov:skip=CKV2_AWS_34:Resource names and ARNs, not secrets.

  name  = "/${local.name}/prod/${each.key}"
  type  = "String"
  value = each.value
}
