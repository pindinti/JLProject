-- REL-04: committed-state gate. Run in a new owner connection after each file.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
WITH phase AS (SELECT :'stage'::integer AS n), defs AS (
  SELECT pg_get_functiondef(to_regprocedure('public.guard_schedule_deletion()')) AS guard,
    pg_get_functiondef(to_regprocedure('public.clone_product(uuid,uuid,uuid,text)')) AS clone,
    pg_get_functiondef(to_regprocedure(
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)')) AS history
)
SELECT 1 / CASE WHEN current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND n BETWEEN 10 AND 27
  AND (n >= 11) = (to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NOT NULL)
  AND (n >= 13) = (to_regclass('public.workspace_calendar_versions') IS NOT NULL)
  AND (n >= 14) = EXISTS (SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.stage_activities'::regclass AND attname = 'planning_mode'
      AND NOT attisdropped)
  AND (n >= 17) = (to_regclass('public.calendar_reschedule_changes') IS NOT NULL)
  AND (n >= 18) = (to_regclass('public.calendar_reschedule_reversals') IS NOT NULL)
  AND (n >= 19) = (to_regprocedure('public.list_calendar_reschedule_history(uuid,uuid,uuid)') IS NOT NULL)
  AND (n >= 20) = (to_regclass('public.schedule_deletion_events') IS NOT NULL)
  AND (n >= 22) = (to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL)
  AND (n >= 23) = EXISTS (SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.stage_activities'::regclass AND attname = 'color_override'
      AND NOT attisdropped)
  AND (n >= 25) = EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stage_activities'::regclass
      AND conname = 'stage_activities_parent_pair_check' AND convalidated)
  AND (n >= 26) = (to_regclass('public.hierarchy_movement_events') IS NOT NULL)
  AND (n >= 27) = COALESCE(position('public.hierarchy_movement_events' IN history) > 0, false)
  AND (n < 11 OR EXISTS (SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.initial_schedule_revisions'::regclass
      AND attname = 'import_batch_id' AND NOT attnotnull))
  AND (n < 12 OR COALESCE(position('LOCK TABLE' IN clone) = 0, false))
  AND (n < 14 OR EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stage_activities'::regclass
      AND conname = 'stage_activities_planning_check' AND convalidated))
  AND (n < 15 OR has_table_privilege('jlproject_date_executor',
    'public.workspace_calendar_versions', 'SELECT'))
  AND (n < 16 OR has_column_privilege('jlproject_date_executor',
    'public.discipline_stages', 'discipline_id', 'SELECT'))
  AND (n <> 20 OR COALESCE(position(
    'IF TG_TABLE_NAME = ''discipline_stages'' AND NOT EXISTS' IN guard) > 0, false))
  AND (n < 21 OR COALESCE(position(
    'IF TG_TABLE_NAME = ''discipline_stages'' THEN' IN guard) > 0, false))
  AND (n < 23 OR COALESCE(position('color_override' IN clone) > 0, false))
  AND (n < 24 OR CASE WHEN n >= 24 THEN
    has_column_privilege('jlproject_worker', 'public.stage_activities',
      'color_override', 'INSERT') AND
    NOT has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT')
    ELSE true END)
  AND (n < 25 OR EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stage_activities'::regclass
      AND conname = 'stage_activities_product_scope_fk' AND convalidated))
  AND (n < 26 OR EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stage_activities'::regclass
      AND conname = 'stage_activities_parent_fk' AND convalidated AND condeferrable))
  AND (n < 26 OR (to_regprocedure(
    'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)') IS NOT NULL
    AND NOT has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')
    AND NOT has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')))
  AND (n < 27 OR (md5(history) = 'e8d5fca15b6f0d855c133bb960047a9c'
    AND has_function_privilege('jlproject_worker',
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE')
    AND NOT has_function_privilege('public',
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE')))
  THEN 1 ELSE 0 END AS committed_stage_gate
FROM phase CROSS JOIN defs;
ROLLBACK;
