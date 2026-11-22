output "bucket" {
  description = "The lake bucket"
  value       = aws_s3_bucket.lake.bucket
}

output "bucket_arn" {
  description = "ARN of the lake bucket"
  value       = aws_s3_bucket.lake.arn
}

output "athena_workgroup" {
  description = "Athena workgroup for querying the lake"
  value       = aws_athena_workgroup.this.name
}

output "tables" {
  description = "Source tables and their columns as Iceberg/Glue types (primary key: id)"
  value       = local.tables
}
