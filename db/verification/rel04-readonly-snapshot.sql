-- REL-04: branch-pinned by the operator; one sanitized JSON result, no data rows.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
WITH rows AS (
  SELECT 'workspaces' AS relation, id::text AS row_key, to_jsonb(t)::text AS row_value FROM public.workspaces t
  UNION ALL SELECT 'workspace_memberships', workspace_id::text || ':' || auth_user_id::text,
    to_jsonb(t)::text FROM public.workspace_memberships t
  UNION ALL SELECT 'products', id::text, to_jsonb(t)::text FROM public.products t
  UNION ALL SELECT 'product_disciplines', id::text,
    (to_jsonb(t) - 'deleted_at' - 'deletion_operation_id')::text FROM public.product_disciplines t
  UNION ALL SELECT 'stage_definitions', id::text, to_jsonb(t)::text FROM public.stage_definitions t
  UNION ALL SELECT 'discipline_stages', id::text,
    (to_jsonb(t) - 'deleted_at' - 'deletion_operation_id')::text FROM public.discipline_stages t
  UNION ALL SELECT 'stage_activities', id::text,
    (to_jsonb(t) - 'planning_mode' - 'working_day_duration' - 'planning_calendar_version'
      - 'deleted_at' - 'deletion_operation_id' - 'color_override')::text
    FROM public.stage_activities t
  UNION ALL SELECT 'business_targets', id::text, to_jsonb(t)::text FROM public.business_targets t
  UNION ALL SELECT 'import_batches', id::text, to_jsonb(t)::text FROM public.import_batches t
  UNION ALL SELECT 'import_source_rows', import_batch_id::text || ':' || source_sheet || ':' || source_row::text,
    to_jsonb(t)::text FROM public.import_source_rows t
  UNION ALL SELECT 'initial_schedule_revisions', id::text, to_jsonb(t)::text
    FROM public.initial_schedule_revisions t
  UNION ALL SELECT 'activity_date_changes', operation_id::text, to_jsonb(t)::text
    FROM public.activity_date_changes t
  UNION ALL SELECT 'business_target_date_changes', operation_id::text, to_jsonb(t)::text
    FROM public.business_target_date_changes t
), relation_names AS (
  SELECT unnest(ARRAY['workspaces','workspace_memberships','products','product_disciplines',
    'stage_definitions','discipline_stages','stage_activities','business_targets',
    'import_batches','import_source_rows','initial_schedule_revisions',
    'activity_date_changes','business_target_date_changes']) AS relation
), data_hashes AS (
  SELECT n.relation, count(r.row_key) AS row_count,
    md5(COALESCE(string_agg(r.row_value, '|' ORDER BY r.row_key), '')) AS row_hash
  FROM relation_names n LEFT JOIN rows r USING (relation) GROUP BY n.relation
), catalog_lines AS (
  -- PostgreSQL catalog "char" fields need explicit text conversion before concatenation.
  SELECT 'relation:' || c.relname || ':' || CAST(c.relkind AS text) || ':' ||
    pg_get_userbyid(c.relowner) || ':' || COALESCE(c.relacl::text, '') || ':' ||
    c.relrowsecurity || ':' || c.relforcerowsecurity AS value
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL SELECT 'column:' || c.relname || ':' || a.attname || ':' ||
    format_type(a.atttypid,a.atttypmod) || ':' || a.attnotnull || ':' ||
    COALESCE(pg_get_expr(d.adbin,d.adrelid),'') || ':' || COALESCE(a.attacl::text,'')
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL SELECT 'constraint:' || c.relname || ':' || con.conname || ':' ||
    pg_get_constraintdef(con.oid) || ':' || con.convalidated || ':' || con.condeferrable
    FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL SELECT 'index:' || c.relname || ':' || pg_get_indexdef(i.indexrelid)
    FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL SELECT 'trigger:' || c.relname || ':' || t.tgname || ':' || CAST(t.tgenabled AS text) || ':' ||
    pg_get_triggerdef(t.oid)
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL SELECT 'function:' || p.oid::regprocedure::text || ':' ||
    pg_get_userbyid(p.proowner) || ':' || COALESCE(p.proacl::text,'') || ':' ||
    COALESCE(p.proconfig::text,'') || ':' || pg_get_functiondef(p.oid)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
  UNION ALL SELECT 'membership:' || grantor.rolname || ':' || granted.rolname || ':' ||
    member.rolname || ':' || m.admin_option || ':' || m.inherit_option || ':' || m.set_option
    FROM pg_auth_members m JOIN pg_roles grantor ON grantor.oid = m.grantor
    JOIN pg_roles granted ON granted.oid = m.roleid
    JOIN pg_roles member ON member.oid = m.member
    WHERE granted.rolname LIKE 'jlproject_%' OR member.rolname LIKE 'jlproject_%'
  UNION ALL SELECT 'role:' || r.rolname || ':' || r.rolcanlogin || ':' ||
    r.rolsuper || ':' || r.rolcreaterole || ':' || r.rolcreatedb || ':' || r.rolinherit
    FROM pg_roles r WHERE r.rolname LIKE 'jlproject_%' OR r.rolname = 'neondb_owner'
  UNION ALL SELECT 'default_acl:' || pg_get_userbyid(d.defaclrole) || ':' ||
    COALESCE(n.nspname,'') || ':' || CAST(d.defaclobjtype AS text) || ':' || d.defaclacl::text
    FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
    WHERE n.nspname = 'public' OR d.defaclnamespace = 0
)
SELECT jsonb_build_object(
  'database', current_database(), 'role', current_user,
  'worker_sessions', (SELECT count(*) FROM pg_stat_activity
    WHERE datname = current_database() AND usename = 'jlproject_worker'),
  'data', (SELECT jsonb_object_agg(relation, jsonb_build_object('count', row_count,
    'hash', row_hash)) FROM data_hashes),
  'dates', (SELECT md5(COALESCE(string_agg(jsonb_build_object('id',a.id,
    'planned_start',a.planned_start,'planned_end',a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities a),
  'r00', (SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
    E'\n' ORDER BY r.id), '')) FROM public.initial_schedule_revisions r),
  'catalog_hash', (SELECT md5(COALESCE(string_agg(value, E'\n' ORDER BY value), ''))
    FROM catalog_lines),
  'markers', jsonb_build_object(
    'clone', to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NOT NULL,
    'calendar', to_regclass('public.workspace_calendar_versions') IS NOT NULL,
    'planning', EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
      AND attname = 'planning_mode' AND NOT attisdropped),
    'reschedule', to_regclass('public.calendar_reschedule_changes') IS NOT NULL,
    'reversal', to_regclass('public.calendar_reschedule_reversals') IS NOT NULL,
    'calendar_history', to_regprocedure('public.list_calendar_reschedule_history(uuid,uuid,uuid)') IS NOT NULL,
    'deletion', to_regclass('public.schedule_deletion_events') IS NOT NULL,
    'product_history', to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL,
    'color', EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
      AND attname = 'color_override' AND NOT attisdropped),
    'root_pair', EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
      AND conname = 'stage_activities_parent_pair_check' AND convalidated),
    'movement', to_regclass('public.hierarchy_movement_events') IS NOT NULL,
    'movement_history', COALESCE(position('public.hierarchy_movement_events' IN
      pg_get_functiondef(to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'))) > 0,false)
  )
)::text AS snapshot;
ROLLBACK;
