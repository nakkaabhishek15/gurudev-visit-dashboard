#!/usr/bin/env bash
# Deploy backend and frontend together. Backend first: the frontend expects the
# API endpoints it calls to already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-$(git rev-parse HEAD)}"

"${SCRIPT_DIR}/deploy_backend_service.sh" "${TAG}"
"${SCRIPT_DIR}/deploy_frontend.sh"

cd "${SCRIPT_DIR}/../envs/prod"
echo "Deployed. App is at $(tofu output -raw app_url)"
