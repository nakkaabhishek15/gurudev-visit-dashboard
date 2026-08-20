#!/usr/bin/env bash
# Full backend deploy: build and push, migrate, then roll the ECS service.
# Migrations run before the new tasks start, so they must stay backward
# compatible with the code currently serving traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/envs/prod"
TAG="${1:-latest}"

if [[ "${TAG}" != "latest" ]]; then
  export PUSH_LATEST="${PUSH_LATEST:-true}"
fi

"${SCRIPT_DIR}/deploy_backend.sh" "${TAG}"
"${SCRIPT_DIR}/run_backend_migrations.sh"

cd "${TF_DIR}"
REGION="$(tofu output -raw aws_region)"
CLUSTER="$(tofu output -raw backend_ecs_cluster_name)"
SERVICE="$(tofu output -raw backend_ecs_service_name)"

aws ecs update-service \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --force-new-deployment >/dev/null

aws ecs wait services-stable --region "${REGION}" --cluster "${CLUSTER}" --services "${SERVICE}"

echo "Backend deployment completed with image tag ${TAG}."
