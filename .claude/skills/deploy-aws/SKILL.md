---
name: deploy-aws
description: Deploy this FastAPI + SvelteKit app to AWS (ECS Fargate, ALB, S3, CloudFront) with OpenTofu, and manage login credentials. Use when asked to deploy, ship, release, or roll back the app; provision or change AWS infrastructure; run database migrations; create, reset, or disable a user login; rotate the session secret or database URL; set up the stack in a new AWS account; or diagnose a failed deploy, an unhealthy ECS service, a 502/403 from the site, or a CloudFront caching problem.
---

# Deploy to AWS

This app runs as two halves behind one CloudFront distribution:

| Path | Origin | What it is |
|---|---|---|
| `/api/*` | ALB → ECS Fargate | FastAPI container, image in ECR |
| everything else | S3 (private, OAC) | SvelteKit static build |

Postgres is an **existing RDS instance owned by another OpenTofu state**. This
stack only reads it and adds one security group rule. Never add an
`aws_db_instance` here.

## Before doing anything

Confirm all three, and stop if any is missing:

1. `tofu -version` and `aws sts get-caller-identity` both work.
2. `terraform/envs/prod/terraform.tfvars` and `backend.hcl` exist. If not, this
   is a first-time setup — read [first-time-setup.md](references/first-time-setup.md).
3. The change is on `main` and tests pass. `git status` should be clean.

Always run `tofu init -backend-config=backend.hcl` in `terraform/envs/prod`
before any `tofu` command in a fresh checkout.

## Routine deploy

Prefer letting CI do it. Pushing to `main` triggers `backend-deploy.yml` when
`backend/**` changed and `frontend-deploy.yml` when `frontend/**` changed. Both
assume short-lived roles over OIDC; there are no stored AWS keys.

Deploy by hand only when CI is broken or the change is infrastructure:

```bash
cd terraform/envs/prod && tofu init -backend-config=backend.hcl

# Infrastructure changes. ALWAYS read the plan before applying.
tofu plan -out=tfplan
tofu apply tfplan

# Application code, from the repo root.
terraform/scripts/deploy_app.sh                 # backend then frontend
terraform/scripts/deploy_backend_service.sh     # backend only: push, migrate, roll
terraform/scripts/deploy_frontend.sh            # frontend only: build, sync, invalidate
```

`deploy_backend_service.sh` runs migrations **before** the new tasks start, so
the old code briefly runs against the new schema. Only ship additive migrations
— add a nullable column, backfill, then drop the old one in a later deploy.

## Rules

- **Read every plan before applying.** A destroy or replace on
  `aws_cloudfront_distribution`, `aws_s3_bucket.frontend`, or the RDS security
  group rule means something is wrong. Stop and report it rather than applying.
- **Never put a secret value in OpenTofu.** `variables.tf` creates empty
  Secrets Manager entries; values are written with the AWS CLI. Anything passed
  as a variable is readable in the state file forever.
- **Never commit `terraform.tfvars`, `backend.hcl`, or `.env`.** They are
  gitignored — keep it that way.
- **The ACM certificate must be in us-east-1**, whatever region everything else
  is in. CloudFront reads viewer certificates only from there.
- **Do not create a second GitHub OIDC provider.** One per issuer per account,
  and `aolf-warehouse` already created it. `create_github_oidc_provider` stays
  `false` unless deploying into a fresh account.
- **Confirm with the user before** `tofu destroy`, deleting a secret, changing
  `app_hostname`, or disabling a user account. These are hard to undo.

## Login credentials

There is no signup. Accounts are created by an operator, and the CLI runs as a
one-off Fargate task so nobody needs the database password locally:

```bash
export AOLF_NEW_PASSWORD='...'                  # 12+ characters
terraform/scripts/manage_users_task.sh create --email you@example.com --name "Your Name" --role admin
unset AOLF_NEW_PASSWORD

terraform/scripts/manage_users_task.sh list
terraform/scripts/manage_users_task.sh set-password --email someone@example.com
terraform/scripts/manage_users_task.sh disable --email someone@example.com
```

Roles are `admin` and `staff` (`backend/app/auth/roles.py`). `create` on an
existing email **resets that user's password** — say so before running it.

Ten failed attempts lock an account for fifteen minutes. Clear a lockout with
`set-password`, which resets the counter.

## Verify after every deploy

```bash
curl -sS "$(cd terraform/envs/prod && tofu output -raw app_url)/api/health"
```

Expect `{"app":"ok","database":"ok"}`. A `database: error` means the task
reached the API but not Postgres — check the security group rule and
`database-url`. Then load the site and sign in.

## When something breaks

Read [troubleshooting.md](references/troubleshooting.md). It covers the failures
this stack actually produces: tasks that start and immediately stop, 502s from
CloudFront, stale frontend after a deploy, `EntityAlreadyExists` on the OIDC
provider, and migration tasks that exit non-zero.

Logs, always the first stop:

```bash
cd terraform/envs/prod
aws logs tail "$(tofu output -raw backend_log_group_name)" \
  --region "$(tofu output -raw aws_region)" --since 30m --follow
```
