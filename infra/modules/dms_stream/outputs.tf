output "replication_task_arn" {
  description = "DMS task of this pipeline"
  value       = aws_dms_replication_task.this.replication_task_arn
}

output "target_endpoint_arn" {
  description = "DMS Kinesis target endpoint"
  value       = aws_dms_endpoint.kinesis.endpoint_arn
}

output "kinesis_stream_name" {
  description = "Kinesis stream between DMS and Firehose"
  value       = aws_kinesis_stream.this.name
}

output "firehose_stream_names" {
  description = "Firehose stream per layer"
  value       = { for k, s in aws_kinesis_firehose_delivery_stream.this : k => s.name }
}

output "databases" {
  description = "Glue database per layer"
  value       = local.databases
}
