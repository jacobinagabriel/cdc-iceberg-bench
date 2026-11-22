output "replication_task_arn" {
  description = "DMS task of this pipeline"
  value       = aws_dms_replication_task.this.replication_task_arn
}

output "target_endpoint_arn" {
  description = "DMS S3 target endpoint"
  value       = aws_dms_s3_endpoint.this.endpoint_arn
}

output "glue_job_name" {
  description = "The merge job"
  value       = aws_glue_job.merge.name
}

output "glue_trigger_name" {
  description = "The merge job's schedule"
  value       = aws_glue_trigger.schedule.name
}

output "databases" {
  description = "Glue database per layer"
  value       = local.databases
}
