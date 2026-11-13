-- Opt-in exact counts. Not executed by the repository review.
-- COUNT(*) reads table data; obtain DBA approval after reviewing estimates.
-- psql is required for \gexec. A confirmed absent relation is reported explicitly.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';

WITH expected(schema_name, relation_name) AS (
  VALUES
    ('public', 'workspaces'),
    ('public', 'workspace_memberships'),
    ('public', 'products'),
    ('public', 'product_disciplines'),
    ('public', 'stage_definitions'),
    ('public', 'discipline_stages'),
    ('public', 'stage_activities'),
    ('public', 'business_targets'),
    ('public', 'import_batches'),
    ('public', 'import_source_rows'),
    ('public', 'initial_schedule_revisions'),
    ('public', 'activity_date_changes'),
    ('public', 'business_target_date_changes'),
    ('public', 'workspace_calendar_versions'),
    ('public', 'workspace_calendar_exceptions'),
    ('public', 'workspace_calendar_events'),
    ('public', 'calendar_reschedule_changes'),
    ('public', 'calendar_reschedule_reversals'),
    ('public', 'schedule_deletion_events'),
    ('public', 'hierarchy_movement_events'),
    ('neon_auth', 'user')
), resolved AS (
  SELECT e.schema_name, e.relation_name, c.oid::regclass AS relation_oid, c.relkind
  FROM expected AS e
  LEFT JOIN pg_namespace AS n ON n.nspname = e.schema_name
  LEFT JOIN pg_class AS c ON c.relnamespace = n.oid AND c.relname = e.relation_name
)
SELECT CASE WHEN relation_oid IS NULL THEN
         format('SELECT %L AS relation_name, NULL::bigint AS exact_rows, %L AS result;',
           schema_name || '.' || relation_name, 'NOT PRESENT')
       WHEN relkind NOT IN ('r', 'p') THEN
         format('SELECT %L AS relation_name, NULL::bigint AS exact_rows, %L AS result;',
           schema_name || '.' || relation_name, 'UNEXPECTED RELKIND ' || relkind)
       ELSE
         format('SELECT %L AS relation_name, count(*)::bigint AS exact_rows, %L AS result FROM %s;',
           schema_name || '.' || relation_name, 'COUNTED', relation_oid)
       END AS generated_read_only_query
FROM resolved
ORDER BY schema_name, relation_name
\gexec

ROLLBACK;
