-- Read-only status and aggregate baseline for JLProject Development.
-- Run with neondb_owner only after independently verifying the Neon project and branch.
SELECT jsonb_build_object(
  'database', current_database(),
  'migrationFunctionPresent', to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL,
  'executor', jsonb_build_object(
    'exists', EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor'),
    'noLogin', COALESCE((SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor'), false),
    'noInherit', COALESCE((SELECT NOT rolinherit FROM pg_roles WHERE rolname = 'jlproject_date_executor'), false),
    'publicCreate', has_schema_privilege('jlproject_date_executor', 'public', 'CREATE'),
    'readsMemberships', has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT'),
    'readsProducts', has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT'),
    'readsActivities', has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT'),
    'readsTargets', has_table_privilege('jlproject_date_executor', 'public.business_targets', 'SELECT'),
    'readsActivityDateAudit', has_table_privilege('jlproject_date_executor', 'public.activity_date_changes', 'SELECT'),
    'readsTargetDateAudit', has_table_privilege('jlproject_date_executor', 'public.business_target_date_changes', 'SELECT'),
    'readsRescheduleAudit', has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_changes', 'SELECT'),
    'readsReversalAudit', has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_reversals', 'SELECT'),
    'readsDeletionAudit', has_table_privilege('jlproject_date_executor', 'public.schedule_deletion_events', 'SELECT'),
    'readsDisciplineScope', has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'id', 'SELECT') AND
      has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'workspace_id', 'SELECT') AND
      has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'product_id', 'SELECT'),
    'readsStageScope', has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'id', 'SELECT') AND
      has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'workspace_id', 'SELECT') AND
      has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'product_id', 'SELECT') AND
      has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'discipline_id', 'SELECT'),
    'ownerCanUseExecutor', pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage'),
    'ownerCanSetExecutor', pg_has_role('neondb_owner', 'jlproject_date_executor', 'set'),
    'readsImportBatchScope', has_column_privilege('jlproject_date_executor', 'public.import_batches', 'product_id', 'SELECT'),
    'readsImportReference', has_column_privilege('jlproject_date_executor', 'public.import_source_rows', 'import_batch_id', 'SELECT'),
    'readsDisciplineName', has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'name', 'SELECT'),
    'readsStageName', has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'display_name', 'SELECT')
  ),
  'historyFunction', CASE WHEN to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL THEN NULL
    ELSE jsonb_build_object(
      'securityDefiner', (SELECT prosecdef FROM pg_proc WHERE oid =
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure),
      'stable', (SELECT provolatile = 's' FROM pg_proc WHERE oid =
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure),
      'owner', (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure),
      'searchPath', (SELECT proconfig FROM pg_proc WHERE oid =
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure),
      'executeGrantees', (SELECT jsonb_agg(COALESCE(grantee.rolname, 'PUBLIC') ORDER BY
          COALESCE(grantee.rolname, 'PUBLIC'))
        FROM pg_proc AS function
        CROSS JOIN LATERAL aclexplode(COALESCE(function.proacl,
          acldefault('f', function.proowner))) AS privilege
        LEFT JOIN pg_roles AS grantee ON grantee.oid = privilege.grantee
        WHERE function.oid =
          'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure
          AND privilege.privilege_type = 'EXECUTE'),
      'workerExecute', has_function_privilege('jlproject_worker',
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE'),
      'publicExecute', has_function_privilege('public',
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE')
  ) END,
  'worker', jsonb_build_object(
    'executorMembership', pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member'),
    'loggedInWorker', COALESCE((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_worker'), false),
    'directRescheduleRead', has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT'),
    'directReversalRead', has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT'),
    'directDeletionAuditRead', has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'SELECT'),
    'r00Update', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE'),
    'r00Delete', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE'),
    'historyExecute', CASE WHEN to_regprocedure(
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL THEN false
      ELSE has_function_privilege('jlproject_worker',
        'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') END
  ),
  'baseline', jsonb_build_object(
    'products', (SELECT count(*) FROM public.products),
    'disciplines', (SELECT count(*) FROM public.product_disciplines),
    'stages', (SELECT count(*) FROM public.discipline_stages),
    'activities', (SELECT count(*) FROM public.stage_activities),
    'targets', (SELECT count(*) FROM public.business_targets),
    'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
    'activityDateEvents', (SELECT count(*) FROM public.activity_date_changes),
    'targetDateEvents', (SELECT count(*) FROM public.business_target_date_changes),
    'rescheduleEvents', (SELECT count(*) FROM public.calendar_reschedule_changes),
    'reversalEvents', (SELECT count(*) FROM public.calendar_reschedule_reversals),
    'deletionEvents', (SELECT count(*) FROM public.schedule_deletion_events)
  )
) AS status;
