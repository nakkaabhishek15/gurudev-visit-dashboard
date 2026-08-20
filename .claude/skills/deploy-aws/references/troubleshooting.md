# Troubleshooting

Start here, always:

```bash
cd terraform/envs/prod
REGION="$(tofu output -raw aws_region)"
CLUSTER="$(tofu output -raw backend_ecs_cluster_name)"
SERVICE="$(tofu output -raw backend_ecs_service_name)"

aws logs tail "$(tofu output -raw backend_log_group_name)" --region "$REGION" --since 30m
aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:10]'
```

## Task starts, then stops immediately

Check `stoppedReason`:

```bash
TASK=$(aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" \
  --desired-status STOPPED --query 'taskArns[0]' --output text)
aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].{reason:stoppedReason,containers:containers[].{name:name,reason:reason,exit:exitCode}}'
```

| `stoppedReason` contains | Cause | Fix |
|---|---|---|
| `ResourceInitializationError ... secrets` | The execution role cannot read a secret, or the secret has no value | Write the value (see first-time-setup step 6); confirm the ARN is in `backend_execution_secrets` |
| `CannotPullContainerError` | Image tag missing from ECR | Re-run `deploy_backend.sh`; if the tag is a SHA, confirm `:latest` also moved |
| `exec format error` in logs | Image built for arm64 | Rebuild with `--platform linux/amd64` — `deploy_backend.sh` already passes it |
| `Essential container in task exited`, exit 1 | App crashed at import | Read the log stream; usually a missing env var |

## Health check fails, service never stabilises

`aws ecs wait services-stable` hangs, then the circuit breaker rolls back.

1. Confirm `/health` returns 200 without auth. It is deliberately outside the
   protected router in `backend/app/main.py` — if someone moved it behind
   `require_auth`, it now returns 401 and every task is killed as unhealthy.
2. Confirm the container listens on `backend_container_port` (8000).
3. Check target health:
   ```bash
   aws elbv2 describe-target-health --region "$REGION" \
     --target-group-arn "$(aws elbv2 describe-target-groups --region "$REGION" \
       --names "$(tofu output -raw backend_ecs_cluster_name)-backend" \
       --query 'TargetGroups[0].TargetGroupArn' --output text)"
   ```

## `/api/health` returns `database: error`

The API is up; Postgres is not reachable.

- The RDS security group rule may be missing. `tofu plan` should show
  `aws_vpc_security_group_ingress_rule.rds_from_backend` as present, not to-add.
  Someone deleting it by hand in the console is the usual cause.
- The `database-url` secret may point at the wrong host, database, or user.
  Verify the endpoint:
  ```bash
  aws rds describe-db-instances --db-instance-identifier aolf \
    --query 'DBInstances[0].Endpoint.Address' --output text
  ```
- ECS caches secret values at task start. After changing a secret you must roll
  the service — updating the secret alone changes nothing.

## CloudFront returns 502 or 504 on /api

The ALB is unreachable from CloudFront. Check the ALB security group still has
the `com.amazonaws.global.cloudfront.origin-facing` prefix list ingress rule on
port 80. Replacing it with `0.0.0.0/0` "to debug" both fails to help and exposes
the origin directly — don't.

## CloudFront returns 403 on the site root

The S3 bucket policy or Origin Access Control was changed. Re-apply. The bucket
is private by design; a 403 means CloudFront lost its signed read access.

## Frontend deploy succeeded but the site is unchanged

The invalidation is asynchronous. Either wait, or re-run with
`WAIT_FOR_CLOUDFRONT_INVALIDATION=true`. Confirm the objects actually landed:

```bash
aws s3 ls "s3://$(tofu output -raw frontend_bucket_name)/" --recursive | head
```

A hard refresh in the browser rules out local cache.

## Refreshing /dashboard gives a 404

The CloudFront SPA-rewrite function is missing or unpublished. It rewrites any
extension-less path to `/index.html`. Check
`aws_cloudfront_function.frontend_spa_rewrite` in
`terraform/envs/prod/app_frontend.tf` is associated with the default cache
behaviour, and that `publish = true`.

## `EntityAlreadyExists` on the OIDC provider

An AWS account holds one OIDC provider per issuer, and `aolf-warehouse` already
created it. Set `create_github_oidc_provider = false` and re-apply — the stack
then reads the existing provider instead.

## Migration task exits non-zero

The deploy stops before rolling the service, so production is still on the old
code. Read the task's log stream:

```bash
aws logs tail "$(tofu output -raw backend_log_group_name)" --region "$REGION" --since 15m
```

Fix the migration in `backend/app/db/migrations.py` and redeploy. Never edit an
already-applied migration — its key is recorded in `app.schema_migrations` and
it will not run again. Add a new entry instead.

## Login always fails with a valid password

- Ten failures lock the account for fifteen minutes and the API returns 423, not
  401. `manage_users_task.sh set-password` clears it.
- If everyone is signed out at once, the `auth/session-secret` changed. Every
  existing cookie is invalid; users just sign in again.
- 401 on `/api/auth/me` right after a successful login means the cookie was not
  stored. Check `AUTH_COOKIE_SECURE=true` is set in the task definition and the
  site is served over HTTPS — a `Secure` cookie is dropped on plain HTTP.

## Rolling back

There is no rollback script. Redeploy the previous image tag:

```bash
aws ecr describe-images --region "$REGION" \
  --repository-name "$(cd terraform/envs/prod && tofu output -raw backend_ecr_repository_url | sed 's|.*/||')" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].[imageTags[0],imagePushedAt]' --output table

PUSH_LATEST=true terraform/scripts/deploy_backend.sh <previous-sha>
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment
```

Migrations do not roll back. If the bad deploy included a schema change, write a
new forward migration that undoes it.
