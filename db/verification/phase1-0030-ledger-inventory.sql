-- Read-only Development inventory for the Phase 1 multi-entity audit correction.
\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $target$
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Expected neondb as neondb_owner; found % as %.', current_database(), current_user;
  END IF;
  IF to_regclass('public.product_schedule_state') IS NULL OR
     to_regclass('public.product_schedule_operations') IS NULL OR
     to_regclass('public.product_schedule_operation_events') IS NULL OR
     to_regclass('public.product_schedule_operation_links') IS NULL OR
     to_regclass('public.stage_date_changes') IS NULL OR
     to_regprocedure('public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)') IS NULL OR
     to_regprocedure('public.link_product_schedule_audit_source()') IS NULL THEN
    RAISE EXCEPTION 'Expected 0029 and the specialized audit ledgers are not present.';
  END IF;
END;
$target$;

DO $pre_0030_state$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute
      WHERE attrelid = 'public.stage_date_changes'::regclass
        AND attname = 'event_id' AND NOT attisdropped) OR
     to_regclass('public.product_schedule_operation_source_events') IS NOT NULL OR
     to_regclass('public.stage_date_changes_event_id_uidx') IS NOT NULL OR
     to_regclass('public.stage_date_changes_operation_group_idx') IS NOT NULL OR
     to_regclass('public.stage_date_changes_event_history_idx') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.product_schedule_operation_events'::regclass
         AND tgname = 'product_schedule_operation_events_source_links' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Migration 0030 appears partially applied; stop before execution.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_pkey' AND contype = 'p'
         AND pg_get_constraintdef(oid, true) = 'PRIMARY KEY (operation_id)') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_stage_version_unique' AND contype = 'u') OR
     EXISTS (SELECT 1 FROM pg_constraint
       WHERE contype = 'f' AND confrelid = 'public.stage_date_changes'::regclass) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_date_changes'::regclass
         AND tgname = 'stage_date_changes_append_only' AND tgenabled IN ('O', 'A')) THEN
    RAISE EXCEPTION 'The stage-date audit prerequisites differ from the reviewed post-0029 schema.';
  END IF;
  IF has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Unexpected temporary executor privileges are present before migration 0030.';
  END IF;
END;
$pre_0030_state$;

SELECT jsonb_pretty(jsonb_build_object(
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
  'executorMemberships', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'member', member.rolname, 'adminOption', membership.admin_option,
      'inheritOption', membership.inherit_option, 'setOption', membership.set_option
    ) ORDER BY member.rolname), '[]'::jsonb)
    FROM pg_auth_members AS membership
    JOIN pg_roles AS granted ON granted.oid = membership.roleid
    JOIN pg_roles AS member ON member.oid = membership.member
    WHERE granted.rolname = 'jlproject_date_executor'
  ),
  'schemaPrivileges', jsonb_build_object(
    'ownerCreate', has_schema_privilege('neondb_owner', 'public', 'CREATE'),
    'executorCreate', has_schema_privilege('jlproject_date_executor', 'public', 'CREATE')
  ),
  'ledgers', (
    SELECT jsonb_agg(jsonb_build_object(
      'table', relation.relname,
      'owner', pg_get_userbyid(relation.relowner),
      'columns', (
        SELECT jsonb_agg(jsonb_build_object(
          'name', attribute.attname,
          'type', format_type(attribute.atttypid, attribute.atttypmod),
          'notNull', attribute.attnotnull,
          'default', pg_get_expr(default_value.adbin, default_value.adrelid)
        ) ORDER BY attribute.attnum)
        FROM pg_attribute AS attribute
        LEFT JOIN pg_attrdef AS default_value
          ON default_value.adrelid = attribute.attrelid AND default_value.adnum = attribute.attnum
        WHERE attribute.attrelid = relation.oid AND attribute.attnum > 0 AND NOT attribute.attisdropped
      ),
      'constraints', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'name', constraint_row.conname,
          'type', constraint_row.contype,
          'definition', pg_get_constraintdef(constraint_row.oid, true)
        ) ORDER BY constraint_row.conname), '[]'::jsonb)
        FROM pg_constraint AS constraint_row
        WHERE constraint_row.conrelid = relation.oid
      ),
      'triggers', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'name', trigger_row.tgname,
          'enabled', trigger_row.tgenabled,
          'definition', pg_get_triggerdef(trigger_row.oid, true)
        ) ORDER BY trigger_row.tgname), '[]'::jsonb)
        FROM pg_trigger AS trigger_row
        WHERE trigger_row.tgrelid = relation.oid AND NOT trigger_row.tgisinternal
      )
    ) ORDER BY relation.relname)
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public' AND relation.relkind IN ('r', 'p')
      AND relation.relname IN (
        'activity_date_changes', 'stage_date_changes', 'business_target_date_changes',
        'calendar_reschedule_changes', 'calendar_reschedule_reversals',
        'hierarchy_movement_events', 'schedule_deletion_events',
        'product_schedule_operations', 'product_schedule_operation_events',
        'product_schedule_operation_links', 'product_schedule_operation_source_events'
      )
  ),
  'foreignKeysReferencingLedgers', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sourceTable', source_relation.relname,
      'constraint', constraint_row.conname,
      'definition', pg_get_constraintdef(constraint_row.oid, true)
    ) ORDER BY source_relation.relname, constraint_row.conname), '[]'::jsonb)
    FROM pg_constraint AS constraint_row
    JOIN pg_class AS source_relation ON source_relation.oid = constraint_row.conrelid
    JOIN pg_namespace AS source_namespace ON source_namespace.oid = source_relation.relnamespace
    JOIN pg_class AS referenced_relation ON referenced_relation.oid = constraint_row.confrelid
    JOIN pg_namespace AS referenced_namespace ON referenced_namespace.oid = referenced_relation.relnamespace
    WHERE constraint_row.contype = 'f' AND referenced_namespace.nspname = 'public'
      AND referenced_relation.relname IN (
        'activity_date_changes', 'stage_date_changes', 'business_target_date_changes',
        'calendar_reschedule_changes', 'calendar_reschedule_reversals',
        'hierarchy_movement_events', 'schedule_deletion_events'
      )
  ),
  'relevantFunctions', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'signature', proc.oid::regprocedure::text,
      'owner', pg_get_userbyid(proc.proowner),
      'securityDefiner', proc.prosecdef,
      'configuration', proc.proconfig,
      'referencesStageLedger', position('public.stage_date_changes' IN pg_get_functiondef(proc.oid)) > 0
    ) ORDER BY proc.proname, proc.oid), '[]'::jsonb)
    FROM pg_proc AS proc
    JOIN pg_namespace AS namespace ON namespace.oid = proc.pronamespace
    WHERE namespace.nspname = 'public' AND proc.proname IN (
      'change_activity_dates', 'change_discipline_stage_dates', 'update_business_target',
      'move_schedule_item', 'delete_schedule_subtree', 'apply_calendar_reschedule',
      'reverse_calendar_reschedule', 'link_product_schedule_audit_source',
      'capture_product_schedule_mutation', 'write_product_schedule_operation_event',
      'list_product_change_history', 'list_product_schedule_operations',
      'link_product_schedule_operation_source_events'
    )
  ),
  'workerDirectLedgerPrivileges', (
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
      'activity_date_changes', 'stage_date_changes', 'business_target_date_changes',
      'calendar_reschedule_changes', 'calendar_reschedule_reversals',
      'hierarchy_movement_events', 'schedule_deletion_events',
      'product_schedule_state', 'product_schedule_operations',
      'product_schedule_operation_events', 'product_schedule_operation_links',
      'product_schedule_operation_source_events'
    )
  ),
  'dataCountsAndFingerprints', jsonb_build_object(
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
      'unresolvedStageGroupLinks', (SELECT count(*) FROM public.product_schedule_operation_links AS link
        WHERE link.source_ledger = 'stage_date_changes'
          AND NOT EXISTS (SELECT 1 FROM public.stage_date_changes AS audit
            WHERE audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
              AND audit.operation_id = link.source_operation_id)),
      'ambiguousStageOperationIds', (SELECT count(*) FROM (
        SELECT operation_id FROM public.stage_date_changes GROUP BY operation_id HAVING count(*) > 1
      ) AS duplicate_groups),
      'r00Snapshots', (SELECT count(*) FROM public.initial_schedule_revisions WHERE label = 'R00')
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
        E'\n' ORDER BY record.reversal_date_operation_id), '')) FROM public.calendar_reschedule_reversals AS record),
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
      'r00Snapshots', (SELECT md5(COALESCE(string_agg(record.id::text || '|' || record.snapshot::text,
        E'\n' ORDER BY record.id), ''))
        FROM public.initial_schedule_revisions AS record WHERE record.label = 'R00')
    )
  )
)) AS development_audit_inventory;

ROLLBACK;
