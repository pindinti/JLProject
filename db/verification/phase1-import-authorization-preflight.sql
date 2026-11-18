-- Read-only inspection of the Development import privilege path before migration 0031.
\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $target$
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     to_regprocedure('public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)') IS NULL OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     to_regclass('public.stage_date_changes') IS NULL THEN
    RAISE EXCEPTION 'Unexpected Development target or missing Phase 1 import/audit objects.';
  END IF;
END;
$target$;

SELECT jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
  'workerRole', (
    SELECT jsonb_build_object('login', worker.rolcanlogin, 'superuser', worker.rolsuper,
      'createRole', worker.rolcreaterole, 'createDatabase', worker.rolcreatedb,
      'inheritsExecutor', pg_has_role(worker.oid, 'jlproject_date_executor', 'member'),
      'publicSchemaCreate', has_schema_privilege(worker.oid, 'public', 'CREATE'))
    FROM pg_roles AS worker WHERE worker.rolname = 'jlproject_worker'
  ),
  'importFunction', (
    SELECT jsonb_build_object('owner', pg_get_userbyid(function_row.proowner),
      'securityDefiner', function_row.prosecdef,
      'configuration', function_row.proconfig,
      'workerExecute', has_function_privilege('jlproject_worker', function_row.oid, 'EXECUTE'),
      'definitionInsertsSourceExternalId',
        position('source_external_id' IN pg_get_functiondef(function_row.oid)) > 0,
      'definitionChecksActiveWriterMembership',
        position('role IN (''admin'', ''editor'')' IN pg_get_functiondef(function_row.oid)) > 0)
    FROM pg_proc AS function_row
    WHERE function_row.oid =
      'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)'::regprocedure
  ),
  'importPathTables', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('table', relation.relname,
      'owner', pg_get_userbyid(relation.relowner),
      'select', has_table_privilege('jlproject_worker', relation.oid, 'SELECT'),
      'tableInsert', has_table_privilege('jlproject_worker', relation.oid, 'INSERT'),
      'update', has_table_privilege('jlproject_worker', relation.oid, 'UPDATE'),
      'delete', has_table_privilege('jlproject_worker', relation.oid, 'DELETE'),
      'rowSecurity', relation.relrowsecurity, 'forceRowSecurity', relation.relforcerowsecurity)
      ORDER BY relation.relname), '[]'::jsonb)
    FROM (VALUES
      ('workspaces'::regclass), ('workspace_memberships'::regclass),
      ('products'::regclass), ('product_disciplines'::regclass),
      ('stage_definitions'::regclass), ('discipline_stages'::regclass),
      ('stage_activities'::regclass), ('business_targets'::regclass),
      ('import_batches'::regclass), ('import_source_rows'::regclass),
      ('initial_schedule_revisions'::regclass)
    ) AS imported_tables(relation_id)
    JOIN pg_class AS relation ON relation.oid = imported_tables.relation_id
  ),
  'stageActivityColumnPrivileges', (
    SELECT jsonb_object_agg(column_name, jsonb_build_object(
      'insert', has_column_privilege('jlproject_worker', 'public.stage_activities', column_name, 'INSERT'),
      'select', has_column_privilege('jlproject_worker', 'public.stage_activities', column_name, 'SELECT'),
      'update', has_column_privilege('jlproject_worker', 'public.stage_activities', column_name, 'UPDATE')))
    FROM unnest(ARRAY['workspace_id', 'product_id', 'discipline_id', 'stage_id', 'name',
      'activity_type', 'planned_start', 'planned_end', 'display_order', 'notes',
      'source_external_id', 'created_by', 'updated_by', 'planning_mode',
      'working_day_duration', 'planning_calendar_version', 'color_override']) AS column_name
  ),
  'importAndAuditFunctions', (
    SELECT jsonb_agg(jsonb_build_object('signature', procedure_row.oid::regprocedure::text,
      'owner', pg_get_userbyid(procedure_row.proowner),
      'securityDefiner', procedure_row.prosecdef,
      'workerExecute', has_function_privilege('jlproject_worker', procedure_row.oid, 'EXECUTE'),
      'configuration', procedure_row.proconfig)
      ORDER BY procedure_row.oid::regprocedure::text)
    FROM pg_proc AS procedure_row
    WHERE procedure_row.oid IN (
      'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)'::regprocedure,
      'public.capture_product_schedule_mutation()'::regprocedure,
      'public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)'::regprocedure,
      'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)'::regprocedure,
      'public.prevent_initial_revision_mutation()'::regprocedure
    )
  ),
  'relevantTriggers', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('table', relation.relname,
      'trigger', trigger_row.tgname, 'enabled', trigger_row.tgenabled,
      'function', trigger_row.tgfoid::regprocedure::text)
      ORDER BY relation.relname, trigger_row.tgname), '[]'::jsonb)
    FROM pg_trigger AS trigger_row
    JOIN pg_class AS relation ON relation.oid = trigger_row.tgrelid
    WHERE NOT trigger_row.tgisinternal AND (
      trigger_row.tgname IN ('products_schedule_audit', 'product_disciplines_schedule_audit',
        'discipline_stages_schedule_audit', 'stage_activities_schedule_audit',
        'business_targets_schedule_audit', 'initial_schedule_revisions_immutable') OR
      relation.oid = 'public.stage_activities'::regclass AND
        trigger_row.tgname = 'stage_activities_dates_immutable')
  ),
  'scheduleOperationGroupingConstraint', (
    SELECT jsonb_agg(pg_get_constraintdef(constraint_row.oid, true))
    FROM pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = 'public.product_schedule_operations'::regclass
      AND constraint_row.contype IN ('p', 'u')
  ),
  'r00Immutability', jsonb_build_object(
    'workerInsert', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'INSERT'),
    'workerUpdate', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE'),
    'workerDelete', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE'),
    'immutableTriggerEnabled', EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
        AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A'))
  ),
  'importSequences', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('sequence', sequence_row.oid::regclass::text,
      'usage', has_sequence_privilege('jlproject_worker', sequence_row.oid, 'USAGE'),
      'select', has_sequence_privilege('jlproject_worker', sequence_row.oid, 'SELECT'),
      'update', has_sequence_privilege('jlproject_worker', sequence_row.oid, 'UPDATE'))
      ORDER BY sequence_row.oid::regclass::text), '[]'::jsonb)
    FROM pg_class AS sequence_row
    JOIN pg_depend AS dependency ON dependency.classid = 'pg_class'::regclass
      AND dependency.objid = sequence_row.oid AND dependency.refclassid = 'pg_class'::regclass
    WHERE sequence_row.relkind = 'S' AND dependency.refobjid IN (
      'public.workspaces'::regclass, 'public.workspace_memberships'::regclass,
      'public.products'::regclass, 'public.product_disciplines'::regclass,
      'public.stage_definitions'::regclass, 'public.discipline_stages'::regclass,
      'public.stage_activities'::regclass, 'public.business_targets'::regclass,
      'public.import_batches'::regclass, 'public.import_source_rows'::regclass,
      'public.initial_schedule_revisions'::regclass)
  ),
  'migration0030Objects', jsonb_build_object(
    'stageEventIdPrimaryKey', EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.stage_date_changes'::regclass AND contype = 'p'
        AND pg_get_constraintdef(oid, true) = 'PRIMARY KEY (event_id)'),
    'exactSourceEventTable', to_regclass('public.product_schedule_operation_source_events') IS NOT NULL,
    'exactSourceEventLinkTrigger', EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.product_schedule_operation_events'::regclass
        AND tgname = 'product_schedule_operation_events_source_links'
        AND tgenabled IN ('O', 'A'))
  ),
  'r00Fingerprints', jsonb_build_object(
    'count', (SELECT count(*) FROM public.initial_schedule_revisions WHERE label = 'R00'),
    'wholeRowJson', (SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text,
      E'\n' ORDER BY revision.id), ''))
      FROM public.initial_schedule_revisions AS revision WHERE revision.label = 'R00'),
    'idAndSnapshot', (SELECT md5(COALESCE(string_agg(revision.id::text || '|' || revision.snapshot::text,
      E'\n' ORDER BY revision.id), ''))
      FROM public.initial_schedule_revisions AS revision WHERE revision.label = 'R00')
  )
) AS import_authorization_preflight;

ROLLBACK;
