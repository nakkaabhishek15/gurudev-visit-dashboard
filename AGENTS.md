# Working in this repository

## What this is

A small internal website with password login. FastAPI backend, SvelteKit static
frontend, Postgres on an existing AWS RDS instance, deployed to ECS Fargate and
CloudFront with OpenTofu.

## Commands

```bash
docker compose up --build                    # everything, locally
docker compose exec -T backend pytest        # needs AOLF_TEST_DATABASE_URL
docker compose exec -T frontend npm run check
tofu fmt -recursive terraform                # before committing any .tf change
```

## Conventions

- Python targets 3.11. `from __future__ import annotations` at the top of every
  module; type hints on every function signature.
- SQL lives in the module that owns the table, written with `psycopg` parameter
  binding. Never build SQL with f-strings or `%` formatting.
- Svelte 5 runes (`$state`, `$derived`, `$props`), not the Svelte 4 store syntax.
- Comments explain *why*, at points where the reason is not evident from the
  code. Skip the ones that restate the line below.

## Rules that matter

- **Every new API route goes behind `require_auth`.** Mount it on the protected
  router in `backend/app/main.py`. `/health` is the one deliberate exception.
- **Never edit an applied migration.** `MIGRATIONS` in
  `backend/app/db/migrations.py` is forward-only — its keys are recorded in
  `app.schema_migrations` and an edited entry will not re-run. Add a new one.
- **Migrations must be backward compatible.** They run before the new tasks
  start, so the previous code briefly serves traffic against the new schema.
- **Never put a secret in OpenTofu or in a committed file.** Secrets Manager
  entries are created empty; values are written with the AWS CLI.
- **Client-side route guards are not security.** `+page.ts` redirects are a
  convenience; enforcement is `require_auth` and `require_admin` on the API.
- Frontend calls the API through `$lib/api`, with relative `/api/...` paths.
  Absolute URLs break the CloudFront routing.

## Deploying

Use the `deploy-aws` skill in `.claude/skills/`. Read it before running any
`tofu` command or deploy script — it covers the ordering constraints and the
things that are hard to undo.
