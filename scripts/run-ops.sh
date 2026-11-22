#!/usr/bin/env bash
# Runs one of the ops tasks (db-setup, db-teardown, source-counts) on ECS, waits for
# it, prints its log and fails if psql failed.
#
#   scripts/run-ops.sh <script> [outputs.json]
#
# outputs.json is `terraform output -json` of infra/envs/prod; without it, the script
# reads the outputs itself (needs AWS credentials for the state, e.g. AWS_PROFILE).
set -euo pipefail

script=${1:?usage: run-ops.sh <db-setup|db-teardown|source-counts> [outputs.json]}
if [ -n "${2:-}" ]; then
  out=$(cat "$2")
else
  out=$(terraform -chdir="$(dirname "$0")/../infra/envs/prod" output -json)
fi

cluster=$(jq -r .ops.value.cluster <<<"$out")
task_definition=$(jq -r --arg s "$script" '.ops.value.task_definitions[$s]' <<<"$out")
subnets=$(jq -r '.ops.value.subnets | join(",")' <<<"$out")
security_group=$(jq -r .ops.value.security_group <<<"$out")
log_group=$(jq -r .ops.value.log_group <<<"$out")

if [ "$task_definition" = null ]; then
  echo "No ops task named $script" >&2
  exit 1
fi

echo "::group::$script"
task=$(aws ecs run-task --cluster "$cluster" --task-definition "$task_definition" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=ENABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task"
code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --query 'tasks[0].containers[0].exitCode' --output text)
aws logs tail "$log_group" --log-stream-names "$script/psql/${task##*/}" --since 1h || true
echo "::endgroup::"

if [ "$code" != 0 ]; then
  echo "::error::$script failed with exit code $code (logs: $log_group)"
  exit 1
fi
