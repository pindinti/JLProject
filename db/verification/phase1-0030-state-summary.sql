-- Read-only Development state summary for before/after migration 0030 comparisons.
\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $target$
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Expected neondb as neondb_owner; found % as %.', current_database(), current_user;
  END IF;
END;
$target$;

SELECT jsonb_build_object(
  'target', jsonb_build_object('database', current_database(), 'role', current_user),
  'migrationRole', (
    SELECT jsonb_build_object('superuser', role_row.rolsuper, 'createRole', role_row.rolcreaterole,
      'canGrantExecutorMembership', role_row.rolsuper OR role_row.rolcreaterole OR EXISTS (
        SELECT 1 FROM pg_auth_members AS membership
        JOIN pg_roles AS granted ON granted.oid = membership.roleid
        JOIN pg_roles AS member ON member.oid = membership.member
        WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = role_row.rolname
          AND membership.admin_option))
    FROM pg_roles AS role_row WHERE role_row.rolname = current_user
  ),
  'migrationState', jsonb_build_object(
    'post0029ObjectsPresent', to_regclass('public.product_schedule_state') IS NOT NULL AND
      to_regclass('public.product_schedule_operations') IS NOT NULL AND
      to_regclass('public.product_schedule_operation_events') IS NOT NULL AND
      to_regclass('public.product_schedule_operation_links') IS NOT NULL AND
      to_regclass('public.stage_date_changes') IS NOT NULL AND
      to_regprocedure('public.link_product_schedule_audit_source()') IS NOT NULL AND
      to_regprocedure('public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)') IS NOT NULL,
    'stageDateOwner', (SELECT pg_get_userbyid(relowner) FROM pg_class
      WHERE oid = 'public.stage_date_changes'::regclass),
    'stageDatePrimaryKey', (SELECT pg_get_constraintdef(oid, true) FROM pg_constraint
      WHERE conrelid = 'public.stage_date_changes'::regclass AND contype = 'p'),
    'stageEventIdDefinition', (SELECT jsonb_build_object(
      'type', format_type(attribute.atttypid, attribute.atttypmod),
      'notNull', attribute.attnotnull,
      'default', pg_get_expr(default_value.adbin, default_value.adrelid))
      FROM pg_attribute AS attribute
      LEFT JOIN pg_attrdef AS default_value ON default_value.adrelid = attribute.attrelid
        AND default_value.adnum = attribute.attnum
      WHERE attribute.attrelid = 'public.stage_date_changes'::regclass
        AND attribute.attname = 'event_id' AND NOT attribute.attisdropped),
    'stageDateUniqueConstraints', (SELECT COALESCE(jsonb_agg(pg_get_constraintdef(oid, true)
      ORDER BY conname), '[]'::jsonb) FROM pg_constraint
      WHERE conrelid = 'public.stage_date_changes'::regclass AND contype = 'u'),
    'stageEventIndexes', (SELECT COALESCE(jsonb_agg(indexname ORDER BY indexname), '[]'::jsonb)
      FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'stage_date_changes'),
    'foreignKeysToStageLedger', (SELECT count(*) FROM pg_constraint
      WHERE contype = 'f' AND confrelid = 'public.stage_date_changes'::regclass),
    'stageDateEventIdPresent', EXISTS (SELECT 1 FROM pg_attribute
      WHERE attrelid = 'public.stage_date_changes'::regclass
        AND attname = 'event_id' AND NOT attisdropped),
    'sourceEventsTablePresent', to_regclass('public.product_schedule_operation_source_events') IS NOT NULL,
    'sourceEventsOwner', (SELECT pg_get_userbyid(relowner) FROM pg_class
      WHERE oid = to_regclass('public.product_schedule_operation_source_events')),
    'sourceEventsPrimaryKey', (SELECT pg_get_constraintdef(oid, true) FROM pg_constraint
      WHERE conrelid = to_regclass('public.product_schedule_operation_source_events') AND contype = 'p'),
    'sourceEventsAppendOnlyTriggers', (SELECT COALESCE(jsonb_agg(tgname ORDER BY tgname), '[]'::jsonb)
      FROM pg_trigger WHERE tgrelid = to_regclass('public.product_schedule_operation_source_events')
        AND NOT tgisinternal AND tgenabled IN ('O', 'A')),
    'sourceLinkTriggerPresent', EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.product_schedule_operation_events'::regclass
        AND tgname = 'product_schedule_operation_events_source_links' AND NOT tgisinternal),
    'stageAppendOnlyEnabled', EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.stage_date_changes'::regclass
        AND tgname = 'stage_date_changes_append_only' AND tgenabled IN ('O', 'A')),
    'ownerSchemaCreate', has_schema_privilege('neondb_owner', 'public', 'CREATE'),
    'executorSchemaCreate', has_schema_privilege('jlproject_date_executor', 'public', 'CREATE'),
    'ownerCanSetExecutor', pg_has_role('neondb_owner', 'jlproject_date_executor', 'set'),
    'workerIsExecutorMember', pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member')
  ),
  'workerDirectPrivileges', (
    SELECT jsonb_object_agg(relation.relname, jsonb_build_object(
      'select', has_table_privilege('jlproject_worker', relation.oid, 'SELECT'),
      'insert', has_table_privilege('jlproject_worker', relation.oid, 'INSERT'),
      'update', has_table_privilege('jlproject_worker', relation.oid, 'UPDATE'),
      'delete', has_table_privilege('jlproject_worker', relation.oid, 'DELETE'),
      'truncate', has_table_privilege('jlproject_worker', relation.oid, 'TRUNCATE')
    ) ORDER BY relation.relname)
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public' AND relation.relname IN (
      'stage_date_changes', 'product_schedule_state', 'product_schedule_operations',
      'product_schedule_operation_events', 'product_schedule_operation_links',
      'product_schedule_operation_source_events', 'activity_date_changes',
      'business_target_date_changes', 'calendar_reschedule_changes',
      'calendar_reschedule_reversals', 'hierarchy_movement_events', 'schedule_deletion_events'
    )
  ),
  'workerFunctionPrivileges', jsonb_build_object(
    'listProductScheduleOperations', has_function_privilege('jlproject_worker',
      'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE'),
    'listProductChangeHistory', has_function_privilege('jlproject_worker',
      'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE'),
    'changeStageDates', has_function_privilege('jlproject_worker',
      'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE'),
    'changeActivityDates', has_function_privilege('jlproject_worker',
      'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE'),
    'linkAuditSource', has_function_privilege('jlproject_worker',
      'public.link_product_schedule_audit_source()', 'EXECUTE'),
    'linkExactSourceEvents', CASE
      WHEN to_regprocedure('public.link_product_schedule_operation_source_events()') IS NULL THEN false
      ELSE has_function_privilege('jlproject_worker',
        'public.link_product_schedule_operation_source_events()', 'EXECUTE') END,
    'writeGenericEvent', has_function_privilege('jlproject_worker',
      'public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)', 'EXECUTE')
  ),
  'securityDefinerFunctions', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'signature', proc.oid::regprocedure::text,
      'owner', pg_get_userbyid(proc.proowner),
      'securityDefiner', proc.prosecdef,
      'configuration', proc.proconfig
    ) ORDER BY proc.proname, proc.oid), '[]'::jsonb)
    FROM pg_proc AS proc
    JOIN pg_namespace AS namespace ON namespace.oid = proc.pronamespace
    WHERE namespace.nspname = 'public' AND proc.proname IN (
      'link_product_schedule_audit_source', 'link_product_schedule_operation_source_events',
      'list_product_schedule_operations', 'list_product_change_history',
      'write_product_schedule_operation_event'
    )
  ),
  'counts', jsonb_build_object(
    'products', (SELECT count(*) FROM public.products),
    'disciplines', (SELECT count(*) FROM public.product_disciplines),
    'stages', (SELECT count(*) FROM public.discipline_stages),
    'activities', (SELECT count(*) FROM public.stage_activities),
    'targets', (SELECT count(*) FROM public.business_targets),
    'stageDateEvents', (SELECT count(*) FROM public.stage_date_changes),
    'activityDateEvents', (SELECT count(*) FROM public.activity_date_changes),
    'targetDateEvents', (SELECT count(*) FROM public.business_target_date_changes),
    'calendarReschedules', (SELECT count(*) FROM public.calendar_reschedule_changes),
    'calendarReversals', (SELECT count(*) FROM public.calendar_reschedule_reversals),
    'hierarchyMoves', (SELECT count(*) FROM public.hierarchy_movement_events),
    'deletionEvents', (SELECT count(*) FROM public.schedule_deletion_events),
    'scheduleCursors', (SELECT count(*) FROM public.product_schedule_state),
    'operationHeaders', (SELECT count(*) FROM public.product_schedule_operations),
    'operationDetails', (SELECT count(*) FROM public.product_schedule_operation_events),
    'legacyOperationLinks', (SELECT count(*) FROM public.product_schedule_operation_links),
    'exactSourceEventLinks', (SELECT count(*) FROM public.product_schedule_operation_source_events),
    'r00Snapshots', (SELECT count(*) FROM public.initial_schedule_revisions WHERE label = 'R00'),
    'unresolvedStageGroupLinks', (SELECT count(*) FROM public.product_schedule_operation_links AS link
      WHERE link.source_ledger = 'stage_date_changes'
        AND NOT EXISTS (SELECT 1 FROM public.stage_date_changes AS audit
          WHERE audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
            AND audit.operation_id = link.source_operation_id)),
    'ambiguousStageOperationIds', (SELECT count(*) FROM (
      SELECT operation_id FROM public.stage_date_changes GROUP BY operation_id HAVING count(*) > 1
    ) AS duplicate_groups)
  ),
  'fingerprints', jsonb_build_object(
    'products', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text, E'\n' ORDER BY record.id), ''))
      FROM public.products AS record),
    'disciplines', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text, E'\n' ORDER BY record.id), ''))
      FROM public.product_disciplines AS record),
    'stages', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text, E'\n' ORDER BY record.id), ''))
      FROM public.discipline_stages AS record),
    'activities', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text, E'\n' ORDER BY record.id), ''))
      FROM public.stage_activities AS record),
    'targets', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text, E'\n' ORDER BY record.id), ''))
      FROM public.business_targets AS record),
    'stageDatePayloads', (SELECT md5(COALESCE(string_agg((to_jsonb(record) - 'event_id')::text,
      E'\n' ORDER BY record.operation_id), '')) FROM public.stage_date_changes AS record),
    'activityDateEvents', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.operation_id), '')) FROM public.activity_date_changes AS record),
    'targetDateEvents', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.operation_id), '')) FROM public.business_target_date_changes AS record),
    'calendarReschedules', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.date_operation_id), '')) FROM public.calendar_reschedule_changes AS record),
    'calendarReversals', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.reversal_date_operation_id), ''))
      FROM public.calendar_reschedule_reversals AS record),
    'hierarchyMoves', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.operation_id), '')) FROM public.hierarchy_movement_events AS record),
    'deletionEvents', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.operation_id), '')) FROM public.schedule_deletion_events AS record),
    'scheduleCursors', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.product_id), '')) FROM public.product_schedule_state AS record),
    'operationHeaders', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.product_id, record.schedule_version), ''))
      FROM public.product_schedule_operations AS record),
    'operationDetails', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.event_id), '')) FROM public.product_schedule_operation_events AS record),
    'legacyOperationLinks', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.product_id, record.schedule_version, record.source_ledger,
        record.source_operation_id), '')) FROM public.product_schedule_operation_links AS record),
    'exactSourceEventLinks', (SELECT md5(COALESCE(string_agg(to_jsonb(record)::text,
      E'\n' ORDER BY record.product_id, record.schedule_version, record.source_ledger,
        record.link_kind, record.source_event_id), ''))
      FROM public.product_schedule_operation_source_events AS record),
    'r00Snapshots', (SELECT md5(COALESCE(string_agg(record.id::text || '|' || record.snapshot::text,
      E'\n' ORDER BY record.id), ''))
      FROM public.initial_schedule_revisions AS record WHERE record.label = 'R00')
  )
) AS development_state_summary;

ROLLBACK;
