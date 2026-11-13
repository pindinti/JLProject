-- REL-03P: rollback-only migration 0026 movement verification.
-- Execute only as jlproject_worker on br-snowy-wave-b6vn905p.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'dates', (SELECT md5(COALESCE(string_agg(jsonb_build_object(
    'id', a.id, 'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a),
  'hierarchy', (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
    SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data FROM public.product_disciplines AS d
    UNION ALL SELECT 's', id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
    UNION ALL SELECT 'a', id::text, to_jsonb(a)::text FROM public.stage_activities AS a
  ) AS rows),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r),
  'target_fingerprint', (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text,
    '|' ORDER BY t.id::text), '')) FROM public.business_targets AS t),
  'source_row_count', (SELECT count(*) FROM public.import_source_rows)
) AS baseline
\gset rel03p_
ROLLBACK;
SELECT 1 / CASE WHEN
  (:'rel03p_baseline'::jsonb->>'products')::bigint = 5 AND
  (:'rel03p_baseline'::jsonb->>'disciplines')::bigint = 19 AND
  (:'rel03p_baseline'::jsonb->>'stages')::bigint = 40 AND
  (:'rel03p_baseline'::jsonb->>'activities')::bigint = 73 AND
  (:'rel03p_baseline'::jsonb->>'date_audits')::bigint = 3 AND
  (:'rel03p_baseline'::jsonb->>'r00')::bigint = 1 AND
  (:'rel03p_baseline'::jsonb->>'dates') = '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS reported_baseline_matches;
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '4min';
SET LOCAL idle_in_transaction_session_timeout = '6min';
DO $$
DECLARE
  v_workspace uuid;
  v_foreign_workspace uuid;
  v_actor uuid;
  v_editor uuid;
  v_denied_actor uuid;
  v_calendar_version bigint;
  v_product constant uuid := '7b000000-0000-4000-8000-000000000001';
  v_other_product constant uuid := '7b000000-0000-4000-8000-000000000020';
  v_discipline_a constant uuid := '7b000000-0000-4000-8000-000000000002';
  v_discipline_b constant uuid := '7b000000-0000-4000-8000-000000000003';
  v_definition_a constant uuid := '7b000000-0000-4000-8000-000000000004';
  v_definition_b constant uuid := '7b000000-0000-4000-8000-000000000005';
  v_stage_a constant uuid := '7b000000-0000-4000-8000-000000000006';
  v_stage_b constant uuid := '7b000000-0000-4000-8000-000000000007';
  v_activity_a uuid;
  v_activity_b uuid;
  v_root uuid;
  v_root_b uuid;
  v_target constant uuid := '7b000000-0000-4000-8000-000000000014';
  v_first_operation constant uuid := '7b000000-0000-4000-8000-00000000000b';
  v_result jsonb;
  v_before jsonb;
  v_dates_before text;
  v_original_hierarchy_before text;
  v_date_audit_count_before bigint;
  v_atomic_before text;
  v_expected_r00 jsonb := jsonb_build_object('dependencies', '[]'::jsonb, 'synthetic', true);
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' THEN
    RAISE EXCEPTION 'REL-03P requires neondb and the limited Worker role.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc
    WHERE oid = 'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure
      AND pg_get_userbyid(proowner) = 'jlproject_date_executor'
      AND prosecdef AND 'search_path=pg_catalog, pg_temp' = ANY(proconfig)) OR
     NOT has_function_privilege(current_user,
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.hierarchy_movement_events'::regclass) IS DISTINCT FROM 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_activities'::regclass
         AND conname = 'stage_activities_parent_fk' AND contype = 'f'
         AND condeferrable AND NOT condeferred) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.activity_date_changes'::regclass
         AND conname = 'activity_date_changes_product_scope_fk' AND convalidated) OR
     EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.activity_date_changes'::regclass
         AND conname = 'activity_date_changes_activity_fk') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'INSERT') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'UPDATE') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'DELETE') OR
     has_column_privilege(current_user, 'public.product_disciplines', 'display_order', 'UPDATE') OR
     has_column_privilege(current_user, 'public.discipline_stages', 'display_order', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'display_order', 'UPDATE') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Movement function, constraints, or Worker privilege boundary differs.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.hierarchy_movement_events'::regclass
        AND tgname = 'hierarchy_movement_events_immutable' AND tgenabled = 'O') OR
     EXISTS (SELECT 1 FROM pg_trigger AS t
       JOIN pg_class AS c ON c.oid = t.tgrelid
       WHERE c.oid IN ('public.products'::regclass,
         'public.product_disciplines'::regclass, 'public.stage_definitions'::regclass,
         'public.discipline_stages'::regclass, 'public.stage_activities'::regclass,
         'public.activity_date_changes'::regclass,
         'public.initial_schedule_revisions'::regclass,
         'public.business_targets'::regclass,
         'public.hierarchy_movement_events'::regclass)
         AND NOT t.tgisinternal AND t.tgenabled IN ('O', 'A')
         AND t.tgname NOT IN ('product_disciplines_deletion_guard',
           'discipline_stages_deletion_guard', 'stage_activities_deletion_guard',
           'stage_activities_dates_immutable', 'activity_date_changes_append_only',
           'initial_schedule_revisions_immutable', 'business_targets_audit_date_update',
           'hierarchy_movement_events_immutable')) THEN
    RAISE EXCEPTION 'Movement audit trigger or write-trigger inventory differs.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE id IN (v_product, v_other_product)
      OR name LIKE 'REL03P synthetic %') OR
     EXISTS (SELECT 1 FROM public.stage_definitions
       WHERE code IN ('7P-SA', '7P-SB')) THEN
    RAISE EXCEPTION 'Existing REL-03P fixture marker or code; stop.';
  END IF;
  SELECT workspace_id, auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships
  WHERE active = true AND role IN ('admin', 'editor')
  ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, workspace_id, auth_user_id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'An active synthetic-test writer is required.'; END IF;
  SELECT auth_user_id INTO v_editor FROM public.workspace_memberships
    WHERE workspace_id = v_workspace AND active = true AND role = 'editor' LIMIT 1;
  SELECT COALESCE((SELECT auth_user_id FROM public.workspace_memberships
      WHERE workspace_id = v_workspace AND active = true AND role = 'viewer' LIMIT 1), gen_random_uuid())
    INTO v_denied_actor;

  SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), ''))
    INTO v_original_hierarchy_before FROM (
      SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d
      UNION ALL SELECT 's', id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
      UNION ALL SELECT 'a', id::text, to_jsonb(a)::text FROM public.stage_activities AS a
    ) AS original_rows;

  INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
    VALUES (v_product, v_workspace, 'REL03P synthetic rollback product', v_actor, v_actor);
  INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
    VALUES (v_other_product, v_workspace, 'REL03P synthetic other product', v_actor, v_actor);
  INSERT INTO public.product_disciplines
    (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES
    (v_discipline_a, v_workspace, v_product, 'Synthetic discipline A', '7P-A', '#112233', 0, v_actor, v_actor),
    (v_discipline_b, v_workspace, v_product, 'Synthetic discipline B', '7P-B', '#223344', 1, v_actor, v_actor);
  INSERT INTO public.stage_definitions (id, workspace_id, code, color) VALUES
    (v_definition_a, v_workspace, '7P-SA', '#334455'),
    (v_definition_b, v_workspace, '7P-SB', '#445566');
  INSERT INTO public.discipline_stages
    (id, workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES
    (v_stage_a, v_workspace, v_product, v_discipline_a, v_definition_a,
      'Synthetic stage A', 0, v_actor, v_actor),
    (v_stage_b, v_workspace, v_product, v_discipline_a, v_definition_b,
      'Synthetic stage B', 1, v_actor, v_actor);
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, color_override, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline_a, v_stage_a,
    'Synthetic activity A', DATE '2026-11-02', DATE '2026-11-03', 0, NULL, v_actor, v_actor)
  RETURNING id INTO v_activity_a;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, color_override, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline_a, v_stage_a,
    'Synthetic activity B', DATE '2026-11-04', DATE '2026-11-05', 1, '#AA5577', v_actor, v_actor)
  RETURNING id INTO v_activity_b;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, color_override, created_by, updated_by)
  VALUES (v_workspace, v_product, NULL, NULL,
    'Synthetic root activity A', DATE '2026-11-06', DATE '2026-11-07', 0, NULL, v_actor, v_actor)
  RETURNING id INTO v_root;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, color_override, created_by, updated_by)
  VALUES (v_workspace, v_product, NULL, NULL,
    'Synthetic root activity B', DATE '2026-11-08', DATE '2026-11-09', 1, '#BB6677', v_actor, v_actor)
  RETURNING id INTO v_root_b;
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (v_workspace, v_product, NULL, v_expected_r00, v_actor);
  INSERT INTO public.business_targets
    (id, workspace_id, product_id, name, target_date, display_order, source_external_id,
     source_row, created_by)
  VALUES (v_target, v_workspace, v_product, 'Synthetic movement target', DATE '2026-11-10',
    0, NULL, NULL, v_actor);

  -- A date audit must retain its original stage parent after later movement.
  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline_a, v_stage_a,
    v_activity_b, v_actor, '7b000000-0000-4000-8000-000000000015',
    DATE '2026-11-05', DATE '2026-11-06', 'Synthetic movement history check', 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'The synthetic date audit setup failed.'; END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_version;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline_a, v_stage_a,
    v_activity_b, v_actor, '7b000000-0000-4000-8000-00000000001c', 'working_days',
    DATE '2026-11-05', DATE '2026-11-06', 2, v_calendar_version,
    'Synthetic movement duration metadata', 2);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'The synthetic working-duration setup failed.'; END IF;

  SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
    'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) INTO v_dates_before
    FROM public.stage_activities AS a WHERE a.product_id = v_product;
  SELECT count(*) INTO v_date_audit_count_before
    FROM public.activity_date_changes WHERE product_id = v_product;

  -- Stage reorder within its current discipline.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000001d', 'stage', v_stage_b, 1,
    v_discipline_a, NULL, 0,
    jsonb_build_array(v_stage_a::text, v_stage_b::text),
    jsonb_build_array(v_stage_a::text, v_stage_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT display_order FROM public.discipline_stages WHERE id = v_stage_b) IS DISTINCT FROM 0 OR
     (SELECT display_order FROM public.discipline_stages WHERE id = v_stage_a) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The stage reorder failed.';
  END IF;

  -- valid activity reorder
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor, v_first_operation,
    'activity', v_activity_b, 3, v_discipline_a, v_stage_a, 0,
    jsonb_build_array(v_activity_a::text, v_activity_b::text),
    jsonb_build_array(v_activity_a::text, v_activity_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_b) IS DISTINCT FROM 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_a) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The valid activity reorder failed.';
  END IF;

  -- Product-root activity reorder.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000016', 'activity', v_root_b, 1,
    NULL, NULL, 0, jsonb_build_array(v_root::text, v_root_b::text),
    jsonb_build_array(v_root::text, v_root_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root_b) IS DISTINCT FROM 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The product-root activity reorder failed.';
  END IF;

  IF v_editor IS NOT NULL THEN
    v_result := public.move_schedule_item(v_workspace, v_product, v_editor,
      '7b000000-0000-4000-8000-00000000001a', 'activity', v_root_b, 2,
      NULL, NULL, 0, jsonb_build_array(v_root_b::text, v_root::text),
      jsonb_build_array(v_root_b::text, v_root::text));
    IF v_result->>'status' IS DISTINCT FROM 'unchanged' THEN RAISE EXCEPTION 'The editor movement authorization failed.'; END IF;
  END IF;

  -- A workspace outside the actor's membership cannot accept this move.
  SELECT workspace.id INTO v_foreign_workspace FROM public.workspaces AS workspace
  WHERE workspace.id IS DISTINCT FROM v_workspace AND NOT EXISTS (
    SELECT 1 FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = workspace.id AND membership.auth_user_id = v_actor
      AND membership.active = true
  ) ORDER BY workspace.id LIMIT 1;
  IF v_foreign_workspace IS NOT NULL THEN
    v_result := public.move_schedule_item(v_foreign_workspace, v_product, v_actor,
      '7b000000-0000-4000-8000-00000000001b', 'activity', v_activity_a, 2,
      v_discipline_a, v_stage_a, 0,
      jsonb_build_array(v_activity_a::text), jsonb_build_array(v_activity_a::text));
    IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
      RAISE EXCEPTION 'The cross-workspace movement was not denied.';
    END IF;
  ELSE
    v_result := public.move_schedule_item(gen_random_uuid(), v_product, v_actor,
      '7b000000-0000-4000-8000-00000000001b', 'activity', v_activity_a, 2,
      v_discipline_a, v_stage_a, 0,
      jsonb_build_array(v_activity_a::text), jsonb_build_array(v_activity_a::text));
    IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
      RAISE EXCEPTION 'A movement using an unknown workspace was accepted.';
    END IF;
  END IF;

  -- root-to-stage movement preserves dates, planning metadata, and explicit/null colors.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_root);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000000c', 'activity', v_root, 2,
    v_discipline_a, v_stage_b, 0, jsonb_build_array(v_root_b::text, v_root::text), '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT discipline_id IS DISTINCT FROM v_discipline_a OR stage_id IS DISTINCT FROM v_stage_b
        OR to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] IS DISTINCT FROM v_before
      FROM public.stage_activities AS a WHERE id = v_root) THEN
    RAISE EXCEPTION 'The root-to-stage movement changed protected activity data.';
  END IF;

  -- Move a stage activity between stages while preserving its source data.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_activity_b);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000017', 'activity', v_activity_b, 4,
    v_discipline_a, v_stage_b, 1,
    jsonb_build_array(v_activity_b::text, v_activity_a::text),
    jsonb_build_array(v_root::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT discipline_id IS DISTINCT FROM v_discipline_a OR stage_id IS DISTINCT FROM v_stage_b OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] IS DISTINCT FROM v_before
      FROM public.stage_activities AS a WHERE id = v_activity_b) THEN
    RAISE EXCEPTION 'The stage-to-stage activity movement changed protected activity data.';
  END IF;

  -- stage movement updates all descendant discipline references in the same transaction.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000000d', 'stage', v_stage_b, 2,
    v_discipline_b, NULL, 0,
    jsonb_build_array(v_stage_b::text, v_stage_a::text), '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT discipline_id FROM public.discipline_stages WHERE id = v_stage_b) IS DISTINCT FROM v_discipline_b OR
     (SELECT discipline_id FROM public.stage_activities WHERE id = v_root) IS DISTINCT FROM v_discipline_b OR
     (SELECT discipline_id FROM public.stage_activities WHERE id = v_activity_b) IS DISTINCT FROM v_discipline_b THEN
    RAISE EXCEPTION 'The stage movement did not update descendant discipline references.';
  END IF;
  SET CONSTRAINTS public.stage_activities_parent_fk IMMEDIATE;
  IF EXISTS (SELECT 1 FROM public.stage_activities AS a
    JOIN public.discipline_stages AS s ON s.id = a.stage_id
    WHERE a.product_id = v_product AND a.stage_id IS NOT NULL
      AND (a.discipline_id IS DISTINCT FROM s.discipline_id OR
           a.product_id IS DISTINCT FROM s.product_id OR
           a.workspace_id IS DISTINCT FROM s.workspace_id)) THEN
    RAISE EXCEPTION 'Stage move left invalid descendant ancestry.';
  END IF;

  -- Null overrides inherit the new stage color, then the product-root fallback.
  IF (SELECT COALESCE(activity.color_override, definition.color)
      FROM public.stage_activities AS activity
      JOIN public.discipline_stages AS stage ON stage.id = activity.stage_id
      JOIN public.stage_definitions AS definition ON definition.id = stage.definition_id
      WHERE activity.id = v_root) IS DISTINCT FROM '#445566' THEN
    RAISE EXCEPTION 'The null activity color did not inherit the destination stage color.';
  END IF;
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_root);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000001e', 'activity', v_root, 4,
    NULL, NULL, 1, jsonb_build_array(v_root::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT discipline_id IS NOT NULL OR stage_id IS NOT NULL OR color_override IS NOT NULL OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] IS DISTINCT FROM v_before
      FROM public.stage_activities AS a WHERE id = v_root) OR
     (SELECT COALESCE(color_override, '#8D9A89') FROM public.stage_activities WHERE id = v_root) IS DISTINCT FROM '#8D9A89' THEN
    RAISE EXCEPTION 'The null activity color did not retain product-root fallback after movement.';
  END IF;

  -- Move an explicitly overridden activity from its stage back to the product root.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_activity_b);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000018', 'activity', v_activity_b, 7,
    NULL, NULL, 2, jsonb_build_array(v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_root::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT discipline_id IS NOT NULL OR stage_id IS NOT NULL OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] IS DISTINCT FROM v_before
      FROM public.stage_activities AS a WHERE id = v_activity_b) THEN
    RAISE EXCEPTION 'The stage-to-root activity movement changed protected activity data.';
  END IF;

  -- Reorder the product-root activities after movement.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000019', 'activity', v_activity_b, 8,
    NULL, NULL, 0, jsonb_build_array(v_root_b::text, v_root::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_root::text, v_activity_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_b) IS DISTINCT FROM 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root_b) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The product-root reorder after movement failed.';
  END IF;

  -- discipline reorder
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000000e', 'discipline', v_discipline_b, 1,
    NULL, NULL, 0,
    jsonb_build_array(v_discipline_a::text, v_discipline_b::text),
    jsonb_build_array(v_discipline_a::text, v_discipline_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (SELECT display_order FROM public.product_disciplines WHERE id = v_discipline_b) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'The discipline reorder failed.';
  END IF;

  -- stale version
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-00000000000f', 'activity', v_activity_a, 1,
    v_discipline_a, v_stage_a, 0,
    jsonb_build_array(v_activity_a::text),
    jsonb_build_array(v_activity_a::text));
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'The stale version was accepted.'; END IF;

  -- sibling-order conflict
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000010', 'activity', v_root_b, 3,
    NULL, NULL, 0,
    jsonb_build_array(v_root_b::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_activity_b::text));
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'The sibling-order conflict was accepted.'; END IF;

  -- A correct source snapshot with a stale destination must also conflict.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000021', 'activity', v_root_b, 3,
    v_discipline_a, v_stage_a, 0,
    jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text), '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'The stale destination order was accepted.';
  END IF;
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000022', 'activity', v_root_b, 3,
    NULL, NULL, 3,
    jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text),
    jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text));
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Out-of-range destination index was accepted.';
  END IF;
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000023', 'target', v_root_b, 3,
    NULL, NULL, 0, '[]'::jsonb, '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Unsupported item kind was accepted.';
  END IF;
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000024', 'activity', v_root_b, 3,
    v_discipline_a, NULL, 0, '[]'::jsonb, '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Mixed NULL activity destination parents were accepted.';
  END IF;
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000025', 'stage', v_stage_a, 2,
    NULL, NULL, 0, '[]'::jsonb, '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Stage-to-root destination was accepted.';
  END IF;
  v_result := public.move_schedule_item(v_workspace, v_other_product, v_actor,
    '7b000000-0000-4000-8000-000000000026', 'activity', v_root_b, 3,
    NULL, NULL, 0, '[]'::jsonb, '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Cross-product item scope was accepted.';
  END IF;

  -- invalid destination and cross-product scope
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7b000000-0000-4000-8000-000000000012', 'activity', v_activity_a, 2,
    v_discipline_b, '7b000000-0000-4000-8000-ffffffffffff', 0,
    jsonb_build_array(v_activity_a::text), '[]'::jsonb);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'The invalid destination or cross-product scope was accepted.';
  END IF;

  -- viewer permission (or an identity with no membership when no viewer exists)
  v_result := public.move_schedule_item(v_workspace, v_product, v_denied_actor,
    '7b000000-0000-4000-8000-000000000011', 'discipline', v_discipline_a, 1,
    NULL, NULL, 1,
    jsonb_build_array(v_discipline_b::text, v_discipline_a::text),
    jsonb_build_array(v_discipline_b::text, v_discipline_a::text));
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'The viewer permission boundary failed.'; END IF;

  -- Direct ordering, ancestry, and audit writes are not granted to the Worker.
  BEGIN
    PERFORM 1 FROM public.hierarchy_movement_events LIMIT 1;
    RAISE EXCEPTION 'The Worker directly read movement audit history.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.product_disciplines SET display_order = 99 WHERE id = v_discipline_a;
    RAISE EXCEPTION 'The Worker directly changed discipline order.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.discipline_stages SET display_order = 99 WHERE id = v_stage_a;
    RAISE EXCEPTION 'The Worker directly changed stage order.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET display_order = 99 WHERE id = v_root_b;
    RAISE EXCEPTION 'The Worker directly changed activity order.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET discipline_id = v_discipline_a WHERE id = v_root_b;
    RAISE EXCEPTION 'The Worker directly changed activity ancestry.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.hierarchy_movement_events SET new_display_order = 99
      WHERE operation_id = v_first_operation;
    RAISE EXCEPTION 'The Worker directly changed movement audit history.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  IF (SELECT snapshot FROM public.initial_schedule_revisions WHERE product_id = v_product) IS DISTINCT FROM v_expected_r00 OR
     (SELECT target_date FROM public.business_targets WHERE id = v_target) IS DISTINCT FROM DATE '2026-11-10' THEN
    RAISE EXCEPTION 'Movement modified the synthetic R00 snapshot or milestone.';
  END IF;

  -- forced audit failure: duplicate operation ID must roll back all order updates.
  SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), ''))
    INTO v_atomic_before FROM (
      SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d WHERE product_id = v_product
      UNION ALL SELECT 's', id::text, to_jsonb(s)::text
        FROM public.discipline_stages AS s WHERE product_id = v_product
      UNION ALL SELECT 'a', id::text, to_jsonb(a)::text
        FROM public.stage_activities AS a WHERE product_id = v_product
    ) AS synthetic_rows;
  BEGIN
    PERFORM public.move_schedule_item(v_workspace, v_product, v_actor, v_first_operation,
      'activity', v_root_b, 3, NULL, NULL, 0,
      jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text),
      jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text));
    RAISE EXCEPTION 'The forced audit failure did not fail.';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;
  IF (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
      SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d WHERE product_id = v_product
      UNION ALL SELECT 's', id::text, to_jsonb(s)::text
        FROM public.discipline_stages AS s WHERE product_id = v_product
      UNION ALL SELECT 'a', id::text, to_jsonb(a)::text
        FROM public.stage_activities AS a WHERE product_id = v_product
    ) AS synthetic_rows) IS DISTINCT FROM v_atomic_before THEN
    RAISE EXCEPTION 'Duplicate movement ID left partial hierarchy changes.';
  END IF;
  IF (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
      'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
      '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a
      WHERE a.product_id = v_product) IS DISTINCT FROM v_dates_before OR
     (SELECT count(*) FROM public.activity_date_changes
       WHERE product_id = v_product) IS DISTINCT FROM v_date_audit_count_before OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE operation_id = '7b000000-0000-4000-8000-000000000015'
         AND activity_id = v_activity_b AND product_id = v_product
         AND discipline_id = v_discipline_a AND stage_id = v_stage_a) THEN
    RAISE EXCEPTION 'Movement changed dates or historical date-audit references.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stage_activities AS a
      LEFT JOIN public.discipline_stages AS s
        ON s.id = a.stage_id AND s.product_id = a.product_id
      WHERE a.product_id = v_product AND
        ((a.discipline_id IS NULL) IS DISTINCT FROM (a.stage_id IS NULL) OR
         (a.stage_id IS NOT NULL AND
           (s.id IS NULL OR s.discipline_id IS DISTINCT FROM a.discipline_id)))) OR
     (SELECT jsonb_agg(id::text ORDER BY display_order, id)
        FROM public.stage_activities WHERE product_id = v_product
          AND discipline_id IS NULL AND stage_id IS NULL)
        IS DISTINCT FROM jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text) OR
     (SELECT jsonb_agg(id::text ORDER BY display_order, id)
        FROM public.product_disciplines WHERE product_id = v_product)
        IS DISTINCT FROM jsonb_build_array(v_discipline_b::text, v_discipline_a::text) THEN
    RAISE EXCEPTION 'Final hierarchy relationships or sibling order differ.';
  END IF;
  IF (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
      SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d WHERE product_id IS DISTINCT FROM v_product
      UNION ALL SELECT 's', id::text, to_jsonb(s)::text
        FROM public.discipline_stages AS s WHERE product_id IS DISTINCT FROM v_product
      UNION ALL SELECT 'a', id::text, to_jsonb(a)::text
        FROM public.stage_activities AS a WHERE product_id IS DISTINCT FROM v_product
    ) AS original_rows) IS DISTINCT FROM v_original_hierarchy_before THEN
    RAISE EXCEPTION 'Original hierarchy records changed during synthetic movements.';
  END IF;
  RAISE NOTICE 'REL-03P movement, validation, permissions, dates, ancestry, and rollback-only atomicity passed.';
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
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'dates', (SELECT md5(COALESCE(string_agg(jsonb_build_object(
    'id', a.id, 'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a),
  'hierarchy', (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
    SELECT 'd' AS kind, id::text AS id, to_jsonb(d)::text AS row_data FROM public.product_disciplines AS d
    UNION ALL SELECT 's', id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
    UNION ALL SELECT 'a', id::text, to_jsonb(a)::text FROM public.stage_activities AS a
  ) AS rows),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r),
  'target_fingerprint', (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text,
    '|' ORDER BY t.id::text), '')) FROM public.business_targets AS t),
  'source_row_count', (SELECT count(*) FROM public.import_source_rows)
) AS after_rollback
\gset rel03p_
SELECT 1 / CASE WHEN
  :'rel03p_after_rollback'::jsonb = :'rel03p_baseline'::jsonb AND
  NOT EXISTS (SELECT 1 FROM public.products WHERE name LIKE 'REL03P synthetic %')
  THEN 1 ELSE 0 END AS full_accessible_baseline_preserved;
ROLLBACK;
