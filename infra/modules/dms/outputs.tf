output "replication_instance_arn" {
  description = "The replication instance both tasks run on"
  value       = aws_dms_replication_instance.this.replication_instance_arn
}

output "source_endpoint_arn" {
  description = "The source endpoint both tasks read from"
  value       = aws_dms_endpoint.source.endpoint_arn
}

output "source_secret_arn" {
  description = "Secret with the DMS user's credentials"
  value       = aws_secretsmanager_secret.source.arn
}

output "trust_policy_json" {
  description = "Trust policy for the DMS service roles of the pipelines"
  value       = data.aws_iam_policy_document.dms_trust.json
}
