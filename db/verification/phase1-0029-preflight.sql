\set ON_ERROR_STOP on

-- Read-only Development preflight for migration 0029. This file performs no writes.
WITH required_tables(table_name) AS (
  VALUES ('products'), ('product_disciplines'), ('discipline_stages'), ('stage_activities'),
    ('business_targets'), ('stage_definitions'), ('workspace_memberships'),
    ('stage_date_changes'), ('activity_date_changes'), ('business_target_date_changes'),
    ('hierarchy_movement_events'), ('schedule_deletion_events'),
    ('calendar_reschedule_changes'), ('calendar_reschedule_reversals'),
    ('initial_schedule_revisions')
), required_columns(table_name, column_name) AS (
  VALUES
    ('products', 'id'), ('products', 'workspace_id'), ('products', 'created_by'),
    ('products', 'updated_by'), ('products', 'active'),
    ('product_disciplines', 'id'), ('product_disciplines', 'workspace_id'),
    ('product_disciplines', 'product_id'), ('product_disciplines', 'display_order'),
    ('discipline_stages', 'id'), ('discipline_stages', 'workspace_id'),
    ('discipline_stages', 'product_id'), ('discipline_stages', 'discipline_id'),
    ('discipline_stages', 'planned_start'), ('discipline_stages', 'planned_end'),
    ('discipline_stages', 'display_order'), ('discipline_stages', 'deleted_at'),
    ('stage_activities', 'id'), ('stage_activities', 'workspace_id'),
    ('stage_activities', 'product_id'), ('stage_activities', 'discipline_id'),
    ('stage_activities', 'stage_id'), ('stage_activities', 'planned_start'),
    ('stage_activities', 'planned_end'), ('stage_activities', 'display_order'),
    ('stage_activities', 'deleted_at'), ('business_targets', 'id'),
    ('business_targets', 'workspace_id'), ('business_targets', 'product_id'),
    ('business_targets', 'target_date'), ('business_targets', 'deleted_at'),
    ('stage_definitions', 'id'), ('stage_definitions', 'workspace_id'),
    ('stage_definitions', 'code'), ('stage_definitions', 'color'),
    ('workspace_memberships', 'workspace_id'), ('workspace_memberships', 'auth_user_id'),
    ('workspace_memberships', 'active'), ('workspace_memberships', 'role'),
    ('stage_date_changes', 'operation_id'), ('stage_date_changes', 'workspace_id'),
    ('stage_date_changes', 'product_id'), ('activity_date_changes', 'operation_id'),
    ('activity_date_changes', 'workspace_id'), ('activity_date_changes', 'product_id'),
    ('business_target_date_changes', 'operation_id'),
    ('business_target_date_changes', 'workspace_id'), ('business_target_date_changes', 'product_id'),
    ('hierarchy_movement_events', 'operation_id'), ('hierarchy_movement_events', 'workspace_id'),
    ('hierarchy_movement_events', 'product_id'), ('schedule_deletion_events', 'operation_id'),
    ('schedule_deletion_events', 'workspace_id'), ('schedule_deletion_events', 'product_id'),
    ('calendar_reschedule_changes', 'batch_operation_id'),
    ('calendar_reschedule_changes', 'date_operation_id'),
    ('calendar_reschedule_changes', 'workspace_id'), ('calendar_reschedule_changes', 'product_id'),
    ('calendar_reschedule_reversals', 'reversal_batch_operation_id'),
    ('calendar_reschedule_reversals', 'original_batch_operation_id'),
    ('calendar_reschedule_reversals', 'workspace_id'),
    ('calendar_reschedule_reversals', 'product_id')
), migration_0029_tables(table_name) AS (
  VALUES ('product_schedule_state'), ('product_schedule_operations'),
    ('product_schedule_operation_events'), ('product_schedule_operation_links')
), migration_0029_triggers(trigger_name) AS (
  VALUES ('products_schedule_audit'), ('product_disciplines_schedule_audit'),
    ('discipline_stages_schedule_audit'), ('stage_activities_schedule_audit'),
    ('business_targets_schedule_audit'), ('stage_definitions_schedule_audit'),
    ('product_schedule_operations_append_only'), ('product_schedule_operations_no_truncate'),
    ('product_schedule_operation_events_append_only'), ('product_schedule_operation_events_no_truncate'),
    ('product_schedule_operation_links_append_only'), ('product_schedule_operation_links_no_truncate'),
    ('activity_date_changes_schedule_link'), ('stage_date_changes_schedule_link'),
    ('business_target_date_changes_schedule_link'), ('calendar_reschedule_changes_schedule_link'),
    ('calendar_reschedule_reversals_schedule_link'), ('hierarchy_movement_events_schedule_link'),
    ('schedule_deletion_events_schedule_link')
), migration_0029_functions(signature) AS (
  VALUES ('public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)'),
    ('public.capture_product_schedule_mutation()'), ('public.link_product_schedule_audit_source()'),
    ('public.read_product_schedule_cursor(uuid,uuid,uuid)'),
    ('public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)'),
    ('public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)')
), current_schedule_tables(table_name) AS (
  VALUES ('products'), ('product_disciplines'), ('discipline_stages'),
    ('stage_activities'), ('business_targets'), ('stage_definitions'),
    ('activity_date_changes'), ('stage_date_changes'), ('business_target_date_changes'),
    ('hierarchy_movement_events'), ('schedule_deletion_events'),
    ('calendar_reschedule_changes'), ('calendar_reschedule_reversals')
)
SELECT jsonb_pretty(jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
  'migration_0028_contract', jsonb_build_object(
    'planned_stage_start', EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'discipline_stages' AND column_name = 'planned_start'),
    'planned_stage_end', EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'discipline_stages' AND column_name = 'planned_end'),
    'stage_date_ledger', to_regclass('public.stage_date_changes') IS NOT NULL,
    'stage_date_operation', to_regprocedure(
      'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)') IS NOT NULL,
    'product_history_function', to_regprocedure(
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL
  ),
  'prerequisites', jsonb_build_object(
    'tables_present', (SELECT bool_and(to_regclass('public.' || table_name) IS NOT NULL)
      FROM required_tables),
    'required_columns_present', NOT EXISTS (
      SELECT 1 FROM required_columns AS required
      WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns AS actual
        WHERE actual.table_schema = 'public' AND actual.table_name = required.table_name
          AND actual.column_name = required.column_name)),
    'expected_executor', EXISTS (SELECT 1 FROM pg_roles
      WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin),
    'expected_worker', EXISTS (SELECT 1 FROM pg_roles
      WHERE rolname = 'jlproject_worker' AND rolcanlogin
        AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb),
    'worker_not_executor_member', NOT pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member'),
    'executor_has_no_public_create', NOT has_schema_privilege('jlproject_date_executor', 'public', 'CREATE'),
    'migration_role_has_no_executor_membership',
      NOT pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage')
      AND NOT pg_has_role('neondb_owner', 'jlproject_date_executor', 'set')
  ),
  'migration_0029_partial_objects', jsonb_build_object(
    'tables_absent', NOT EXISTS (SELECT 1 FROM migration_0029_tables AS expected
      WHERE to_regclass('public.' || expected.table_name) IS NOT NULL),
    'functions_absent', NOT EXISTS (SELECT 1 FROM migration_0029_functions AS expected
      WHERE to_regprocedure(expected.signature) IS NOT NULL),
    'triggers_absent', NOT EXISTS (SELECT 1 FROM pg_trigger AS trigger
      JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
      JOIN pg_namespace AS schema ON schema.oid = relation.relnamespace
      JOIN migration_0029_triggers AS expected ON expected.trigger_name = trigger.tgname
      WHERE NOT trigger.tgisinternal AND schema.nspname = 'public'),
    'unexpected_schedule_state_trigger', NOT EXISTS (SELECT 1 FROM pg_trigger AS trigger
      JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
      JOIN pg_namespace AS schema ON schema.oid = relation.relnamespace
      WHERE NOT trigger.tgisinternal AND schema.nspname = 'public'
        AND relation.relname = 'product_schedule_state')
  ),
  'existing_trigger_inventory', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', relation.relname, 'trigger', trigger.tgname,
      'enabled', trigger.tgenabled, 'definition', pg_get_triggerdef(trigger.oid, true),
      'function', proc.proname, 'functionOwner', pg_get_userbyid(proc.proowner),
      'securityDefiner', proc.prosecdef, 'functionConfig', proc.proconfig
    ) ORDER BY relation.relname, trigger.tgname), '[]'::jsonb)
    FROM pg_trigger AS trigger
    JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
    JOIN pg_namespace AS schema ON schema.oid = relation.relnamespace
    JOIN pg_proc AS proc ON proc.oid = trigger.tgfoid
    JOIN current_schedule_tables AS expected ON expected.table_name = relation.relname
    WHERE NOT trigger.tgisinternal AND schema.nspname = 'public'),
  'existing_controlled_function_security', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'function', proc.proname,
      'arguments', pg_get_function_identity_arguments(proc.oid),
      'owner', pg_get_userbyid(proc.proowner), 'securityDefiner', proc.prosecdef,
      'functionConfig', proc.proconfig
    ) ORDER BY proc.proname, proc.oid), '[]'::jsonb)
    FROM pg_proc AS proc
    JOIN pg_namespace AS schema ON schema.oid = proc.pronamespace
    WHERE schema.nspname = 'public' AND proc.proname IN (
      'clone_product', 'import_initial_schedule', 'create_discipline_stage_with_dates',
      'change_discipline_stage_dates', 'move_schedule_item', 'delete_schedule_subtree',
      'change_activity_dates', 'change_activity_planning', 'update_business_target',
      'delete_business_target', 'apply_calendar_reschedule', 'reverse_calendar_reschedule')),
  'data_fingerprints', jsonb_build_object(
    'product_count', (SELECT count(*) FROM public.products),
    'stage_count', (SELECT count(*) FROM public.discipline_stages),
    'activity_count', (SELECT count(*) FROM public.stage_activities),
    'r00_count', (SELECT count(*) FROM public.initial_schedule_revisions
      WHERE label = 'R00'),
    'r00_fingerprint', (SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n'
      ORDER BY revision.id), '')) FROM public.initial_schedule_revisions AS revision
      WHERE revision.label = 'R00')
  )
));
