#!/usr/bin/env bash
# Run the user-management CLI inside AWS as a one-off Fargate task.
#
# This is how the first login gets created: the task already has DATABASE_URL
# from Secrets Manager, so nobody needs database credentials on their laptop.
#
#   terraform/scripts/manage_users_task.sh create --email you@example.com --name "You" --role admin
#   terraform/scripts/manage_users_task.sh list
#
# The password is read from AOLF_NEW_PASSWORD, which must be exported before
# running this. It is passed as a container environment override, so it does not
# appear in shell history -- but it IS visible in `aws ecs describe-tasks` output
# for the lifetime of the task. Rotate the password afterwards if that matters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/envs/prod"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <manage_users subcommand> [args...]" >&2
  exit 2
fi

cd "${TF_DIR}"

REGION="$(tofu output -raw aws_region)"
CLUSTER="$(tofu output -raw backend_ecs_cluster_name)"
TASK_DEFINITION="$(tofu output -raw backend_task_definition_arn)"
SECURITY_GROUP="$(tofu output -raw backend_security_group_id)"
SUBNETS_JSON="$(tofu output -json backend_subnet_ids)"
LOG_GROUP="$(tofu output -raw backend_log_group_name)"

COMMAND_JSON="$(jq -cn --args '["python","-m","app.cli.manage_users"] + $ARGS.positional' "$@")"

ENVIRONMENT_JSON='[]'
if [[ -n "${AOLF_NEW_PASSWORD:-}" ]]; then
  ENVIRONMENT_JSON="$(jq -cn --arg value "${AOLF_NEW_PASSWORD}" \
    '[{name:"AOLF_NEW_PASSWORD",value:$value}]')"
fi

NETWORK_CONFIGURATION="$(jq -cn \
  --argjson subnets "${SUBNETS_JSON}" \
  --arg sg "${SECURITY_GROUP}" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$sg],assignPublicIp:"ENABLED"}}')"

OVERRIDES="$(jq -cn \
  --argjson command "${COMMAND_JSON}" \
  --argjson environment "${ENVIRONMENT_JSON}" \
  '{containerOverrides:[{name:"backend",command:$command,environment:$environment}]}')"

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
  echo "ERROR: task did not start." >&2
  exit 1
fi

aws ecs wait tasks-stopped --region "${REGION}" --cluster "${CLUSTER}" --tasks "${TASK_ARN}"

EXIT_CODE="$(aws ecs describe-tasks \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --tasks "${TASK_ARN}" \
  --query 'tasks[0].containers[?name==`backend`].exitCode | [0]' \
  --output text)"

TASK_ID="${TASK_ARN##*/}"
echo "Task ${TASK_ID} exited with ${EXIT_CODE}. Output:"
aws logs get-log-events \
  --region "${REGION}" \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "backend/backend/${TASK_ID}" \
  --query 'events[].message' \
  --output text || echo "(log stream not available yet -- retry: aws logs tail ${LOG_GROUP} --region ${REGION} --since 10m)"

[[ "${EXIT_CODE}" == "0" ]]
