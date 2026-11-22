# Read by the deploy workflow.

output "ops" {
  description = "Where and how to run the one-off psql tasks"
  value = {
    cluster          = module.ops.cluster_name
    task_definitions = module.ops.task_definition_arns
    security_group   = module.ops.security_group_id
    subnets          = module.shared.public_subnet_ids
    log_group        = module.ops.log_group_name
  }
}

output "dms" {
  description = "The replication instance, its endpoints and both tasks"
  value = {
    replication_instance_arn = module.dms.replication_instance_arn
    endpoint_arns = [
      module.dms.source_endpoint_arn,
      module.dms_stream.target_endpoint_arn,
      module.dms_batch.target_endpoint_arn,
    ]
    task_arns = {
      dms_stream = module.dms_stream.replication_task_arn
      dms_batch  = module.dms_batch.replication_task_arn
    }
  }
}

output "dms_batch" {
  description = "The merge job and its schedule"
  value = {
    glue_job     = module.dms_batch.glue_job_name
    glue_trigger = module.dms_batch.glue_trigger_name
  }
}

output "lake" {
  description = "Where to query the results"
  value = {
    bucket           = module.lake.bucket
    athena_workgroup = module.lake.athena_workgroup
    databases = {
      dms_stream = module.dms_stream.databases
      dms_batch  = module.dms_batch.databases
    }
  }
}
