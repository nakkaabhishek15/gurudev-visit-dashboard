# First-time setup

Run once per environment. Roughly 45 minutes, most of it waiting on the ACM
validation and the first CloudFront deployment.

Do these in order. Several steps depend on the one before.

## 1. Decide the names

| Thing | Example | Constraint |
|---|---|---|
| `app_name` | `gurudev` | Under 12 chars — ALB and target group names cap at 32 total |
| `frontend_bucket_name` | `gurudev-frontend-prod-716156543359` | Globally unique across all of AWS |
| `app_hostname` | `site.devopsagent.com` | You must control the DNS zone |
| `github_repository` | `nakkaabhishek15/gurudev-visit-dashboard` | `owner/name`, must match exactly |

## 2. Request the ACM certificate — in us-east-1

CloudFront ignores certificates in any other region. This is the single most
common setup mistake.

```bash
aws acm request-certificate \
  --region us-east-1 \
  --domain-name site.devopsagent.com \
  --validation-method DNS \
  --query CertificateArn --output text
```

Get the validation record and add it to DNS:

```bash
aws acm describe-certificate --region us-east-1 --certificate-arn <arn> \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

Wait for `Status: ISSUED` before applying. OpenTofu fails on a `PENDING_VALIDATION`
certificate.

## 3. Fill in the config files

```bash
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edit `terraform.tfvars` with the names from step 1 and the certificate ARN from
step 2. Both files are gitignored — never commit them.

Confirm the network defaults in `variables.tf` still match the AWS account:
`vpc_id`, `app_subnet_ids`, `rds_security_group_id`. They point at the VPC that
holds the existing AOLF RDS instance. Check with:

```bash
aws rds describe-db-instances --db-instance-identifier aolf \
  --query 'DBInstances[0].{vpc:DBSubnetGroup.VpcId,sg:VpcSecurityGroups[0].VpcSecurityGroupId}'
```

## 4. Create the database

The app needs its own logical database on the shared instance, so its tables
never collide with the warehouse. Connect through the existing SSM jump path (a
laptop cannot reach RDS directly — it is not publicly accessible), then:

```sql
CREATE DATABASE gurudev;
CREATE USER gurudev_app WITH PASSWORD '<generate a strong one>';
GRANT ALL PRIVILEGES ON DATABASE gurudev TO gurudev_app;
```

Give the app its own user, not the RDS master account. A compromise of this app
should not reach the warehouse database.

## 5. First apply

```bash
tofu init -backend-config=backend.hcl
tofu plan -out=tfplan
```

Read the plan. Expect roughly 35 resources created and **zero destroyed**. Any
destroy at this stage means the state key collides with another stack — stop.

```bash
tofu apply tfplan
```

CloudFront takes 5–15 minutes. That is normal.

## 6. Write the secret values

OpenTofu created the secret containers empty. Fill them now — the ECS task will
not start without them.

```bash
aws secretsmanager put-secret-value \
  --secret-id /gurudev/prod/database-url \
  --secret-string 'postgresql://gurudev_app:<password>@<rds-endpoint>:5432/gurudev'

aws secretsmanager put-secret-value \
  --secret-id /gurudev/prod/auth/session-secret \
  --secret-string "$(python -c 'import secrets; print(secrets.token_urlsafe(64))')"
```

The session secret signs login cookies. Rotating it signs every user out — which
is exactly what you want if it ever leaks.

## 7. Point DNS at CloudFront

```bash
tofu output -raw cloudfront_domain_name
```

Create a CNAME (or Route 53 alias A record) from `app_hostname` to that value.
Alias is better if the zone is in Route 53: no CNAME-at-apex problem, no extra
lookup.

## 8. First deploy

From the repo root:

```bash
terraform/scripts/deploy_app.sh
```

This builds and pushes the image, runs migrations to create the `app` schema,
rolls the service, then builds and publishes the frontend.

Check it came up:

```bash
curl -sS https://site.devopsagent.com/api/health
```

## 9. Create the first login

```bash
export AOLF_NEW_PASSWORD='<12+ characters, from a password manager>'
terraform/scripts/manage_users_task.sh create \
  --email you@artofliving.ca --name "Your Name" --role admin
unset AOLF_NEW_PASSWORD
```

Sign in at `https://site.devopsagent.com`. If that works, setup is done.

## 10. Wire up CI

```bash
tofu output -raw github_actions_backend_role_arn
tofu output -raw github_actions_frontend_role_arn
```

Put those into `AWS_ROLE_TO_ASSUME` in `.github/workflows/backend-deploy.yml`
and `frontend-deploy.yml`, then commit. The placeholder ARNs in those files
assume the default `app_name` and account.

## Deploying into a brand-new AWS account

Three extra things:

1. Set `create_github_oidc_provider = true` — no provider exists yet.
2. Create the OpenTofu state bucket first (versioned, encrypted, public access
   blocked), and update `backend.hcl` plus `opentofu_state_bucket_name`.
3. There is no existing RDS instance. Add an `aws_db_instance` to this stack —
   at which point this stack owns it, and the warning in SKILL.md about not
   managing RDS no longer applies.
