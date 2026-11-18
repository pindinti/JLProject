-- Read-only Development checks for migration 0031 postconditions.
\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $postflight$
DECLARE
  v_import_function oid :=
    'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)'::regprocedure;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities',
       'source_external_id', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities',
       'source_external_id', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     NOT has_function_privilege('jlproject_worker', v_import_function, 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_import_function
       AND NOT prosecdef AND proconfig @> ARRAY['search_path=public, pg_catalog']) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_schema_privilege('jlproject_worker', 'public', 'CREATE') OR
     has_function_privilege('jlproject_worker', 'public.capture_product_schedule_mutation()', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)',
       'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_state', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') OR
     NOT has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'INSERT') OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_activities'::regclass
         AND tgname = 'stage_activities_schedule_audit' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
         AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A')) THEN
    RAISE EXCEPTION 'Migration 0031 postconditions or approved Worker restrictions are not satisfied.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY['workspace_id', 'product_id', 'discipline_id', 'stage_id',
      'name', 'activity_type', 'planned_start', 'planned_end', 'display_order', 'notes',
      'created_by', 'updated_by']) AS allowed_column(column_name)
    WHERE NOT has_column_privilege('jlproject_worker', 'public.stage_activities',
      allowed_column.column_name, 'INSERT')
  ) OR EXISTS (
    SELECT 1 FROM unnest(ARRAY['planning_mode', 'working_day_duration',
      'planning_calendar_version']) AS restricted_column(column_name)
    WHERE has_column_privilege('jlproject_worker', 'public.stage_activities',
      restricted_column.column_name, 'INSERT')
  ) THEN
    RAISE EXCEPTION 'Existing stage activity column-level INSERT grants changed unexpectedly.';
  END IF;
END;
$postflight$;

SELECT jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
  'sourceExternalId', jsonb_build_object(
    'insert', has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'INSERT'),
    'update', has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'UPDATE')),
  'stageActivitiesTable', jsonb_build_object(
    'insert', has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT'),
    'update', has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE'),
    'delete', has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE')),
  'plannedDateUpdates', jsonb_build_object(
    'start', has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE'),
    'end', has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE')),
  'planningFieldInsert', jsonb_build_object(
    'mode', has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT'),
    'workingDayDuration', has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'INSERT'),
    'calendarVersion', has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'INSERT')),
  'importFunction', (SELECT jsonb_build_object(
    'securityDefiner', procedure_row.prosecdef,
    'configuration', procedure_row.proconfig,
    'workerExecute', has_function_privilege('jlproject_worker', procedure_row.oid, 'EXECUTE'))
    FROM pg_proc AS procedure_row WHERE procedure_row.oid =
      'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)'::regprocedure),
  'auditAndR00', jsonb_build_object(
    'sourceEventsTable', to_regclass('public.product_schedule_operation_source_events') IS NOT NULL,
    'activityAuditTrigger', EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.stage_activities'::regclass
        AND tgname = 'stage_activities_schedule_audit' AND tgenabled IN ('O', 'A')),
    'r00Insert', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'INSERT'),
    'r00Update', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE'),
    'r00Delete', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE'),
    'r00ImmutableTrigger', EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
        AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A')))
) AS import_authorization_postflight;

ROLLBACK;
