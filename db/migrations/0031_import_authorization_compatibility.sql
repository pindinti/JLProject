BEGIN;

DO $preflight$
DECLARE
  v_import_function oid :=
    'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)'::regprocedure;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.stage_activities'::regclass) <> 'neondb_owner' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker'
       AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     pg_has_role('jlproject_worker', 'neon_superuser', 'member') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'UPDATE') OR
     NOT has_function_privilege('jlproject_worker', v_import_function, 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_import_function
       AND NOT prosecdef AND proconfig @> ARRAY['search_path=public, pg_catalog']) OR
     NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.stage_activities'::regclass
       AND NOT relrowsecurity AND NOT relforcerowsecurity) OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     to_regclass('public.stage_activities_source_id_unique_idx') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_activities'::regclass
         AND tgname = 'stage_activities_schedule_audit' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
         AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.product_schedule_operations'::regclass
         AND contype = 'u'
         AND pg_get_constraintdef(oid, true) =
           'UNIQUE (workspace_id, product_id, transaction_id)') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Import authorization preconditions differ from the reviewed Development contract.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY['workspace_id', 'product_id', 'discipline_id', 'stage_id',
      'name', 'activity_type', 'planned_start', 'planned_end', 'display_order', 'notes',
      'created_by', 'updated_by']) AS required_column(column_name)
    WHERE NOT has_column_privilege('jlproject_worker', 'public.stage_activities',
      required_column.column_name, 'INSERT')
  ) OR EXISTS (
    SELECT 1 FROM (VALUES
      ('workspaces'::regclass), ('workspace_memberships'::regclass),
      ('products'::regclass), ('product_disciplines'::regclass),
      ('stage_definitions'::regclass), ('discipline_stages'::regclass),
      ('stage_activities'::regclass), ('business_targets'::regclass),
      ('import_batches'::regclass), ('import_source_rows'::regclass),
      ('initial_schedule_revisions'::regclass)
    ) AS import_table(relation_id)
    WHERE NOT has_table_privilege('jlproject_worker', import_table.relation_id, 'SELECT')
  ) OR EXISTS (
    SELECT 1 FROM (VALUES
      ('products'::regclass), ('product_disciplines'::regclass),
      ('stage_definitions'::regclass), ('discipline_stages'::regclass),
      ('business_targets'::regclass), ('import_batches'::regclass),
      ('import_source_rows'::regclass), ('initial_schedule_revisions'::regclass)
    ) AS insert_table(relation_id)
    WHERE NOT has_table_privilege('jlproject_worker', insert_table.relation_id, 'INSERT')
  ) OR NOT has_column_privilege('jlproject_worker', 'public.workspaces', 'name', 'UPDATE') THEN
    RAISE EXCEPTION 'An import-path SELECT, INSERT, or workspace row-lock privilege is missing.';
  END IF;
END;
$preflight$;

-- The SECURITY INVOKER importer already writes this provenance column. This
-- column-only grant completes its existing privilege contract without granting
-- table-level activity INSERT or any UPDATE capability.
GRANT INSERT (source_external_id) ON public.stage_activities TO jlproject_worker;

DO $postcondition$
BEGIN
  IF NOT has_column_privilege('jlproject_worker', 'public.stage_activities',
       'source_external_id', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities',
       'source_external_id', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_function_privilege('jlproject_worker', 'public.capture_product_schedule_mutation()', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)',
       'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_activities'::regclass
         AND tgname = 'stage_activities_schedule_audit' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
         AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A')) THEN
    RAISE EXCEPTION 'Import grant exceeded its column scope or the audit/R00 protections changed.';
  END IF;
END;
$postcondition$;

COMMIT;
