# Gurudev Visit Dashboard

A small internal website: password login, role-based pages, and a FastAPI
backend on top of the existing AOLF Postgres instance in AWS.

Two halves behind one CloudFront distribution — `/api/*` goes to a FastAPI
container on ECS Fargate, everything else is a static SvelteKit build in S3.

## Local setup

```bash
docker compose up --build
```

That starts Postgres, applies migrations, and serves the API on
`http://127.0.0.1:8000` and the site on `http://127.0.0.1:5173`.

Create yourself a login:

```bash
docker compose exec backend python -m app.cli.manage_users \
  create --email you@example.com --name "Your Name" --role admin
```

Then sign in at `http://127.0.0.1:5173`.

The Gurudev visit report reads the AOLF warehouse, which is private to its VPC.
Open the tunnel in a second window first, and leave it running:

```powershell
.\connect.ps1
```

That forwards `localhost:5433` to the RDS instance through the `ssm-rds-jump`
host. `WAREHOUSE_DATABASE_URL` in `.env` points the backend container at it.
Without the tunnel the report shows a connection error; the rest of the app is
unaffected.

## Checks

```bash
docker compose exec -T postgres createdb -U postgres gurudev_test || true
docker compose exec -T -e AOLF_TEST_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/gurudev_test \
  backend pytest
docker compose exec -T frontend npm run check
docker compose exec -T frontend npm test
docker compose exec -T frontend npm run build
```

Backend tests need a real Postgres — they skip, loudly, without
`AOLF_TEST_DATABASE_URL`.

## Deploying

Push to `main`. CI builds, migrates, and rolls the service using short-lived
AWS credentials over OIDC.

For anything else — first-time setup, infrastructure changes, creating
production logins, or a failed deploy — ask Claude to deploy and it will follow
the `deploy-aws` skill in `.claude/skills/`. The same documents are readable by
hand:

- [`.claude/skills/deploy-aws/SKILL.md`](.claude/skills/deploy-aws/SKILL.md) — day-to-day deploys and rules
- [`references/first-time-setup.md`](.claude/skills/deploy-aws/references/first-time-setup.md) — one-time bootstrap
- [`references/troubleshooting.md`](.claude/skills/deploy-aws/references/troubleshooting.md) — when it breaks

## Layout

```
backend/app/auth/        password hashing, sessions, roles
backend/app/api/         application endpoints (all behind require_auth)
backend/app/api/reports.py   Retreat Guru reporting queries
backend/app/db/          connection helper and forward-only migrations
backend/app/cli/         user management, run as a one-off task in AWS
frontend/src/routes/     login, dashboard, and the Gurudev visit report
frontend/src/lib/reports/    report rendering and its stylesheet
terraform/envs/prod/     the AWS stack
terraform/scripts/       deploy and operational scripts
```

## Notes

- There is no signup. An operator creates every account.
- The RDS instance belongs to the `aolf-warehouse` OpenTofu state. This stack
  reads it and adds one security group rule; it never manages the database.
- The ECS cluster and the load balancer are shared with the aolf stack too. A
  cluster is a free logical grouping, and a second load balancer would be about
  $20 a month for an internal dashboard. This stack adds a target group, a
  host-header listener rule, and a service; the listener's default action, which
  serves the aolf app, is untouched.
- Reports read the warehouse over a second, read-only connection
  (`WAREHOUSE_DATABASE_URL`). Locally that is the SSM tunnel from `connect.ps1`;
  in AWS it is a `gurudev_reader` role with SELECT on three tables. See
  `terraform/scripts/warehouse_reader.sql`.
- Secret values are written with the AWS CLI, never through OpenTofu, so they
  stay out of the state file.
