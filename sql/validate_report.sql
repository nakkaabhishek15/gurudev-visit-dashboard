-- Validation queries for the Gurudev visit dashboard.
--
-- Each query reproduces, in plain SQL, a number the dashboard shows. Run them
-- against the warehouse and compare. If these agree with the dashboard, the app's
-- SQL is right. If they disagree with Retreat Guru, the *sync* is wrong -- these
-- queries cannot tell you that, because they read the same tables the app does.
--
-- Run through the SSM tunnel (.\connect.ps1 must be open in another window):
--
--   docker run --rm -i -e PGPASSWORD=<the DB_PASSWORD from .env> `
--     -v "${PWD}/sql:/sql:ro" postgres:16 `
--     psql -h host.docker.internal -p 5433 -U aolf_admin -d postgres -f /sql/validate_report.sql
--
-- Three details must match the app exactly or the numbers will drift:
--
--   * `status IS DISTINCT FROM 'cancelled'` -- not `<> 'cancelled'`. A NULL status
--     would make `<>` evaluate to NULL and silently drop the row.
--   * Geography comes from r.questions->'address', NOT from the person's profile
--     in retreat_guru_people. The two never disagree, but the profile is missing
--     for about a fifth of registrations -- reading it undercounts real provinces
--     and inflates (unknown). This is the bug that made BC show 3 instead of 5.
--   * COALESCE(NULLIF(BTRIM(...), ''), '(unknown)') -- blank strings and missing
--     people both land in one bucket, which is the bucket the dashboard draws.

\echo '=== 1. Registrations per programme, cancelled or not ==='
-- Compare with: the "Registrations" tile (162) and the include-cancelled toggle (167).
SELECT r.program_id,
       COUNT(*)                                                     AS all_statuses,
       COUNT(*) FILTER (WHERE r.status IS DISTINCT FROM 'cancelled') AS excluding_cancelled,
       COUNT(*) FILTER (WHERE r.status = 'cancelled')                AS cancelled
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
GROUP BY r.program_id
ORDER BY r.program_id;

\echo ''
\echo '=== 2. Province breakdown, per programme ==='
-- Compare with: the Province panel. Each bar is one (province, programme) pair.
SELECT COALESCE(NULLIF(BTRIM(r.questions->'address'->>'state'), ''), '(unknown)') AS province,
       r.program_id,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
GROUP BY province, r.program_id
ORDER BY COUNT(*) DESC, province;

\echo ''
\echo '=== 3. Province totals across both programmes ==='
SELECT COALESCE(NULLIF(BTRIM(r.questions->'address'->>'state'), ''), '(unknown)') AS province,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
GROUP BY province
ORDER BY COUNT(*) DESC, province;

\echo ''
\echo '=== 4. Country breakdown, per programme ==='
SELECT COALESCE(NULLIF(BTRIM(r.questions->'address'->>'country'), ''), '(unknown)') AS country,
       r.program_id,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
GROUP BY country, r.program_id
ORDER BY COUNT(*) DESC, country;

\echo ''
\echo '=== 5. City breakdown, per programme ==='
SELECT COALESCE(NULLIF(BTRIM(r.questions->'address'->>'city'), ''), '(unknown)') AS city,
       r.program_id,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
GROUP BY city, r.program_id
ORDER BY COUNT(*) DESC, city;

\echo ''
\echo '=== 6. Reconciliation: all three dimensions must equal the same total ==='
-- Every registration appears exactly once in each dimension, so all three
-- numbers must be identical and must equal query 1's excluding_cancelled sum.
-- If one differs, the dashboard is double-counting or dropping rows.
WITH base AS (
    SELECT r.registration_id,
           COALESCE(NULLIF(BTRIM(r.questions->'address'->>'state'), ''), '(unknown)')   AS province,
           COALESCE(NULLIF(BTRIM(r.questions->'address'->>'city'), ''), '(unknown)')    AS city,
           COALESCE(NULLIF(BTRIM(r.questions->'address'->>'country'), ''), '(unknown)') AS country
    FROM raw_data.retreat_guru_registrations r
    WHERE r.program_id IN ('4521', '4522')
      AND r.status IS DISTINCT FROM 'cancelled'
)
SELECT (SELECT SUM(n) FROM (SELECT COUNT(*) n FROM base GROUP BY province) x) AS province_total,
       (SELECT SUM(n) FROM (SELECT COUNT(*) n FROM base GROUP BY city) y)     AS city_total,
       (SELECT SUM(n) FROM (SELECT COUNT(*) n FROM base GROUP BY country) z)  AS country_total,
       (SELECT COUNT(*) FROM base)                                           AS registrations;

\echo ''
\echo '=== 7. Drill-down: who is behind one province ==='
-- The rows behind a single bar, so a count can be checked name by name against
-- Retreat Guru. Change the province code to audit a different bar.
SELECT r.program_id,
       r.status,
       r.full_name,
       r.questions->'address'->>'city'    AS city,
       r.questions->'address'->>'state'   AS province,
       r.questions->'address'->>'country' AS country
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
  AND BTRIM(r.questions->'address'->>'state') = 'AB'
ORDER BY r.program_id, r.full_name;

\echo ''
\echo '=== 8. Data quality: registrations with a blank address answer ==='
-- These are the (unknown) bars. Should now be small or empty; before the fix this
-- also swallowed every registration whose person profile was missing.
SELECT r.program_id, COUNT(*) AS blank_address
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
  AND NULLIF(BTRIM(r.questions->'address'->>'state'), '') IS NULL
GROUP BY r.program_id
ORDER BY r.program_id;

\echo ''
\echo '=== 8b. Registration answer vs person profile, side by side ==='
-- Proof the switch was safe: rows where both are present must agree. Rows where
-- from_person is blank are exactly what the old query was throwing away.
SELECT COALESCE(NULLIF(BTRIM(r.questions->'address'->>'state'), ''), '(blank)') AS from_registration,
       COALESCE(NULLIF(BTRIM(p.address->>'state'), ''), '(blank)')                  AS from_person,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
LEFT JOIN raw_data.retreat_guru_people p ON p.person_id = r.person_id
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
GROUP BY from_registration, from_person
ORDER BY registrations DESC;

\echo ''
\echo '=== 9. Data quality: city names that differ only by case or spacing ==='
-- Retreat Guru does not normalise city names, so "kelowna" and "Kelowna" are two
-- separate bars splitting one city. Any row returned here means the City chart
-- understates that place. Province and Country are two-letter codes, so they are
-- far less exposed to this.
SELECT LOWER(BTRIM(r.questions->'address'->>'city')) AS normalised,
       COUNT(DISTINCT BTRIM(r.questions->'address'->>'city')) AS spelling_variants,
       STRING_AGG(DISTINCT BTRIM(r.questions->'address'->>'city'), ' | ') AS variants_found,
       COUNT(*) AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
  AND NULLIF(BTRIM(r.questions->'address'->>'city'), '') IS NOT NULL
GROUP BY normalised
HAVING COUNT(DISTINCT BTRIM(r.questions->'address'->>'city')) > 1
ORDER BY registrations DESC;

\echo ''
\echo '=== 10. Data quality: province code that disagrees with its country ==='
-- A Canadian province code against country US (or the reverse) means one of the
-- two fields is wrong. Also catches the CA ambiguity: CA is California in the
-- province field and Canada in the country field.
SELECT r.questions->'address'->>'country' AS country,
       r.questions->'address'->>'state'   AS province,
       COUNT(*)              AS registrations
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled'
  AND NULLIF(BTRIM(r.questions->'address'->>'state'), '') IS NOT NULL
GROUP BY country, province
ORDER BY country, province;

\echo ''
\echo '=== 11. How stale is the snapshot? ==='
-- The dashboard reads a copy, not Retreat Guru itself. If this is hours or days
-- old, a disagreement with Retreat Guru may be lag rather than error.
SELECT 'registrations' AS table_name, MAX(ingested_at) AS last_ingested, COUNT(*) AS rows
FROM raw_data.retreat_guru_registrations
UNION ALL
SELECT 'programs', MAX(ingested_at), COUNT(*) FROM raw_data.retreat_guru_programs;

\echo ''
\echo '=== 12. Registrations vs people ==='
-- The dashboard counts registrations. Someone signed up for both programmes is
-- two registrations and one person, so these two numbers are not the same claim.
SELECT COUNT(*)                       AS registrations,
       COUNT(DISTINCT r.person_id)    AS distinct_people,
       COUNT(*) - COUNT(DISTINCT r.person_id) AS people_counted_twice
FROM raw_data.retreat_guru_registrations r
WHERE r.program_id IN ('4521', '4522')
  AND r.status IS DISTINCT FROM 'cancelled';
