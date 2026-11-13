-- REL-03O: rollback-only root activity verification for migration 0025.
-- Run as jlproject_worker on br-snowy-wave-b6vn905p only.
\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'roots', (SELECT count(*) FROM public.stage_activities
    WHERE discipline_id IS NULL AND stage_id IS NULL),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events),
  'calendar_state', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('workspace_id', c.workspace_id, 'version', c.version,
      'updated_at', c.updated_at)::text, '|' ORDER BY c.workspace_id::text), ''))
    FROM public.workspace_calendar_versions AS c),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS baseline
\gset rel03o_
ROLLBACK;

SELECT 1 / CASE WHEN
  (:'rel03o_baseline'::jsonb->>'products')::bigint = 5 AND
  (:'rel03o_baseline'::jsonb->>'disciplines')::bigint = 19 AND
  (:'rel03o_baseline'::jsonb->>'stages')::bigint = 40 AND
  (:'rel03o_baseline'::jsonb->>'activities')::bigint = 73 AND
  (:'rel03o_baseline'::jsonb->>'roots')::bigint = 0 AND
  (:'rel03o_baseline'::jsonb->>'date_audits')::bigint = 3 AND
  (:'rel03o_baseline'::jsonb->>'r00')::bigint = 1 AND
  (:'rel03o_baseline'::jsonb->>'dates') = '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS reported_baseline_matches;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '3min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_direct_target uuid;
  v_direct_clone uuid;
  v_clone uuid;
  v_source_r00 uuid;
  v_clone_r00 uuid;
  v_discipline uuid;
  v_definition uuid;
  v_stage uuid;
  v_root_working uuid;
  v_root_manual uuid;
  v_stage_activity uuid;
  v_calendar bigint;
  v_next_calendar bigint;
  v_calendar_batch uuid;
  v_start date := DATE '2030-03-04';
  v_calendar_result jsonb;
  v_result jsonb;
  v_preview jsonb;
  v_clone_result jsonb;
  v_snapshot jsonb;
  v_source_snapshot jsonb;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_calendar_attempts integer := 0;
  v_deletion_operation uuid := gen_random_uuid();
  v_reason text := 'Synthetic root activity verification only';
  v_activity_hash_before text;
  v_activity_hash_after text;
  v_date_audit_hash_before text;
  v_date_audit_hash_after text;
  v_r00_hash_before text;
  v_r00_hash_after text;
  v_error_seen boolean;
  v_error_message text;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' THEN
    RAISE EXCEPTION 'REL-03O requires neondb and the limited Worker role.';
  END IF;
  IF NOT has_function_privilege(current_user,
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'INSERT') OR
     has_table_privilege(current_user, 'public.stage_activities', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'DELETE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'member') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Worker or date-executor permissions are broader than approved.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc
      WHERE oid = 'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure
        AND pg_get_userbyid(proowner) = 'jlproject_date_executor'
        AND prosecdef) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.stage_activities'::regclass
        AND conname = 'stage_activities_parent_pair_check' AND convalidated) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.stage_activities'::regclass
        AND conname = 'stage_activities_product_scope_fk' AND convalidated) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.activity_date_changes'::regclass
        AND conname = 'activity_date_changes_product_scope_fk' AND convalidated) OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_activities'::regclass
         AND tgname = 'stage_activities_deletion_guard'
         AND tgfoid = 'public.guard_schedule_deletion()'::regprocedure
         AND tgenabled = 'O' AND NOT tgisinternal
         AND (tgtype & 2) = 2 AND (tgtype & 4) = 4
         AND (tgtype & 16) = 16 AND (tgtype & 8) = 8) THEN
    RAISE EXCEPTION 'REL-03O root constraints, owner, or ledger boundary differ.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', true, 'jlproject_date_executor'),
      ('public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', true, 'jlproject_date_executor'),
      ('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', true, 'jlproject_date_executor'),
      ('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', true, 'jlproject_date_executor'),
      ('public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', true, 'jlproject_date_executor'),
      ('public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', true, 'jlproject_date_executor'),
      ('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', true, 'jlproject_date_executor'),
      ('public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', true, 'jlproject_date_executor'),
      ('public.clone_product(uuid,uuid,uuid,text)', false, 'neondb_owner')
    ) AS expected(signature, is_definer, owner_name)
    LEFT JOIN pg_proc AS p ON p.oid = to_regprocedure(expected.signature)
    WHERE p.oid IS NULL OR p.prosecdef IS DISTINCT FROM expected.is_definer
      OR pg_get_userbyid(p.proowner) IS DISTINCT FROM expected.owner_name
      OR NOT has_function_privilege(current_user, p.oid, 'EXECUTE')
      OR has_function_privilege('public', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'Rewritten function ownership, context, or EXECUTE grant differs.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
      AND c.relname IN ('products','product_disciplines','stage_definitions',
        'discipline_stages','stage_activities','initial_schedule_revisions',
        'workspace_calendar_versions','workspace_calendar_exceptions',
        'workspace_calendar_events','activity_date_changes',
        'calendar_reschedule_changes','calendar_reschedule_reversals',
        'schedule_deletion_events')
      AND ((t.tgtype & 4) IS DISTINCT FROM 0 OR (t.tgtype & 16) IS DISTINCT FROM 0 OR (t.tgtype & 8) IS DISTINCT FROM 0)
      AND t.tgname NOT IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard','stage_activities_deletion_guard',
        'stage_activities_dates_immutable','initial_schedule_revisions_immutable',
        'workspace_calendar_events_append_only','activity_date_changes_append_only',
        'calendar_reschedule_changes_append_only',
        'calendar_reschedule_reversals_append_only',
        'schedule_deletion_events_immutable')) THEN
    RAISE EXCEPTION 'Unreviewed trigger could have external effects.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
  FROM public.workspace_memberships AS membership
  WHERE membership.active AND membership.role = 'admin'
  ORDER BY membership.workspace_id, membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'An active administrator is required.'; END IF;

  SELECT md5(COALESCE(string_agg(to_jsonb(activity)::text, '|' ORDER BY activity.id), ''))
    INTO v_activity_hash_before FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace;
  SELECT md5(COALESCE(string_agg(to_jsonb(change)::text, '|' ORDER BY change.operation_id), ''))
    INTO v_date_audit_hash_before FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace;
  SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text, '|' ORDER BY revision.id), ''))
    INTO v_r00_hash_before FROM public.initial_schedule_revisions AS revision
    WHERE revision.workspace_id = v_workspace;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;
  WHILE EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
      WHERE exception.workspace_id = v_workspace AND exception.removed_at IS NULL
        AND exception.start_date <= v_start + 3 AND exception.end_date >= v_start) LOOP
    v_calendar_attempts := v_calendar_attempts + 1;
    IF v_calendar_attempts > 26 THEN
      RAISE EXCEPTION 'No clear synthetic calendar date window was found.';
    END IF;
    v_start := v_start + 7;
  END LOOP;

  IF EXISTS (SELECT 1 FROM public.products
      WHERE name LIKE 'REL03O synthetic %') THEN
    RAISE EXCEPTION 'Existing REL-03O marker; inspect before testing.';
  END IF;
  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
  VALUES (v_workspace, 'REL03O synthetic source ' || v_marker,
    'Rollback-only root activity verification', v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
  VALUES (v_workspace, 'REL03O synthetic direct target ' || v_marker,
    v_actor, v_actor) RETURNING id INTO v_direct_target;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'Synthetic stage discipline',
    'R' || left(replace(gen_random_uuid()::text, '-', ''), 10), '#334455', 0, v_actor, v_actor)
  RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R' || left(replace(gen_random_uuid()::text, '-', ''), 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition, 'Synthetic stage', 0, v_actor, v_actor)
  RETURNING id INTO v_stage;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    NULL, NULL, v_actor, 'Synthetic root working plan', NULL, v_start, v_start + 1,
    0, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Root working-day activity creation failed.'; END IF;
  v_root_working := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic stage working plan', NULL, v_start, v_start + 1,
    0, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Stage working-day activity creation failed.'; END IF;
  v_stage_activity := (v_result->>'id')::uuid;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, NULL, NULL, 'Synthetic default-color root activity',
    v_start, v_start + 1, 1, v_actor, v_actor)
  RETURNING id INTO v_root_manual;
  UPDATE public.stage_activities SET color_override = '#123456', version = version + 1,
    updated_by = v_actor, updated_at = clock_timestamp()
  WHERE workspace_id = v_workspace AND product_id = v_product AND id = v_root_working AND version = 1;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_root_working
      AND discipline_id IS NULL AND stage_id IS NULL AND version = 2
      AND planning_mode = 'working_days' AND color_override = '#123456') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity
      AND discipline_id = v_discipline AND stage_id = v_stage) THEN
    RAISE EXCEPTION 'Root or conventional stage ancestry differs.';
  END IF;

  -- The BEFORE INSERT guard raises 23514 for missing or mismatched product scope
  -- before the product-scope foreign key could raise 23503.
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, NULL, v_stage, 'Invalid mixed-parent activity', 2, v_actor, v_actor);
  EXCEPTION WHEN SQLSTATE '23514' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Mixed root/stage parent pair was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, NULL,
      'Invalid reverse mixed-parent activity', 2, v_actor, v_actor);
  EXCEPTION WHEN SQLSTATE '23514' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Reverse mixed parent pair was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, gen_random_uuid(), NULL, NULL, 'Invalid product scope', 2, v_actor, v_actor);
  EXCEPTION WHEN SQLSTATE '23514' THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    v_error_seen := v_error_message IS NOT DISTINCT FROM 'Parent product or stage is inactive.';
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Activity without a direct product/workspace owner was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (gen_random_uuid(), v_product, NULL, NULL,
      'Invalid workspace scope', 2, v_actor, v_actor);
  EXCEPTION WHEN SQLSTATE '23514' THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    v_error_seen := v_error_message IS NOT DISTINCT FROM 'Parent product or stage is inactive.';
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Root crossed workspace scope.'; END IF;
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, v_direct_target, v_discipline, v_stage,
      'Invalid cross-product stage', 2, v_actor, v_actor);
  EXCEPTION WHEN SQLSTATE '23514' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Stage ancestry crossed product scope.'; END IF;

  v_result := public.change_activity_planning(v_workspace, v_product, NULL, NULL,
    v_root_manual, v_actor, gen_random_uuid(), 'manual', v_start + 1,
    v_start + 2, NULL, NULL, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id = v_product
      AND change.activity_id = v_root_manual AND change.discipline_id IS NULL
      AND change.stage_id IS NULL AND change.previous_start = v_start
      AND change.new_start = v_start + 1 AND change.version_after = 2
  ) THEN RAISE EXCEPTION 'Manual root date audit or version differs.'; END IF;

  -- Date changes through the same guarded function must create nullable-parent audit rows.
  v_result := public.change_activity_planning(v_workspace, v_product, NULL, NULL,
    v_root_working, v_actor, gen_random_uuid(), 'working_days', v_start + 1,
    v_start + 2, 2, v_calendar, v_reason, 2);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id = v_product
      AND change.activity_id = v_root_working AND change.discipline_id IS NULL
      AND change.stage_id IS NULL AND change.previous_start = v_start
      AND change.new_start = v_start + 1 AND change.version_after = 3
  ) THEN RAISE EXCEPTION 'Root date audit did not persist with a NULL parent pair.'; END IF;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline, v_stage,
    v_stage_activity, v_actor, gen_random_uuid(), 'working_days', v_start + 1,
    v_start + 2, 2, v_calendar, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id = v_product
      AND change.activity_id = v_stage_activity AND change.discipline_id = v_discipline
      AND change.stage_id = v_stage AND change.version_after = 2
  ) THEN RAISE EXCEPTION 'Stage date audit behavior changed.'; END IF;

  v_result := public.change_activity_planning(v_workspace, v_product, NULL, NULL,
    v_root_working, v_actor, gen_random_uuid(), 'working_days', v_start + 2,
    v_start + 3, 2, v_calendar, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'Stale root activity version was accepted.'; END IF;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    NULL, NULL, gen_random_uuid(), 'Synthetic denied root', NULL, v_start, v_start + 1,
    3, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Unqualified actor created a root activity.'; END IF;
  IF (public.preview_schedule_deletion(gen_random_uuid(), v_product, v_actor,
      'activity', v_root_working)->>'status') IS DISTINCT FROM 'forbidden' OR
     (public.preview_schedule_deletion(v_workspace, gen_random_uuid(), v_actor,
      'activity', v_root_working)->>'status') IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Workspace or product isolation failed for root activity operations.';
  END IF;

  v_direct_clone := public.clone_root_activity(v_workspace, v_product,
    v_direct_target, v_actor, v_root_working);
  IF v_direct_clone IS NULL OR v_direct_clone = v_root_working OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS a
       WHERE a.id = v_direct_clone AND a.workspace_id = v_workspace
         AND a.product_id = v_direct_target AND a.discipline_id IS NULL
         AND a.stage_id IS NULL AND a.name = 'Synthetic root working plan'
         AND a.planned_start = v_start + 1 AND a.planned_end = v_start + 2
         AND a.display_order = 0 AND a.color_override = '#123456'
         AND a.planning_mode = 'working_days' AND a.working_day_duration = 2
         AND a.planning_calendar_version = v_calendar AND a.version = 1) THEN
    RAISE EXCEPTION 'Direct root clone content or scope differs.';
  END IF;
  v_error_seen := false;
  BEGIN
    PERFORM public.clone_root_activity(v_workspace,v_product,v_product,
      v_actor,v_root_working);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Same-product root clone was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    PERFORM public.clone_root_activity(v_workspace,v_product,v_direct_target,
      gen_random_uuid(),v_root_working);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Unauthorized root clone was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    PERFORM public.clone_root_activity(gen_random_uuid(),v_product,v_direct_target,
      v_actor,v_root_working);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Cross-workspace root clone was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    PERFORM public.clone_root_activity(v_workspace,v_product,v_direct_target,
      v_actor,v_stage_activity);
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Stage activity was cloned as a root.'; END IF;
  v_error_seen := false;
  BEGIN
    PERFORM public.clone_root_activity(v_workspace,v_direct_target,v_product,
      v_actor,v_root_working);
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Foreign product root lookup succeeded.'; END IF;

  v_source_snapshot := jsonb_build_object(
    'product', jsonb_build_object('id', v_product,
      'name', 'REL03O synthetic source ' || v_marker),
    'rootActivities', '[]'::jsonb, 'disciplines', '[]'::jsonb,
    'sourceMeta', '[]'::jsonb, 'targets', '[]'::jsonb,
    'actualStageColors', '{}'::jsonb, 'disciplineIds', '{}'::jsonb,
    'stageIds', '[]'::jsonb, 'activityIds', '{}'::jsonb, 'dependencies', '[]'::jsonb);
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (v_workspace, v_product, NULL, v_source_snapshot, v_actor)
  RETURNING id INTO v_source_r00;
  v_clone_result := public.clone_product(v_workspace, v_product, v_actor,
    'REL03O synthetic clone ' || v_marker);
  IF v_clone_result->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Synthetic product clone failed.'; END IF;
  v_clone := (v_clone_result->'product'->>'id')::uuid;
  v_clone_r00 := (v_clone_result->>'revisionId')::uuid;
  SELECT snapshot INTO v_snapshot FROM public.initial_schedule_revisions
    WHERE workspace_id = v_workspace AND product_id = v_clone
      AND id = v_clone_r00 AND label = 'R00' AND import_batch_id IS NULL;
  IF v_snapshot IS NULL OR v_clone = v_product OR v_clone_r00 = v_source_r00 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE product_id = v_clone) IS DISTINCT FROM 1 OR
     jsonb_array_length(v_snapshot->'rootActivities') IS DISTINCT FROM 2 OR
     jsonb_array_length(v_snapshot->'disciplines') IS DISTINCT FROM 1 OR
     jsonb_array_length(v_snapshot->'disciplines'->0->'stages') IS DISTINCT FROM 1 OR
     jsonb_array_length(v_snapshot->'disciplines'->0->'stages'->0->'activities') IS DISTINCT FROM 1 OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_clone AND discipline_id IS NULL AND stage_id IS NULL) IS DISTINCT FROM 2 OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_clone AND discipline_id IS NOT NULL AND stage_id IS NOT NULL) IS DISTINCT FROM 1 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS source
       JOIN public.stage_activities AS clone ON clone.workspace_id = v_workspace
         AND clone.product_id = v_clone AND clone.name = source.name
       WHERE source.workspace_id = v_workspace AND source.product_id = v_product
         AND source.id = v_root_working AND clone.id IS DISTINCT FROM source.id
         AND clone.color_override = '#123456' AND clone.planning_mode = 'working_days'
         AND clone.working_day_duration = 2 AND clone.planning_calendar_version = v_calendar
         AND clone.planned_start = v_start + 1 AND clone.planned_end = v_start + 2
         AND clone.display_order = 0) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS a
       JOIN public.discipline_stages AS s ON s.id = a.stage_id
       JOIN public.product_disciplines AS d ON d.id = a.discipline_id
       WHERE a.product_id = v_clone AND s.product_id = v_clone
         AND d.product_id = v_clone AND a.name = 'Synthetic stage working plan'
         AND a.discipline_id IS NOT NULL AND a.stage_id IS NOT NULL
         AND a.planned_start = v_start + 1 AND a.planned_end = v_start + 2
         AND a.display_order = 0) OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot->'rootActivities') AS root
       WHERE root->>'effectiveColor' = '#8D9A89' AND root->'colorOverride' = 'null'::jsonb) OR
     (SELECT snapshot FROM public.initial_schedule_revisions WHERE id = v_source_r00)
       IS DISTINCT FROM v_source_snapshot THEN
    RAISE EXCEPTION 'Root activity clone or independent R00 baseline failed.';
  END IF;

  v_calendar_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback root schedule closure', v_start + 2, v_start + 2);
  IF v_calendar_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Synthetic calendar change failed.'; END IF;
  v_next_calendar := (v_calendar_result->>'version')::bigint;
  v_calendar_batch := gen_random_uuid();
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_calendar_batch,
    v_next_calendar, v_reason, jsonb_build_array(
      jsonb_build_object('activityId', v_root_working, 'disciplineId', NULL, 'stageId', NULL,
        'expectedVersion', 3, 'startDate', v_start + 1, 'currentEndDate', v_start + 2,
        'proposedEndDate', v_start + 3, 'workingDays', 2, 'savedCalendarVersion', v_calendar),
      jsonb_build_object('activityId', v_stage_activity, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 2, 'startDate', v_start + 1, 'currentEndDate', v_start + 2,
        'proposedEndDate', v_start + 3, 'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Calendar rescheduling did not update root and stage activities atomically.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_root_working
      AND planned_end = v_start + 3 AND version = 4
      AND planning_calendar_version = v_next_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity
      AND planned_end = v_start + 3 AND version = 3
      AND planning_calendar_version = v_next_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
      WHERE product_id = v_product AND activity_id = v_root_working
        AND discipline_id IS NULL AND stage_id IS NULL
        AND version_before = 3 AND version_after = 4
        AND new_end = v_start + 3) THEN
    RAISE EXCEPTION 'Root calendar apply date, version, or audit differs.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_calendar_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR (v_result->>'count')::integer IS DISTINCT FROM 2 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_root_working
       AND discipline_id IS NULL AND stage_id IS NULL AND planned_end = v_start + 2
       AND version = 5 AND planning_calendar_version = v_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity
       AND discipline_id = v_discipline AND stage_id = v_stage AND planned_end = v_start + 2
       AND version = 4 AND planning_calendar_version = v_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE product_id = v_product AND activity_id = v_root_working
         AND discipline_id IS NULL AND stage_id IS NULL
         AND version_before = 4 AND version_after = 5
         AND new_end = v_start + 2) THEN
    RAISE EXCEPTION 'Calendar reversal failed for root or stage activity.';
  END IF;

  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_root_manual);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR
     (v_preview->'counts'->>'activities')::integer IS DISTINCT FROM 1 OR
     jsonb_array_length(v_preview->'items') IS DISTINCT FROM 1 OR
     v_preview->'items'->0->>'id' IS DISTINCT FROM v_root_manual::text OR
     v_preview->>'fingerprint' IS DISTINCT FROM md5((v_preview->'items')::text) THEN
    RAISE EXCEPTION 'Root soft-delete preview omitted the root activity.';
  END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, v_deletion_operation,
    'activity', v_root_manual, v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR
     v_result->>'operationId' IS DISTINCT FROM v_deletion_operation::text OR
     NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_root_manual
      AND deleted_at IS NOT NULL AND deletion_operation_id = v_deletion_operation
      AND discipline_id IS NULL AND stage_id IS NULL AND version = 3
  ) THEN RAISE EXCEPTION 'Root soft deletion failed.'; END IF;
  v_result := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_root_manual);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Deleted root remained active in preview.';
  END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor,
    gen_random_uuid(), 'activity', v_root_manual,
    v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Repeated root deletion was accepted.';
  END IF;
  v_error_seen := false;
  BEGIN
    UPDATE public.stage_activities SET name = 'Invalid deleted root edit'
      WHERE id = v_root_manual;
  EXCEPTION WHEN SQLSTATE '23514' THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Deleted root was mutable.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_root_working
      AND deleted_at IS NULL AND deletion_operation_id IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_direct_clone
      AND deleted_at IS NULL AND deletion_operation_id IS NULL) THEN
    RAISE EXCEPTION 'Root deletion affected unrelated activities.';
  END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor, 'stage', v_stage);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR (v_preview->'counts'->>'activities')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Stage soft-delete behavior changed or included root activities.';
  END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, gen_random_uuid(),
    'stage', v_stage, v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity AND deleted_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Stage activity soft deletion failed.'; END IF;

  SELECT md5(COALESCE(string_agg(to_jsonb(activity)::text, '|' ORDER BY activity.id), ''))
    INTO v_activity_hash_after FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace
      AND activity.product_id NOT IN (v_product, v_direct_target, v_clone);
  SELECT md5(COALESCE(string_agg(to_jsonb(change)::text, '|' ORDER BY change.operation_id), ''))
    INTO v_date_audit_hash_after FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace
      AND change.product_id NOT IN (v_product, v_direct_target, v_clone);
  SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text, '|' ORDER BY revision.id), ''))
    INTO v_r00_hash_after FROM public.initial_schedule_revisions AS revision
    WHERE revision.workspace_id = v_workspace
      AND revision.product_id NOT IN (v_product, v_direct_target, v_clone);
  IF v_activity_hash_after IS DISTINCT FROM v_activity_hash_before OR
     v_date_audit_hash_after IS DISTINCT FROM v_date_audit_hash_before OR
     v_r00_hash_after IS DISTINCT FROM v_r00_hash_before OR
     (SELECT snapshot FROM public.initial_schedule_revisions WHERE id = v_source_r00)
       IS DISTINCT FROM v_source_snapshot THEN
    RAISE EXCEPTION 'Existing workspace activities, audit records, or R00 snapshots changed.';
  END IF;
  RAISE NOTICE 'REL-03O root hierarchy, planning, calendar, deletion, cloning, grants, and existing-record preservation passed.';
END;
$$;

-- A separate statement lets the STABLE history function see the prior DO writes.
DO $$
DECLARE
  v_product record;
  v_history jsonb;
  v_root uuid;
  v_deleted_root uuid;
BEGIN
  SELECT id, workspace_id, created_by INTO v_product FROM public.products
    WHERE name LIKE 'REL03O synthetic source %';
  IF NOT FOUND THEN RAISE EXCEPTION 'Synthetic source for history check is missing.'; END IF;
  SELECT id INTO v_root FROM public.stage_activities
    WHERE product_id = v_product.id AND name = 'Synthetic root working plan';
  SELECT id INTO v_deleted_root FROM public.stage_activities
    WHERE product_id = v_product.id AND name = 'Synthetic default-color root activity';
  v_history := public.list_product_change_history(
    v_product.workspace_id, v_product.id, v_product.created_by, 100, NULL, NULL);
  IF v_history->>'status' IS DISTINCT FROM 'ok' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_history->'events') AS event
    WHERE event->>'eventType' = 'activity_dates_changed'
      AND event->'item'->>'id' = v_root::text
      AND event->'item'->'hierarchy'->>'discipline' IS NULL
      AND event->'item'->'hierarchy'->>'stage' IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_history->'events') AS event
    WHERE event->>'eventType' = 'schedule_hierarchy_deleted'
      AND event->'item'->>'id' = v_deleted_root::text
  ) THEN RAISE EXCEPTION 'Product history omitted root activity events.'; END IF;
  RAISE NOTICE 'REL-03O root history visibility passed.';
END;
$$;

ROLLBACK;

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'roots', (SELECT count(*) FROM public.stage_activities
    WHERE discipline_id IS NULL AND stage_id IS NULL),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events),
  'calendar_state', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('workspace_id', c.workspace_id, 'version', c.version,
      'updated_at', c.updated_at)::text, '|' ORDER BY c.workspace_id::text), ''))
    FROM public.workspace_calendar_versions AS c),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS after_rollback
\gset rel03o_
SELECT 1 / CASE WHEN
  :'rel03o_after_rollback'::jsonb = :'rel03o_baseline'::jsonb AND
  NOT EXISTS (SELECT 1 FROM public.products WHERE name LIKE 'REL03O synthetic %')
  THEN 1 ELSE 0 END AS full_accessible_baseline_preserved;
ROLLBACK;
