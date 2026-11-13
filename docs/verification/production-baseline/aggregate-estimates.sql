-- Approximate table statistics only. Not executed by the repository review.
-- Use after catalog.sql, with the approved restricted read-only role.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '10s';
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
)
SELECT e.schema_name, e.relation_name, s.n_live_tup AS estimated_live_rows,
       s.n_dead_tup AS estimated_dead_rows, s.last_analyze, s.last_autoanalyze,
       CASE WHEN c.oid IS NULL THEN 'NOT PRESENT'
            WHEN s.relid IS NULL THEN 'PRESENT; NO STATISTICS ROW'
            ELSE 'APPROXIMATE' END AS interpretation
FROM expected AS e
LEFT JOIN pg_namespace AS n ON n.nspname = e.schema_name
LEFT JOIN pg_class AS c ON c.relnamespace = n.oid AND c.relname = e.relation_name
LEFT JOIN pg_stat_user_tables AS s ON s.relid = c.oid
ORDER BY e.schema_name, e.relation_name;

ROLLBACK;
