-- Aggregate-only data-integrity indicators for the schema shape through 0027.
-- Not executed by the repository review. Run only after catalog.sql confirms
-- every referenced relation and column, and the DBA approves the scan cost.
\set ON_ERROR_STOP on

-- Each SELECT is independently bounded. A timeout or error is UNKNOWN, not a pass.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'workspaces_without_active_admin' AS check_name, count(*) AS violating_rows
FROM public.workspaces AS w
WHERE NOT EXISTS (
  SELECT 1 FROM public.workspace_memberships AS m
  WHERE m.workspace_id = w.id AND m.active AND m.role = 'admin'
);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'memberships_without_workspace_or_auth_identity' AS check_name,
       count(*) AS violating_rows
FROM public.workspace_memberships AS m
WHERE NOT EXISTS (SELECT 1 FROM public.workspaces AS w WHERE w.id = m.workspace_id)
   OR NOT EXISTS (SELECT 1 FROM neon_auth."user" AS u WHERE u.id = m.auth_user_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'products_without_workspace' AS check_name, count(*) AS violating_rows
FROM public.products AS p
WHERE NOT EXISTS (SELECT 1 FROM public.workspaces AS w WHERE w.id = p.workspace_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'disciplines_outside_product_scope' AS check_name, count(*) AS violating_rows
FROM public.product_disciplines AS d
WHERE NOT EXISTS (SELECT 1 FROM public.products AS p
  WHERE p.workspace_id = d.workspace_id AND p.id = d.product_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'stages_outside_parent_scope' AS check_name, count(*) AS violating_rows
FROM public.discipline_stages AS s
WHERE NOT EXISTS (SELECT 1 FROM public.product_disciplines AS d
    WHERE d.workspace_id = s.workspace_id AND d.product_id = s.product_id
      AND d.id = s.discipline_id)
   OR NOT EXISTS (SELECT 1 FROM public.stage_definitions AS sd
    WHERE sd.workspace_id = s.workspace_id AND sd.id = s.definition_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'activities_outside_product_or_parent_scope' AS check_name,
       count(*) AS violating_rows
FROM public.stage_activities AS a
LEFT JOIN public.discipline_stages AS s
  ON s.workspace_id = a.workspace_id AND s.product_id = a.product_id
 AND s.discipline_id = a.discipline_id AND s.id = a.stage_id
WHERE NOT EXISTS (SELECT 1 FROM public.products AS p
    WHERE p.workspace_id = a.workspace_id AND p.id = a.product_id)
   OR ((a.discipline_id IS NULL) <> (a.stage_id IS NULL))
   OR (a.stage_id IS NOT NULL AND (s.id IS NULL OR s.discipline_id IS DISTINCT FROM a.discipline_id));
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'activity_dates_with_invalid_pair_or_order' AS check_name,
       count(*) AS violating_rows
FROM public.stage_activities AS a
WHERE (a.planned_start IS NULL) <> (a.planned_end IS NULL)
   OR (a.planned_start IS NOT NULL AND a.planned_end IS NOT NULL
       AND a.planned_start > a.planned_end);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'targets_outside_product_scope' AS check_name, count(*) AS violating_rows
FROM public.business_targets AS t
WHERE NOT EXISTS (SELECT 1 FROM public.products AS p
  WHERE p.workspace_id = t.workspace_id AND p.id = t.product_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'import_rows_outside_batch_product_scope' AS check_name,
       count(*) AS violating_rows
FROM public.import_source_rows AS source_row
JOIN public.import_batches AS batch ON batch.id = source_row.import_batch_id
WHERE (source_row.activity_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.stage_activities AS activity
    WHERE activity.workspace_id = batch.workspace_id AND activity.product_id = batch.product_id
      AND activity.id = source_row.activity_id))
   OR (source_row.target_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.business_targets AS target
    WHERE target.workspace_id = batch.workspace_id AND target.product_id = batch.product_id
      AND target.id = source_row.target_id));
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'initial_revisions_outside_product_or_import_scope' AS check_name,
       count(*) AS violating_rows
FROM public.initial_schedule_revisions AS revision
WHERE NOT EXISTS (SELECT 1 FROM public.products AS product
    WHERE product.workspace_id = revision.workspace_id AND product.id = revision.product_id)
   OR NOT EXISTS (SELECT 1 FROM public.import_batches AS batch
    WHERE batch.workspace_id = revision.workspace_id AND batch.product_id = revision.product_id
      AND batch.id = revision.import_batch_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'activity_date_audit_without_scoped_activity_or_membership' AS check_name,
       count(*) AS violating_rows
FROM public.activity_date_changes AS c
WHERE NOT EXISTS (SELECT 1 FROM public.stage_activities AS a
    WHERE a.workspace_id = c.workspace_id AND a.product_id = c.product_id
      AND a.id = c.activity_id)
   OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = c.workspace_id AND m.auth_user_id = c.actor_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'target_date_audit_without_target_or_membership' AS check_name,
       count(*) AS violating_rows
FROM public.business_target_date_changes AS c
WHERE NOT EXISTS (SELECT 1 FROM public.business_targets AS t
    WHERE t.workspace_id = c.workspace_id AND t.product_id = c.product_id
      AND t.id = c.target_id)
   OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = c.workspace_id AND m.auth_user_id = c.actor_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'calendar_exceptions_with_invalid_workspace_or_dates' AS check_name,
       count(*) AS violating_rows
FROM public.workspace_calendar_exceptions AS e
WHERE NOT EXISTS (SELECT 1 FROM public.workspaces AS w WHERE w.id = e.workspace_id)
   OR e.end_date < e.start_date;
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'calendar_events_without_exception_or_membership' AS check_name,
       count(*) AS violating_rows
FROM public.workspace_calendar_events AS e
WHERE NOT EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS x
    WHERE x.workspace_id = e.workspace_id AND x.id = e.exception_id)
   OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = e.workspace_id AND m.auth_user_id = e.actor_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'calendar_reschedule_without_date_audit' AS check_name,
       count(*) AS violating_rows
FROM public.calendar_reschedule_changes AS c
WHERE NOT EXISTS (SELECT 1 FROM public.activity_date_changes AS d
  WHERE d.operation_id = c.date_operation_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'calendar_reversal_without_original_reschedule_or_date_audit' AS check_name,
       count(*) AS violating_rows
FROM public.calendar_reschedule_reversals AS r
WHERE NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes AS c
    WHERE c.date_operation_id = r.original_date_operation_id)
   OR NOT EXISTS (SELECT 1 FROM public.activity_date_changes AS d
    WHERE d.operation_id = r.reversal_date_operation_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'deletion_events_without_product_or_membership' AS check_name,
       count(*) AS violating_rows
FROM public.schedule_deletion_events AS e
WHERE NOT EXISTS (SELECT 1 FROM public.products AS p
    WHERE p.workspace_id = e.workspace_id AND p.id = e.product_id)
   OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = e.workspace_id AND m.auth_user_id = e.actor_id);
ROLLBACK;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';
SELECT 'movement_events_without_product_or_membership' AS check_name,
       count(*) AS violating_rows
FROM public.hierarchy_movement_events AS e
WHERE NOT EXISTS (SELECT 1 FROM public.products AS p
    WHERE p.workspace_id = e.workspace_id AND p.id = e.product_id)
   OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = e.workspace_id AND m.auth_user_id = e.actor_id);
ROLLBACK;
