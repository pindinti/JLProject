\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $preflight$
DECLARE
  v_history oid := to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)');
  v_definition text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_history IS NULL OR
     pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_history)) <> 'jlproject_date_executor' OR
     (SELECT pg_get_function_result(v_history)) <> 'jsonb' OR
     NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
       FROM pg_proc WHERE oid = v_history) OR
     NOT has_function_privilege('jlproject_worker', v_history, 'EXECUTE') OR
     EXISTS (SELECT 1 FROM pg_proc AS proc
       CROSS JOIN LATERAL aclexplode(COALESCE(proc.proacl, acldefault('f', proc.proowner))) AS privilege
       WHERE proc.oid = v_history AND privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.products'::regclass) <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.import_batches'::regclass) <> 'neondb_owner' OR
     to_regclass('public.product_schedule_state') IS NULL OR
     to_regclass('public.product_schedule_operations') IS NULL OR
     to_regclass('public.product_schedule_operation_events') IS NULL OR
     to_regclass('public.product_schedule_operation_links') IS NULL OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     to_regclass('public.stage_date_changes') IS NULL OR
     to_regclass('public.activity_date_changes') IS NULL OR
     to_regclass('public.business_target_date_changes') IS NULL OR
     to_regclass('public.hierarchy_movement_events') IS NULL OR
     to_regclass('public.schedule_deletion_events') IS NULL OR
     to_regclass('public.calendar_reschedule_changes') IS NULL OR
     to_regclass('public.calendar_reschedule_reversals') IS NULL OR
     to_regprocedure('public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)') IS NULL OR
     to_regprocedure('public.link_product_schedule_operation_source_events()') IS NULL OR
     to_regprocedure('public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)') IS NULL OR
     to_regprocedure('public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)') IS NULL OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'UPDATE') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.product_schedule_operations'::regclass
       AND contype = 'u' AND pg_get_constraintdef(oid, true) =
         'UNIQUE (workspace_id, product_id, transaction_id)') OR
     to_regclass('public.product_schedule_operations_history_time_idx') IS NOT NULL OR
     to_regprocedure('public.link_product_schedule_history_provenance()') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN
       ('products_z_history_source_link', 'import_batches_z_history_source_link') AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Development catalog, migration 0028–0031 contracts, or privilege assumptions differ from migration 0032 preconditions.';
  END IF;

  v_definition := pg_get_functiondef(v_history);
  IF position('public.product_schedule_operation_source_events' IN v_definition) > 0 OR
     position('public.hierarchy_movement_events' IN v_definition) = 0 OR
     position('change.event_id::text' IN v_definition) = 0 OR
     position('ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC' IN v_definition) = 0 OR
     position('LIMIT p_limit + 1' IN v_definition) = 0 OR
     position('  ), eligible AS MATERIALIZED (' IN v_definition) = 0 OR
     position('SELECT event.* FROM event_feed AS event' IN v_definition) = 0 OR
     position('''eventType'', event.event_type, ''item'', event.item,' IN v_definition) = 0 OR
     position('logical_feed AS event' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'The complete current history function is not the reviewed pre-0032 definition.';
  END IF;
END;
$preflight$;

SELECT jsonb_pretty(jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
  'migration0032', jsonb_build_object(
    'historyIndexAbsent', to_regclass('public.product_schedule_operations_history_time_idx') IS NULL,
    'provenanceFunctionAbsent', to_regprocedure('public.link_product_schedule_history_provenance()') IS NULL,
    'provenanceTriggersAbsent', NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN
      ('products_z_history_source_link', 'import_batches_z_history_source_link') AND NOT tgisinternal)),
  'historyFunction', (SELECT jsonb_build_object(
      'signature', proc.oid::regprocedure::text,
      'returnType', pg_get_function_result(proc.oid),
      'owner', pg_get_userbyid(proc.proowner),
      'securityDefiner', proc.prosecdef,
      'configuration', proc.proconfig,
      'workerExecute', has_function_privilege('jlproject_worker', proc.oid, 'EXECUTE'),
      'publicExecute', EXISTS (SELECT 1 FROM aclexplode(COALESCE(proc.proacl,
        acldefault('f', proc.proowner))) AS privilege
        WHERE privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'),
      'definitionMd5', md5(pg_get_functiondef(proc.oid)))
    FROM pg_proc AS proc WHERE proc.oid =
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure),
  'appliedContracts', jsonb_build_object(
    'phase1OperationTables', to_regclass('public.product_schedule_state') IS NOT NULL AND
      to_regclass('public.product_schedule_operations') IS NOT NULL AND
      to_regclass('public.product_schedule_operation_events') IS NOT NULL AND
      to_regclass('public.product_schedule_operation_source_events') IS NOT NULL,
    'phase1ImportColumnGrant', has_column_privilege('jlproject_worker',
      'public.stage_activities', 'source_external_id', 'INSERT'),
    'phase1ImportHasNoTableInsert', NOT has_table_privilege('jlproject_worker',
      'public.stage_activities', 'INSERT'),
    'transactionOperationUnique', EXISTS (SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.product_schedule_operations'::regclass AND contype = 'u'
        AND pg_get_constraintdef(oid, true) = 'UNIQUE (workspace_id, product_id, transaction_id)')),
  'workerDirectGenericAuditReads', jsonb_build_object(
    'operations', has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT'),
    'details', has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT'),
    'sourceLinks', has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT'))
)) AS phase1_1_migration_0032_preflight;

ROLLBACK;
