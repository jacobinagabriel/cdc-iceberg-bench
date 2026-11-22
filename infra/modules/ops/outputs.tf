output "cluster_name" {
  description = "ECS cluster the ops tasks run in"
  value       = aws_ecs_cluster.this.name
}

output "task_definition_arns" {
  description = "Task definition per script"
  value       = { for k, t in aws_ecs_task_definition.script : k => t.arn }
}

output "security_group_id" {
  description = "Security group of the ops tasks"
  value       = aws_security_group.ops.id
}

output "log_group_name" {
  description = "Log group of the ops tasks"
  value       = aws_cloudwatch_log_group.this.name
}
