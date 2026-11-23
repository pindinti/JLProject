\set ON_ERROR_STOP on

BEGIN READ ONLY;

SELECT current_database() AS database_name, current_user AS connected_role,
  current_setting('transaction_read_only') AS read_only;

SELECT conrelid::regclass AS relation, conname, convalidated, pg_get_constraintdef(oid) AS definition
FROM pg_catalog.pg_constraint
WHERE conrelid IN ('public.products'::regclass, 'public.discipline_stages'::regclass,
  'public.stage_activities'::regclass, 'public.initial_schedule_revisions'::regclass,
  'public.activity_date_changes'::regclass, 'public.stage_date_changes'::regclass,
  'public.product_schedule_operations'::regclass, 'public.product_schedule_operation_source_events'::regclass)
  AND (contype IN ('p', 'u') OR (conrelid = 'public.initial_schedule_revisions'::regclass AND contype = 'c'))
ORDER BY conrelid::regclass::text, conname;

SELECT tgrelid::regclass AS relation, tgname, tgenabled, tgdeferrable, tginitdeferred,
  pg_get_triggerdef(oid) AS definition
FROM pg_catalog.pg_trigger
WHERE NOT tgisinternal AND tgrelid IN ('public.initial_schedule_revisions'::regclass,
  'public.activity_date_changes'::regclass, 'public.stage_date_changes'::regclass,
  'public.stage_activities'::regclass, 'public.discipline_stages'::regclass)
ORDER BY tgrelid::regclass::text, tgname;

WITH functions AS (
  SELECT p.oid, p.proname, p.proowner, p.proconfig, p.prosecdef, pg_get_functiondef(p.oid) AS definition
  FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN ('apply_calendar_reschedule', 'change_activity_dates',
    'change_activity_planning', 'change_discipline_stage_dates', 'change_product_status',
    'change_workspace_calendar', 'clone_product', 'clone_root_activity', 'clone_stage_activity',
    'create_activity_with_working_plan', 'create_discipline_stage_with_dates', 'delete_schedule_subtree',
    'import_initial_schedule', 'link_product_schedule_audit_source', 'list_product_change_history',
    'move_schedule_item', 'reverse_calendar_reschedule', 'write_product_schedule_operation_event')
)
SELECT oid::regprocedure AS signature, pg_get_userbyid(proowner) AS owner, prosecdef, proconfig,
  has_function_privilege('jlproject_worker', oid, 'EXECUTE') AS worker_execute,
  position('FOR UPDATE' IN definition) > 0 AS contains_update_lock, md5(definition) AS definition_fingerprint
FROM functions
ORDER BY proname, oid::regprocedure::text;

SELECT p.oid::regprocedure AS baseline_function,
  position('INSERT INTO public.initial_schedule_revisions' IN p.prosrc) > 0 AS inserts_baseline,
  position('''dependencies'', ''[]''::jsonb' IN p.prosrc) > 0 AS initializes_empty_dependencies
FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosrc ILIKE '%initial_schedule_revisions%'
ORDER BY p.oid::regprocedure::text;

SELECT count(*) AS baseline_count,
  count(*) FILTER (WHERE snapshot->'dependencies' = '[]'::jsonb) AS empty_dependency_arrays,
  has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') AS worker_baseline_update,
  has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') AS worker_baseline_delete,
  to_regclass('public.product_schedule_dependencies') IS NULL AS dependency_table_absent
FROM public.initial_schedule_revisions;

COMMIT;
