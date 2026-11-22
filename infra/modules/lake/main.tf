# The lake both DMS pipelines write to: one bucket (Iceberg warehouse, DMS landing
# files, Firehose errors, the Glue script, Athena results), the Athena workgroup to
# query it, and the schema of every source table, shared by all pipelines.

locals {
  # The source-app tables (Alembic migrations in source-app), as Iceberg/Glue types:
  # uuid and text → string, integer → int, bigint → bigint, double precision →
  # double, numeric(12,2) → decimal(12,2), timestamptz → timestamp. Every table's
  # primary key is `id`.
  tables = {
    dist_centers = [
      { name = "id", type = "bigint" },
      { name = "name", type = "string" },
      { name = "latitude", type = "double" },
      { name = "longitude", type = "double" },
    ]
    products = [
      { name = "id", type = "bigint" },
      { name = "cost", type = "decimal(12,2)" },
      { name = "category", type = "string" },
      { name = "name", type = "string" },
      { name = "brand", type = "string" },
      { name = "retail_price", type = "decimal(12,2)" },
      { name = "department", type = "string" },
      { name = "sku", type = "string" },
      { name = "distribution_center_id", type = "bigint" },
    ]
    users = [
      { name = "id", type = "string" },
      { name = "first_name", type = "string" },
      { name = "last_name", type = "string" },
      { name = "email", type = "string" },
      { name = "age", type = "int" },
      { name = "gender", type = "string" },
      { name = "street_address", type = "string" },
      { name = "postal_code", type = "string" },
      { name = "city", type = "string" },
      { name = "state", type = "string" },
      { name = "country", type = "string" },
      { name = "latitude", type = "double" },
      { name = "longitude", type = "double" },
      { name = "traffic_source", type = "string" },
      { name = "created_at", type = "timestamp" },
      { name = "updated_at", type = "timestamp" },
    ]
    orders = [
      { name = "id", type = "string" },
      { name = "user_id", type = "string" },
      { name = "status", type = "string" },
      { name = "num_of_items", type = "int" },
      { name = "created_at", type = "timestamp" },
      { name = "updated_at", type = "timestamp" },
      { name = "returned_at", type = "timestamp" },
      { name = "shipped_at", type = "timestamp" },
      { name = "delivered_at", type = "timestamp" },
      { name = "cancelled_at", type = "timestamp" },
    ]
    order_items = [
      { name = "id", type = "string" },
      { name = "order_id", type = "string" },
      { name = "product_id", type = "bigint" },
      { name = "status", type = "string" },
      { name = "quantity", type = "int" },
      { name = "sale_price", type = "decimal(12,2)" },
      { name = "created_at", type = "timestamp" },
      { name = "updated_at", type = "timestamp" },
      { name = "shipped_at", type = "timestamp" },
      { name = "delivered_at", type = "timestamp" },
      { name = "returned_at", type = "timestamp" },
      { name = "cancelled_at", type = "timestamp" },
    ]
    events = [
      { name = "id", type = "string" },
      { name = "user_id", type = "string" },
      { name = "sequence_number", type = "int" },
      { name = "session_id", type = "string" },
      { name = "ip_address", type = "string" },
      { name = "city", type = "string" },
      { name = "state", type = "string" },
      { name = "postal_code", type = "string" },
      { name = "browser", type = "string" },
      { name = "traffic_source", type = "string" },
      { name = "uri", type = "string" },
      { name = "event_type", type = "string" },
      { name = "created_at", type = "timestamp" },
    ]
  }
}

# --- Bucket ----------------------------------------------------------------------

resource "aws_s3_bucket" "lake" {
  #checkov:skip=CKV_AWS_18:Access logging adds cost; the bucket only holds synthetic benchmark data.
  #checkov:skip=CKV_AWS_21:Iceberg keeps its own snapshots; S3 versioning would only duplicate data files.
  #checkov:skip=CKV_AWS_144:No cross-region replication for a throwaway benchmark lake.
  #checkov:skip=CKV_AWS_145:SSE-S3 is enough for synthetic data; a customer managed key adds cost.
  #checkov:skip=CKV2_AWS_62:No consumers of S3 event notifications.
  bucket_prefix = "${var.name}-lake-"
  force_destroy = true # down removes the lake with everything else
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 7
    }
  }
}

# --- Athena ------------------------------------------------------------------------

resource "aws_athena_workgroup" "this" {
  name          = var.name
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
