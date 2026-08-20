-- Read-only warehouse role for the dashboard's reporting endpoints.
--
-- Run once against the aolf instance, as a user that can create roles, through
-- the SSM tunnel (see connect.ps1). Replace the password before running, then
-- store the resulting URL in Secrets Manager as /gurudev/prod/warehouse-database-url:
--
--   postgresql://gurudev_reader:<password>@aolf.cpgy4w88a8cb.ca-central-1.rds.amazonaws.com:5432/postgres
--
-- The app must not reach the warehouse as aolf_admin. These endpoints only ever
-- run SELECT against three tables, so that is all the role is granted -- a bug in
-- report SQL then cannot reach anything else, let alone write.

CREATE ROLE gurudev_reader WITH LOGIN PASSWORD 'REPLACE-ME';

GRANT CONNECT ON DATABASE postgres TO gurudev_reader;
GRANT USAGE ON SCHEMA raw_data TO gurudev_reader;

GRANT SELECT ON raw_data.retreat_guru_programs      TO gurudev_reader;
GRANT SELECT ON raw_data.retreat_guru_registrations TO gurudev_reader;
GRANT SELECT ON raw_data.retreat_guru_people        TO gurudev_reader;

-- Deliberately no ALTER DEFAULT PRIVILEGES: a new table appearing in raw_data
-- should not become readable by the dashboard without someone deciding it should.

-- Verify, as the new role:
--   SELECT COUNT(*) FROM raw_data.retreat_guru_registrations;  -- expect a number
--   SELECT COUNT(*) FROM raw_data.retreat_guru_payments;       -- expect permission denied
