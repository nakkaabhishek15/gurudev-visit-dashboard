#!/usr/bin/env bash
# Run database migrations as a one-off Fargate task, then wait for the result.
# Exits non-zero if the task fails, which stops the deploy before the service rolls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/envs/prod"

cd "${TF_DIR}"

REGION="$(tofu output -raw aws_region)"
CLUSTER="$(tofu output -raw backend_ecs_cluster_name)"
TASK_DEFINITION="$(tofu output -raw backend_task_definition_arn)"
SECURITY_GROUP="$(tofu output -raw backend_security_group_id)"
SUBNETS_JSON="$(tofu output -json backend_subnet_ids)"
LOG_GROUP="$(tofu output -raw backend_log_group_name)"

NETWORK_CONFIGURATION="$(jq -cn \
  --argjson subnets "${SUBNETS_JSON}" \
  --arg sg "${SECURITY_GROUP}" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$sg],assignPublicIp:"ENABLED"}}')"

OVERRIDES="$(jq -cn \
  '{containerOverrides:[{name:"backend",command:["python","-c","from app.db.migrations import apply_migrations; apply_migrations()"]}]}')"

TASK_ARN="$(aws ecs run-task \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --launch-type FARGATE \
  --task-definition "${TASK_DEFINITION}" \
  --network-configuration "${NETWORK_CONFIGURATION}" \
  --overrides "${OVERRIDES}" \
  --query 'tasks[0].taskArn' \
  --output text)"

if [[ "${TASK_ARN}" == "None" || -z "${TASK_ARN}" ]]; then
  echo "ERROR: ECS migration task did not start." >&2
  exit 1
fi

aws ecs wait tasks-stopped --region "${REGION}" --cluster "${CLUSTER}" --tasks "${TASK_ARN}"

EXIT_CODE="$(aws ecs describe-tasks \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --tasks "${TASK_ARN}" \
  --query 'tasks[0].containers[?name==`backend`].exitCode | [0]' \
  --output text)"

if [[ "${EXIT_CODE}" != "0" ]]; then
  echo "ERROR: ECS migration task exited with ${EXIT_CODE}." >&2
  echo "Logs: aws logs tail ${LOG_GROUP} --region ${REGION} --since 15m" >&2
  exit 1
fi

echo "Backend migrations completed in task ${TASK_ARN}."
