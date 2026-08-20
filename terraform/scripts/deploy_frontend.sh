#!/usr/bin/env bash
# Build the SvelteKit static site, sync it to S3, and invalidate CloudFront.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/envs/prod"
FRONTEND_DIR="${REPO_ROOT}/frontend"

cd "${TF_DIR}"

REGION="$(tofu output -raw aws_region)"
BUCKET="$(tofu output -raw frontend_bucket_name)"
DISTRIBUTION_ID="$(tofu output -raw cloudfront_distribution_id)"

cd "${FRONTEND_DIR}"

if [[ "${SKIP_FRONTEND_BUILD:-false}" != "true" ]]; then
  npm ci
  npm run build
fi

if [[ ! -f "${FRONTEND_DIR}/build/index.html" ]]; then
  echo "ERROR: ${FRONTEND_DIR}/build/index.html is missing. Did the build succeed?" >&2
  exit 1
fi

# --delete removes files from previous builds. Safe here because the bucket
# holds nothing but the build output.
aws s3 sync "${FRONTEND_DIR}/build" "s3://${BUCKET}" --delete --region "${REGION}"

INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths '/*' \
  --query 'Invalidation.Id' \
  --output text)"

if [[ "${WAIT_FOR_CLOUDFRONT_INVALIDATION:-false}" == "true" ]]; then
  aws cloudfront wait invalidation-completed --distribution-id "${DISTRIBUTION_ID}" --id "${INVALIDATION_ID}"
fi

echo "Uploaded frontend build to s3://${BUCKET} and invalidated ${DISTRIBUTION_ID} (${INVALIDATION_ID})."
