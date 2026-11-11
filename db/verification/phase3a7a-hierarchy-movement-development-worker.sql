-- Run as neondb_owner inside a rollback-only transaction, combining migration
-- 0026 and this synthetic verification when the migration is not yet installed.
-- The temporary SET ROLE options and all synthetic rows are rolled back.
BEGIN;

CREATE TEMP TABLE phase3a7a_existing_products AS
  SELECT id FROM public.products;
CREATE TEMP TABLE phase3a7a_before AS
SELECT
  (SELECT md5(COALESCE(string_agg(a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
    COALESCE(a.planned_end::text, '') || '|' || COALESCE(a.planning_mode, '') || '|' ||
    COALESCE(a.working_day_duration::text, '') || '|' || COALESCE(a.planning_calendar_version::text, ''),
    E'\n' ORDER BY a.id), '')) FROM public.stage_activities AS a
    JOIN phase3a7a_existing_products AS p ON p.id = a.product_id) AS planned_date_fingerprint,
  (SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
    E'\n' ORDER BY r.id), '')) FROM public.initial_schedule_revisions AS r
    JOIN phase3a7a_existing_products AS p ON p.id = r.product_id) AS r00_fingerprint,
  (SELECT md5(COALESCE(string_agg(t.id::text || '|' || t.target_date::text || '|' ||
    COALESCE(t.operational_date::text, ''), E'\n' ORDER BY t.id), ''))
    FROM public.business_targets AS t
    JOIN phase3a7a_existing_products AS p ON p.id = t.product_id) AS milestone_fingerprint,
  (SELECT count(*) FROM public.activity_date_changes AS audit
    JOIN phase3a7a_existing_products AS p ON p.id = audit.product_id) AS date_audit_count,
  (SELECT count(*) FROM public.import_source_rows) AS imported_row_count;

GRANT jlproject_worker TO neondb_owner
  WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_worker;

DO $$
DECLARE
  v_workspace uuid;
  v_foreign_workspace uuid;
  v_actor uuid;
  v_editor uuid;
  v_denied_actor uuid;
  v_calendar_version bigint;
  v_product constant uuid := '7a000000-0000-4000-8000-000000000001';
  v_discipline_a constant uuid := '7a000000-0000-4000-8000-000000000002';
  v_discipline_b constant uuid := '7a000000-0000-4000-8000-000000000003';
  v_definition_a constant uuid := '7a000000-0000-4000-8000-000000000004';
  v_definition_b constant uuid := '7a000000-0000-4000-8000-000000000005';
  v_stage_a constant uuid := '7a000000-0000-4000-8000-000000000006';
  v_stage_b constant uuid := '7a000000-0000-4000-8000-000000000007';
  v_activity_a uuid;
  v_activity_b uuid;
  v_root uuid;
  v_root_b uuid;
  v_target constant uuid := '7a000000-0000-4000-8000-000000000014';
  v_first_operation constant uuid := '7a000000-0000-4000-8000-00000000000b';
  v_result jsonb;
  v_before jsonb;
  v_expected_r00 jsonb := jsonb_build_object('dependencies', '[]'::jsonb, 'synthetic', true);
BEGIN
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

  INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
    VALUES (v_product, v_workspace, 'Phase 3A.7a synthetic rollback product', v_actor, v_actor);
  INSERT INTO public.product_disciplines
    (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES
    (v_discipline_a, v_workspace, v_product, 'Synthetic discipline A', '7A-A', '#112233', 0, v_actor, v_actor),
    (v_discipline_b, v_workspace, v_product, 'Synthetic discipline B', '7A-B', '#223344', 1, v_actor, v_actor);
  INSERT INTO public.stage_definitions (id, workspace_id, code, color) VALUES
    (v_definition_a, v_workspace, '7A-SA', '#334455'),
    (v_definition_b, v_workspace, '7A-SB', '#445566');
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
    v_activity_b, v_actor, '7a000000-0000-4000-8000-000000000015',
    DATE '2026-11-05', DATE '2026-11-06', 'Synthetic movement history check', 1);
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'The synthetic date audit setup failed.'; END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_version;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline_a, v_stage_a,
    v_activity_b, v_actor, '7a000000-0000-4000-8000-00000000001c', 'working_days',
    DATE '2026-11-05', DATE '2026-11-06', 2, v_calendar_version,
    'Synthetic movement duration metadata', 2);
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'The synthetic working-duration setup failed.'; END IF;

  -- Stage reorder within its current discipline.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000001d', 'stage', v_stage_b, 1,
    v_discipline_a, NULL, 0,
    jsonb_build_array(v_stage_a::text, v_stage_b::text),
    jsonb_build_array(v_stage_a::text, v_stage_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT display_order FROM public.discipline_stages WHERE id = v_stage_b) <> 0 OR
     (SELECT display_order FROM public.discipline_stages WHERE id = v_stage_a) <> 1 THEN
    RAISE EXCEPTION 'The stage reorder failed.';
  END IF;

  -- valid activity reorder
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor, v_first_operation,
    'activity', v_activity_b, 3, v_discipline_a, v_stage_a, 0,
    jsonb_build_array(v_activity_a::text, v_activity_b::text),
    jsonb_build_array(v_activity_a::text, v_activity_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_b) <> 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_a) <> 1 THEN
    RAISE EXCEPTION 'The valid activity reorder failed.';
  END IF;

  -- Product-root activity reorder.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000016', 'activity', v_root_b, 1,
    NULL, NULL, 0, jsonb_build_array(v_root::text, v_root_b::text),
    jsonb_build_array(v_root::text, v_root_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root_b) <> 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root) <> 1 THEN
    RAISE EXCEPTION 'The product-root activity reorder failed.';
  END IF;

  IF v_editor IS NOT NULL THEN
    v_result := public.move_schedule_item(v_workspace, v_product, v_editor,
      '7a000000-0000-4000-8000-00000000001a', 'activity', v_root_b, 2,
      NULL, NULL, 0, jsonb_build_array(v_root_b::text, v_root::text),
      jsonb_build_array(v_root_b::text, v_root::text));
    IF v_result->>'status' <> 'unchanged' THEN RAISE EXCEPTION 'The editor movement authorization failed.'; END IF;
  END IF;

  -- A workspace outside the actor's membership cannot accept this move.
  SELECT workspace.id INTO v_foreign_workspace FROM public.workspaces AS workspace
  WHERE workspace.id <> v_workspace AND NOT EXISTS (
    SELECT 1 FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = workspace.id AND membership.auth_user_id = v_actor
      AND membership.active = true
  ) ORDER BY workspace.id LIMIT 1;
  IF v_foreign_workspace IS NOT NULL THEN
    v_result := public.move_schedule_item(v_foreign_workspace, v_product, v_actor,
      '7a000000-0000-4000-8000-00000000001b', 'activity', v_activity_a, 2,
      v_discipline_a, v_stage_a, 0,
      jsonb_build_array(v_activity_a::text), jsonb_build_array(v_activity_a::text));
    IF v_result->>'status' <> 'forbidden' THEN
      RAISE EXCEPTION 'The cross-workspace movement was not denied.';
    END IF;
  ELSE
    v_result := public.move_schedule_item(gen_random_uuid(), v_product, v_actor,
      '7a000000-0000-4000-8000-00000000001b', 'activity', v_activity_a, 2,
      v_discipline_a, v_stage_a, 0,
      jsonb_build_array(v_activity_a::text), jsonb_build_array(v_activity_a::text));
    IF v_result->>'status' <> 'not_found' THEN
      RAISE EXCEPTION 'A movement using an unknown workspace was accepted.';
    END IF;
  END IF;

  -- root-to-stage movement preserves dates, planning metadata, and explicit/null colors.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_root);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000000c', 'activity', v_root, 2,
    v_discipline_a, v_stage_b, 0, jsonb_build_array(v_root_b::text, v_root::text), '[]'::jsonb);
  IF v_result->>'status' <> 'moved' OR
     (SELECT discipline_id <> v_discipline_a OR stage_id <> v_stage_b
        OR to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] <> v_before
      FROM public.stage_activities AS a WHERE id = v_root) THEN
    RAISE EXCEPTION 'The root-to-stage movement changed protected activity data.';
  END IF;

  -- Move a stage activity between stages while preserving its source data.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_activity_b);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000017', 'activity', v_activity_b, 4,
    v_discipline_a, v_stage_b, 1,
    jsonb_build_array(v_activity_b::text, v_activity_a::text),
    jsonb_build_array(v_root::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT discipline_id <> v_discipline_a OR stage_id <> v_stage_b OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] <> v_before
      FROM public.stage_activities AS a WHERE id = v_activity_b) THEN
    RAISE EXCEPTION 'The stage-to-stage activity movement changed protected activity data.';
  END IF;

  -- stage movement updates all descendant discipline references in the same transaction.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000000d', 'stage', v_stage_b, 2,
    v_discipline_b, NULL, 0,
    jsonb_build_array(v_stage_b::text, v_stage_a::text), '[]'::jsonb);
  IF v_result->>'status' <> 'moved' OR
     (SELECT discipline_id FROM public.discipline_stages WHERE id = v_stage_b) <> v_discipline_b OR
     (SELECT discipline_id FROM public.stage_activities WHERE id = v_root) <> v_discipline_b OR
     (SELECT discipline_id FROM public.stage_activities WHERE id = v_activity_b) <> v_discipline_b THEN
    RAISE EXCEPTION 'The stage movement did not update descendant discipline references.';
  END IF;

  -- Null overrides inherit the new stage color, then the product-root fallback.
  IF (SELECT COALESCE(activity.color_override, definition.color)
      FROM public.stage_activities AS activity
      JOIN public.discipline_stages AS stage ON stage.id = activity.stage_id
      JOIN public.stage_definitions AS definition ON definition.id = stage.definition_id
      WHERE activity.id = v_root) <> '#445566' THEN
    RAISE EXCEPTION 'The null activity color did not inherit the destination stage color.';
  END IF;
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_root);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000001e', 'activity', v_root, 4,
    NULL, NULL, 1, jsonb_build_array(v_root::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT discipline_id IS NOT NULL OR stage_id IS NOT NULL OR color_override IS NOT NULL OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] <> v_before
      FROM public.stage_activities AS a WHERE id = v_root) OR
     (SELECT COALESCE(color_override, '#8D9A89') FROM public.stage_activities WHERE id = v_root) <> '#8D9A89' THEN
    RAISE EXCEPTION 'The null activity color did not retain product-root fallback after movement.';
  END IF;

  -- Move an explicitly overridden activity from its stage back to the product root.
  v_before := (SELECT to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at']
    FROM public.stage_activities AS a WHERE id = v_activity_b);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000018', 'activity', v_activity_b, 7,
    NULL, NULL, 2, jsonb_build_array(v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_root::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT discipline_id IS NOT NULL OR stage_id IS NOT NULL OR
        to_jsonb(a) - ARRAY['discipline_id','stage_id','display_order','version','updated_by','updated_at'] <> v_before
      FROM public.stage_activities AS a WHERE id = v_activity_b) THEN
    RAISE EXCEPTION 'The stage-to-root activity movement changed protected activity data.';
  END IF;

  -- Reorder the product-root activities after movement.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000019', 'activity', v_activity_b, 8,
    NULL, NULL, 0, jsonb_build_array(v_root_b::text, v_root::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_root::text, v_activity_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_activity_b) <> 0 OR
     (SELECT display_order FROM public.stage_activities WHERE id = v_root_b) <> 1 THEN
    RAISE EXCEPTION 'The product-root reorder after movement failed.';
  END IF;

  -- discipline reorder
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000000e', 'discipline', v_discipline_b, 1,
    NULL, NULL, 0,
    jsonb_build_array(v_discipline_a::text, v_discipline_b::text),
    jsonb_build_array(v_discipline_a::text, v_discipline_b::text));
  IF v_result->>'status' <> 'moved' OR
     (SELECT display_order FROM public.product_disciplines WHERE id = v_discipline_b) <> 0 THEN
    RAISE EXCEPTION 'The discipline reorder failed.';
  END IF;

  -- stale version
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-00000000000f', 'activity', v_activity_a, 1,
    v_discipline_a, v_stage_a, 0,
    jsonb_build_array(v_activity_a::text),
    jsonb_build_array(v_activity_a::text));
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'The stale version was accepted.'; END IF;

  -- sibling-order conflict
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000010', 'activity', v_root_b, 3,
    NULL, NULL, 0,
    jsonb_build_array(v_root_b::text, v_activity_b::text),
    jsonb_build_array(v_root_b::text, v_activity_b::text));
  IF v_result->>'status' <> 'conflict' THEN RAISE EXCEPTION 'The sibling-order conflict was accepted.'; END IF;

  -- invalid destination and cross-product scope
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7a000000-0000-4000-8000-000000000012', 'activity', v_activity_a, 2,
    v_discipline_b, '7a000000-0000-4000-8000-ffffffffffff', 0,
    jsonb_build_array(v_activity_a::text), '[]'::jsonb);
  IF v_result->>'status' <> 'not_found' THEN
    RAISE EXCEPTION 'The invalid destination or cross-product scope was accepted.';
  END IF;

  -- viewer permission (or an identity with no membership when no viewer exists)
  v_result := public.move_schedule_item(v_workspace, v_product, v_denied_actor,
    '7a000000-0000-4000-8000-000000000011', 'discipline', v_discipline_a, 1,
    NULL, NULL, 1,
    jsonb_build_array(v_discipline_b::text, v_discipline_a::text),
    jsonb_build_array(v_discipline_b::text, v_discipline_a::text));
  IF v_result->>'status' <> 'forbidden' THEN RAISE EXCEPTION 'The viewer permission boundary failed.'; END IF;

  -- Direct ordering, ancestry, and audit writes are not granted to the Worker.
  BEGIN
    PERFORM 1 FROM public.hierarchy_movement_events LIMIT 1;
    RAISE EXCEPTION 'The Worker directly read movement audit history.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.product_disciplines SET display_order = 99 WHERE id = v_discipline_a;
    RAISE EXCEPTION 'The Worker directly changed discipline order.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.discipline_stages SET display_order = 99 WHERE id = v_stage_a;
    RAISE EXCEPTION 'The Worker directly changed stage order.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET display_order = 99 WHERE id = v_root_b;
    RAISE EXCEPTION 'The Worker directly changed activity order.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET discipline_id = v_discipline_a WHERE id = v_root_b;
    RAISE EXCEPTION 'The Worker directly changed activity ancestry.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.hierarchy_movement_events SET new_display_order = 99
      WHERE operation_id = v_first_operation;
    RAISE EXCEPTION 'The Worker directly changed movement audit history.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF (SELECT snapshot FROM public.initial_schedule_revisions WHERE product_id = v_product) <> v_expected_r00 OR
     (SELECT target_date FROM public.business_targets WHERE id = v_target) <> DATE '2026-11-10' THEN
    RAISE EXCEPTION 'Movement modified the synthetic R00 snapshot or milestone.';
  END IF;

  -- forced audit failure: duplicate operation ID must roll back all order updates.
  v_before := (SELECT jsonb_agg(jsonb_build_object('id', id, 'order', display_order, 'version', version)
    ORDER BY display_order, id) FROM public.stage_activities
    WHERE product_id = v_product AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL);
  BEGIN
    PERFORM public.move_schedule_item(v_workspace, v_product, v_actor, v_first_operation,
      'activity', v_root_b, 3, NULL, NULL, 0,
      jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text),
      jsonb_build_array(v_activity_b::text, v_root_b::text, v_root::text));
    RAISE EXCEPTION 'The forced audit failure did not fail.';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  IF (SELECT jsonb_agg(jsonb_build_object('id', id, 'order', display_order, 'version', version)
      ORDER BY display_order, id) FROM public.stage_activities
      WHERE product_id = v_product AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL) <> v_before THEN
    RAISE EXCEPTION 'The forced audit failure left partial ordering changes.';
  END IF;
END;
$$;

RESET ROLE;
REVOKE jlproject_worker FROM neondb_owner GRANTED BY neondb_owner;

GRANT jlproject_date_executor TO neondb_owner
  WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;

DO $$
DECLARE
  v_event public.hierarchy_movement_events%ROWTYPE;
  v_stage_event public.hierarchy_movement_events%ROWTYPE;
  v_date_event public.activity_date_changes%ROWTYPE;
  v_history_page jsonb;
  v_history_events jsonb := '[]'::jsonb;
  v_history_cursor jsonb;
  v_history_event jsonb;
  v_history_stage_event jsonb;
  v_history_activity_id uuid;
  v_history_actor uuid;
  v_history_workspace uuid;
  v_cursor_at timestamptz;
  v_cursor_id text;
  v_movement_count bigint;
  v_history_movement_count bigint;
  v_duplicate_count bigint;
  v_isolated_result jsonb;
BEGIN
  SELECT * INTO v_event FROM public.hierarchy_movement_events
    WHERE operation_id = '7a000000-0000-4000-8000-00000000000b';
  IF v_event.operation_id IS NULL OR v_event.item_kind <> 'activity' OR
     v_event.item_id IS DISTINCT FROM (SELECT id FROM public.stage_activities
       WHERE product_id = '7a000000-0000-4000-8000-000000000001' AND name = 'Synthetic activity B') OR
     v_event.actor_id <> (SELECT created_by FROM public.products
       WHERE id = '7a000000-0000-4000-8000-000000000001') OR
     v_event.original_discipline_id <> '7a000000-0000-4000-8000-000000000002' OR
     v_event.original_stage_id <> '7a000000-0000-4000-8000-000000000006' OR
     v_event.new_discipline_id <> v_event.original_discipline_id OR
     v_event.new_stage_id <> v_event.original_stage_id OR
     v_event.original_display_order <> 1 OR v_event.new_display_order <> 0 OR
     v_event.version_before <> 3 OR v_event.version_after <> 4 OR
     v_event.changed_at IS NULL OR
     jsonb_array_length(v_event.source_order_before) <> 2 OR
     jsonb_array_length(v_event.source_order_after) <> 2 OR
     jsonb_array_length(v_event.destination_order_before) <> 2 OR
     jsonb_array_length(v_event.destination_order_after) <> 2 THEN
    RAISE EXCEPTION 'The immutable movement audit lacks actor, parent, version, or ordering information.';
  END IF;
  SELECT * INTO v_stage_event FROM public.hierarchy_movement_events
    WHERE operation_id = '7a000000-0000-4000-8000-00000000000d';
  IF v_stage_event.item_kind <> 'stage' OR
     v_stage_event.original_discipline_id <> '7a000000-0000-4000-8000-000000000002' OR
     v_stage_event.new_discipline_id <> '7a000000-0000-4000-8000-000000000003' OR
     NOT (v_stage_event.descendant_activity_ids ? (SELECT id::text FROM public.stage_activities
       WHERE product_id = '7a000000-0000-4000-8000-000000000001' AND name = 'Synthetic activity B')) OR
     NOT (v_stage_event.descendant_activity_ids ? (SELECT id::text FROM public.stage_activities
       WHERE product_id = '7a000000-0000-4000-8000-000000000001' AND name = 'Synthetic root activity A')) THEN
    RAISE EXCEPTION 'The stage movement audit lacks new parent or descendant IDs.';
  END IF;
  SELECT * INTO v_date_event FROM public.activity_date_changes
    WHERE operation_id = '7a000000-0000-4000-8000-000000000015';
  IF v_date_event.activity_id IS DISTINCT FROM (SELECT id FROM public.stage_activities
       WHERE product_id = '7a000000-0000-4000-8000-000000000001' AND name = 'Synthetic activity B') OR
     v_date_event.discipline_id <> '7a000000-0000-4000-8000-000000000002' OR
     v_date_event.stage_id <> '7a000000-0000-4000-8000-000000000006' OR
     (SELECT discipline_id IS NOT NULL OR stage_id IS NOT NULL FROM public.stage_activities
       WHERE id = v_date_event.activity_id) THEN
    RAISE EXCEPTION 'Historical date audit parent scope changed after activity movement.';
  END IF;

  SELECT workspace_id, created_by INTO v_history_workspace, v_history_actor
  FROM public.products WHERE id = '7a000000-0000-4000-8000-000000000001';
  v_cursor_at := NULL;
  v_cursor_id := NULL;
  LOOP
    v_history_page := public.list_product_change_history(v_history_workspace,
      '7a000000-0000-4000-8000-000000000001', v_history_actor, 2, v_cursor_at, v_cursor_id);
    IF v_history_page->>'status' <> 'ok' OR jsonb_typeof(v_history_page->'events') <> 'array' THEN
      RAISE EXCEPTION 'The synthetic product history page was not authorized or valid.';
    END IF;
    v_history_events := v_history_events || (v_history_page->'events');
    v_history_cursor := v_history_page->'nextCursor';
    EXIT WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb;
    v_cursor_at := (v_history_cursor->>'occurredAt')::timestamptz;
    v_cursor_id := v_history_cursor->>'eventId';
  END LOOP;

  SELECT count(*), count(DISTINCT event->>'id') INTO v_history_movement_count, v_duplicate_count
  FROM jsonb_array_elements(v_history_events) AS page_event(event)
  WHERE event->>'eventType' = 'hierarchy_moved';
  SELECT count(*) INTO v_movement_count FROM public.hierarchy_movement_events
  WHERE workspace_id = v_history_workspace AND product_id = '7a000000-0000-4000-8000-000000000001';
  IF v_history_movement_count <> v_movement_count OR v_duplicate_count <> v_history_movement_count OR
     jsonb_array_length(v_history_events) < 3 THEN
    RAISE EXCEPTION 'Movement history omitted, duplicated, or failed keyset pagination.';
  END IF;

  SELECT id INTO v_history_activity_id FROM public.stage_activities
  WHERE product_id = '7a000000-0000-4000-8000-000000000001' AND name = 'Synthetic activity B';
  SELECT event INTO v_history_event FROM jsonb_array_elements(v_history_events) AS page_event(event)
  WHERE event->>'id' = 'hierarchy-movement:7a000000-0000-4000-8000-00000000000b';
  IF v_history_event->>'actorId' <> v_event.actor_id::text OR
     (v_history_event->>'occurredAt')::timestamptz <> v_event.changed_at OR
     v_history_event#>>'{item,kind}' <> 'activity' OR
     v_history_event#>>'{item,id}' <> v_event.item_id::text OR
     v_history_event#>>'{item,name}' <> 'Synthetic activity B' OR
     v_history_event#>>'{before,parent,scope}' <> 'stage' OR
     v_history_event#>>'{before,parent,discipline}' <> 'Synthetic discipline A' OR
     v_history_event#>>'{before,parent,stage}' <> 'Synthetic stage A' OR
     (v_history_event#>>'{before,position}')::integer <> 2 OR
     v_history_event#>>'{after,parent,stage}' <> 'Synthetic stage A' OR
     (v_history_event#>>'{after,position}')::integer <> 1 THEN
    RAISE EXCEPTION 'Activity movement history did not preserve actor, time, item, parent, or positions.';
  END IF;

  SELECT event INTO v_history_stage_event FROM jsonb_array_elements(v_history_events) AS page_event(event)
  WHERE event->>'id' = 'hierarchy-movement:7a000000-0000-4000-8000-00000000000d';
  IF v_history_stage_event#>>'{before,parent,discipline}' <> 'Synthetic discipline A' OR
     v_history_stage_event#>>'{after,parent,discipline}' <> 'Synthetic discipline B' OR
     v_history_stage_event#>>'{before,parent,scope}' <> 'discipline' OR
     v_history_stage_event#>>'{after,parent,scope}' <> 'discipline' OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_history_stage_event->'affectedItems') AS affected(item)
       WHERE item->>'id' = v_history_activity_id::text
         AND item#>>'{hierarchy,scope}' = 'product_root') THEN
    RAISE EXCEPTION 'Stage movement history omitted a descendant later moved to the product root.';
  END IF;

  v_isolated_result := public.list_product_change_history(gen_random_uuid(),
    '7a000000-0000-4000-8000-000000000001', v_history_actor, 10, NULL, NULL);
  IF v_isolated_result->>'status' <> 'forbidden' OR
     jsonb_array_length(COALESCE(v_isolated_result->'events', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'Product history was visible outside its active workspace.';
  END IF;
  BEGIN
    UPDATE public.hierarchy_movement_events SET new_display_order = 99
      WHERE operation_id = v_event.operation_id;
    RAISE EXCEPTION 'The immutable movement audit accepted an update.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END;
$$;

RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
DECLARE v_before phase3a7a_before%ROWTYPE; v_after phase3a7a_before%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM phase3a7a_before;
  SELECT
    (SELECT md5(COALESCE(string_agg(a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
      COALESCE(a.planned_end::text, '') || '|' || COALESCE(a.planning_mode, '') || '|' ||
      COALESCE(a.working_day_duration::text, '') || '|' || COALESCE(a.planning_calendar_version::text, ''),
      E'\n' ORDER BY a.id), '')) FROM public.stage_activities AS a
      JOIN phase3a7a_existing_products AS p ON p.id = a.product_id),
    (SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
      E'\n' ORDER BY r.id), '')) FROM public.initial_schedule_revisions AS r
      JOIN phase3a7a_existing_products AS p ON p.id = r.product_id),
    (SELECT md5(COALESCE(string_agg(t.id::text || '|' || t.target_date::text || '|' ||
      COALESCE(t.operational_date::text, ''), E'\n' ORDER BY t.id), ''))
      FROM public.business_targets AS t JOIN phase3a7a_existing_products AS p ON p.id = t.product_id),
    (SELECT count(*) FROM public.activity_date_changes AS audit
      JOIN phase3a7a_existing_products AS p ON p.id = audit.product_id),
    (SELECT count(*) FROM public.import_source_rows)
  INTO v_after;
  IF v_before IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'Existing planned date fingerprint, R00 fingerprint, milestones, audit, or imported data changed.';
  END IF;
END;
$$;

DO $$
DECLARE
  v_worker_count bigint;
  v_worker_options boolean;
  v_executor_count bigint;
  v_executor_options boolean;
BEGIN
  SELECT count(*), bool_and(membership.admin_option AND
      NOT membership.inherit_option AND NOT membership.set_option)
    INTO v_worker_count, v_worker_options
    FROM pg_auth_members AS membership
    JOIN pg_roles AS granted ON granted.oid = membership.roleid
    JOIN pg_roles AS member ON member.oid = membership.member
    WHERE granted.rolname = 'jlproject_worker' AND member.rolname = 'neondb_owner';
  SELECT count(*), bool_and(membership.admin_option AND
      NOT membership.inherit_option AND NOT membership.set_option)
    INTO v_executor_count, v_executor_options
    FROM pg_auth_members AS membership
    JOIN pg_roles AS granted ON granted.oid = membership.roleid
    JOIN pg_roles AS member ON member.oid = membership.member
    WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner';
  IF v_worker_count <> 1 OR v_worker_options IS DISTINCT FROM true OR
     v_executor_count <> 1 OR v_executor_options IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Temporary role options were not restored before rollback.';
  END IF;
END;
$$;

ROLLBACK;
