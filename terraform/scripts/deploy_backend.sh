#!/usr/bin/env bash
# Build the backend image and push it to ECR. Does not touch the running service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/envs/prod"
TAG="${1:-latest}"
PUSH_LATEST="${PUSH_LATEST:-false}"

cd "${TF_DIR}"

REGION="$(tofu output -raw aws_region)"
REPO_URL="$(tofu output -raw backend_ecr_repository_url)"
REGISTRY="${REPO_URL%/*}"

aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"

# --platform is not optional: Fargate runs X86_64 here, and an image built on an
# Apple Silicon machine without it will start and immediately die with an exec
# format error.
docker build --platform linux/amd64 -f "${REPO_ROOT}/backend/Dockerfile" -t "${REPO_URL}:${TAG}" "${REPO_ROOT}"
docker push "${REPO_URL}:${TAG}"

# The task definition pins :latest, so a commit-SHA tag also has to move :latest
# for the new image to actually be the one ECS pulls.
if [[ "${PUSH_LATEST}" == "true" && "${TAG}" != "latest" ]]; then
  docker tag "${REPO_URL}:${TAG}" "${REPO_URL}:latest"
  docker push "${REPO_URL}:latest"
  echo "Also pushed ${REPO_URL}:latest for the task definition managed by OpenTofu."
fi

echo "Pushed backend image ${REPO_URL}:${TAG}"
