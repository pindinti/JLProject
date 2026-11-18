\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $postflight$
DECLARE
  v_history oid := to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)');
  v_provenance oid := to_regprocedure('public.link_product_schedule_history_provenance()');
  v_definition text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_history IS NULL OR v_provenance IS NULL OR
     pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_history)) <> 'jlproject_date_executor' OR
     (SELECT pg_get_function_result(v_history)) <> 'jsonb' OR
     NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
       FROM pg_proc WHERE oid = v_history) OR
     NOT has_function_privilege('jlproject_worker', v_history, 'EXECUTE') OR
     EXISTS (SELECT 1 FROM pg_proc AS proc
       CROSS JOIN LATERAL aclexplode(COALESCE(proc.proacl, acldefault('f', proc.proowner))) AS privilege
       WHERE proc.oid = v_history AND privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE') OR
     pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_provenance)) <> 'jlproject_date_executor' OR
     NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
       FROM pg_proc WHERE oid = v_provenance) OR
     has_function_privilege('jlproject_worker', v_provenance, 'EXECUTE') OR
     NOT has_function_privilege('neondb_owner', v_provenance, 'EXECUTE') OR
     EXISTS (SELECT 1 FROM pg_proc AS proc
       CROSS JOIN LATERAL aclexplode(COALESCE(proc.proacl, acldefault('f', proc.proowner))) AS privilege
       WHERE proc.oid = v_provenance AND privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.products'::regclass) <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.import_batches'::regclass) <> 'neondb_owner' OR
     to_regclass('public.product_schedule_operations_history_time_idx') IS NULL OR
     (SELECT count(*) FROM pg_trigger WHERE tgname IN
       ('products_z_history_source_link', 'import_batches_z_history_source_link')
       AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred) <> 2 THEN
    RAISE EXCEPTION 'Migration 0032 ownership, privilege, index, or trigger postconditions failed.';
  END IF;

  v_definition := pg_get_functiondef(v_history);
  IF position('candidate_operations AS MATERIALIZED' IN v_definition) = 0 OR
     position('source_event_entities AS' IN v_definition) = 0 OR
     position('logical_feed AS' IN v_definition) = 0 OR
     position('SELECT event.* FROM logical_feed AS event' IN v_definition) = 0 OR
     position('''operationId'', event.operation_id::text' IN v_definition) = 0 OR
     position('''details'', event.details' IN v_definition) = 0 OR
     position('workspace_memberships' IN v_definition) = 0 OR
     position('membership.active = true' IN v_definition) = 0 OR
     position('product.workspace_id = p_workspace_id AND product.id = p_product_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'The installed unified history definition is missing a reviewed feed or authorization contract.';
  END IF;
END;
$postflight$;

SELECT jsonb_pretty(jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
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
  'provenanceFunction', (SELECT jsonb_build_object(
      'owner', pg_get_userbyid(proc.proowner),
      'securityDefiner', proc.prosecdef,
      'configuration', proc.proconfig,
      'workerExecute', has_function_privilege('jlproject_worker', proc.oid, 'EXECUTE'),
      'ownerExecute', has_function_privilege('neondb_owner', proc.oid, 'EXECUTE'),
      'publicExecute', EXISTS (SELECT 1 FROM aclexplode(COALESCE(proc.proacl,
        acldefault('f', proc.proowner))) AS privilege
        WHERE privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'))
    FROM pg_proc AS proc WHERE proc.oid =
      'public.link_product_schedule_history_provenance()'::regprocedure),
  'postconditions', jsonb_build_object(
    'historyIndexPresent', to_regclass('public.product_schedule_operations_history_time_idx') IS NOT NULL,
    'productsTriggerReady', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'products_z_history_source_link'
      AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred),
    'importsTriggerReady', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'import_batches_z_history_source_link'
      AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred),
    'executorCreateRevoked', NOT has_schema_privilege('jlproject_date_executor', 'public', 'CREATE'),
    'ownerExecutorMembershipRevoked', NOT pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage')
      AND NOT pg_has_role('neondb_owner', 'jlproject_date_executor', 'set'),
    'workerNoDirectGenericReads', NOT has_table_privilege('jlproject_worker',
      'public.product_schedule_operations', 'SELECT') AND
      NOT has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') AND
      NOT has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT'))
)) AS phase1_1_migration_0032_postflight;

ROLLBACK;
