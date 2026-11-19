\set ON_ERROR_STOP on

BEGIN READ ONLY;
SELECT current_database() AS database_name, current_user AS migration_role,
  'rapid-mud-63974868' AS expected_project, 'br-delicate-glitter-b6mj0051' AS expected_branch;

SELECT
  EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.products'::regclass
    AND attname = 'planning_classification' AND NOT attisdropped) AS migration_0034_column_present,
  position('product.active IN (true, false)' IN pg_get_functiondef(
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) > 0 AS migration_0034_clone_source_rule_present,
  position('''planningClassification'', ''em_estudo''' IN pg_get_functiondef(
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) > 0 AS migration_0034_clone_status_present,
  to_regprocedure('public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid)') IS NULL
    AS migration_0035_helper_absent,
  position('AND id = p_source_product_id AND active = true' IN pg_get_functiondef(
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure)) > 0
    AS root_source_active_guard_present,
  position('AND id = p_target_product_id AND active = true' IN pg_get_functiondef(
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure)) > 0
    AS root_target_active_guard_present,
  position('planning_mode, working_day_duration, planning_calendar_version' IN
    pg_get_functiondef('public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) = 0
    AS stage_clone_metadata_still_missing,
  position('planned_start' IN pg_get_functiondef(
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) > 0 AS stage_date_clone_present;

SELECT
  (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) AS root_helper_owner,
  (SELECT prosecdef FROM pg_proc WHERE oid =
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) AS root_helper_security_definer,
  (SELECT proconfig FROM pg_proc WHERE oid =
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) AS root_helper_settings,
  (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) AS clone_product_owner,
  (SELECT prosecdef FROM pg_proc WHERE oid =
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) AS clone_product_security_definer,
  has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') AS executor_public_create,
  pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') AS worker_executor_member,
  has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT')
    AS worker_planning_mode_insert,
  has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planning_mode', 'INSERT')
    AS executor_planning_mode_insert;

-- Expect exactly one row: cloud_admin, ADMIN true, INHERIT false, SET false.
SELECT pg_get_userbyid(grantor) AS grantor, admin_option, inherit_option, set_option
FROM pg_catalog.pg_auth_members
WHERE roleid = 'jlproject_date_executor'::regrole AND member = 'neondb_owner'::regrole
ORDER BY grantor;

SELECT count(*) AS total_products,
  count(*) FILTER (WHERE active) AS active_products,
  count(*) FILTER (WHERE NOT active) AS archived_products,
  md5(COALESCE(string_agg(id::text || '|' || active::text || '|' || version::text || '|' ||
    name || '|' || COALESCE(description, ''), E'\n' ORDER BY id), '')) AS product_fingerprint
FROM public.products;
SELECT count(*) AS r00_count,
  md5(COALESCE(string_agg(id::text || '|' || snapshot::text, E'\n' ORDER BY id), '')) AS r00_fingerprint
FROM public.initial_schedule_revisions WHERE label = 'R00';
SELECT count(*) AS cursor_count,
  md5(COALESCE(string_agg(product_id::text || '|' || schedule_version::text || '|' ||
    history_watermark::text, E'\n' ORDER BY product_id), '')) AS cursor_fingerprint
FROM public.product_schedule_state;
SELECT count(*) AS operation_count,
  md5(COALESCE(string_agg(workspace_id::text || '|' || product_id::text || '|' ||
    schedule_version::text || '|' || operation_id::text || '|' || operation_type,
    E'\n' ORDER BY workspace_id, product_id, schedule_version), '')) AS operation_fingerprint
FROM public.product_schedule_operations;
SELECT 'product_disciplines' AS entity, count(*) AS row_count,
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) AS fingerprint FROM public.product_disciplines t
UNION ALL SELECT 'discipline_stages', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.discipline_stages t
UNION ALL SELECT 'stage_activities', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.stage_activities t
UNION ALL SELECT 'business_targets', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.business_targets t;
COMMIT;
