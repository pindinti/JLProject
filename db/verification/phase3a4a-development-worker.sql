-- Run with jlproject_worker on the verified JLProject development branch only.
-- Every synthetic row and audit event is rolled back.
BEGIN;

DO $$
DECLARE
  v_ws uuid;
  v_actor uuid;
  v_product uuid;
  v_other uuid;
  v_discipline uuid;
  v_stage uuid;
  v_stage2 uuid;
  v_definition uuid;
  v_definition2 uuid;
  v_target uuid;
  v_clone jsonb;
  v_clone_id uuid;
  v_activity uuid;
  v_activity2 uuid;
  v_operation uuid := gen_random_uuid();
  v_preview jsonb;
  v_result jsonb;
  v_snapshot_hash text;
  v_rejected boolean;
BEGIN
  IF current_user <> 'jlproject_worker' OR current_database() <> 'neondb' OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'INSERT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'deleted_at', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Limited role or audit privileges are unexpected.';
  END IF;
  SELECT m.workspace_id, m.auth_user_id INTO v_ws, v_actor
    FROM public.workspace_memberships AS m JOIN public.workspaces AS w ON w.id = m.workspace_id
    WHERE w.name = 'JLProject' AND m.active = true AND m.role IN ('admin', 'editor')
    ORDER BY (m.role = 'admin') DESC LIMIT 1;
  IF v_ws IS NULL THEN RAISE EXCEPTION 'No synthetic test actor is available.'; END IF;
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_ws, 'Synthetic deletion ' || gen_random_uuid()::text, v_actor, v_actor)
    RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_ws, v_product, 'Synthetic discipline', 'SYN', '#336699', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
    VALUES (v_ws, substr(gen_random_uuid()::text, 1, 12), '#557799') RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
    VALUES (v_ws, v_product, v_discipline, v_definition, 'Synthetic stage', 0, v_actor, v_actor)
    RETURNING id INTO v_stage;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, display_order,
     planned_start, planned_end, created_by, updated_by)
    VALUES (v_ws, v_product, v_discipline, v_stage, 'Synthetic activity one', 0,
      DATE '2026-11-10', DATE '2026-11-11', v_actor, v_actor)
    RETURNING id INTO v_activity;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, display_order,
     planned_start, planned_end, created_by, updated_by)
    VALUES (v_ws, v_product, v_discipline, v_stage, 'Synthetic activity two', 1,
      DATE '2026-11-12', DATE '2026-11-13', v_actor, v_actor)
    RETURNING id INTO v_activity2;
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
    VALUES (v_ws, v_product, NULL, '{"dependencies":[]}'::jsonb, v_actor);
  INSERT INTO public.business_targets
    (workspace_id, product_id, name, color, target_date, display_order, created_by)
    VALUES (v_ws, v_product, 'Synthetic target', '#AA5577', DATE '2026-11-15', 0, v_actor)
    RETURNING id INTO v_target;
  SELECT md5(snapshot::text) INTO v_snapshot_hash FROM public.initial_schedule_revisions
    WHERE product_id = v_product;

  v_preview := public.preview_schedule_deletion(v_ws, v_product, v_actor, 'activity', v_activity);
  IF v_preview->>'status' <> 'ok' OR (v_preview->'counts'->>'activities')::integer <> 1 THEN
    RAISE EXCEPTION 'Activity impact preview failed.'; END IF;
  UPDATE public.stage_activities SET name = 'Synthetic activity renamed', version = version + 1
    WHERE id = v_activity;
  v_result := public.delete_schedule_subtree(v_ws, v_product, v_actor, gen_random_uuid(),
    'activity', v_activity, v_preview->>'fingerprint', 'Synthetic stale deletion check');
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'Stale preview was accepted.'; END IF;
  v_preview := public.preview_schedule_deletion(v_ws, v_product, v_actor, 'activity', v_activity);
  v_result := public.delete_schedule_subtree(v_ws, v_product, v_actor, v_operation,
    'activity', v_activity, v_preview->>'fingerprint', 'Synthetic activity deletion');
  IF v_result->>'status' <> 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_activity AND deleted_at IS NOT NULL
      AND deletion_operation_id = v_operation) THEN
    RAISE EXCEPTION 'Activity logical deletion failed.'; END IF;

  v_preview := public.preview_schedule_deletion(v_ws, v_product, v_actor, 'stage', v_stage);
  IF (v_preview->'counts'->>'activities')::integer <> 1 OR
     (v_preview->'counts'->>'stages')::integer <> 1 THEN
    RAISE EXCEPTION 'Stage impact scope is incorrect.'; END IF;
  v_result := public.delete_schedule_subtree(v_ws, v_product, v_actor, gen_random_uuid(),
    'stage', v_stage, v_preview->>'fingerprint', 'Synthetic stage deletion');
  IF v_result->>'status' <> 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_activity2 AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Stage subtree deletion failed.'; END IF;
  v_result := public.delete_schedule_subtree(v_ws, v_product, v_actor, gen_random_uuid(),
    'stage', v_stage, v_preview->>'fingerprint', 'Synthetic repeated deletion');
  IF v_result->>'status' <> 'not_found' THEN RAISE EXCEPTION 'Repeated deletion was accepted.'; END IF;

  INSERT INTO public.stage_definitions (workspace_id, code, color)
    VALUES (v_ws, substr(gen_random_uuid()::text, 1, 12), '#779955') RETURNING id INTO v_definition2;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
    VALUES (v_ws, v_product, v_discipline, v_definition2, 'Synthetic second stage', 1, v_actor, v_actor)
    RETURNING id INTO v_stage2;
  v_preview := public.preview_schedule_deletion(v_ws, v_product, v_actor, 'discipline', v_discipline);
  IF (v_preview->'counts'->>'stages')::integer <> 1 OR
     (v_preview->'counts'->>'disciplines')::integer <> 1 THEN
    RAISE EXCEPTION 'Discipline impact scope is incorrect.'; END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.delete_schedule_subtree(v_ws, v_product, v_actor, v_operation,
      'discipline', v_discipline, v_preview->>'fingerprint', 'Synthetic audit collision');
  EXCEPTION WHEN unique_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected OR NOT EXISTS (
    SELECT 1 FROM public.discipline_stages WHERE id = v_stage2 AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Failed deletion was not atomic.'; END IF;
  v_result := public.delete_schedule_subtree(v_ws, v_product, v_actor, gen_random_uuid(),
    'discipline', v_discipline, v_preview->>'fingerprint', 'Synthetic discipline deletion');
  IF v_result->>'status' <> 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.discipline_stages WHERE id = v_stage2 AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Discipline subtree deletion failed.'; END IF;
  IF EXISTS (SELECT 1 FROM public.product_disciplines WHERE product_id = v_product AND deleted_at IS NULL) OR
     EXISTS (SELECT 1 FROM public.discipline_stages WHERE product_id = v_product AND deleted_at IS NULL) OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_product AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Deleted hierarchy remains active.'; END IF;
  IF (SELECT md5(snapshot::text) FROM public.initial_schedule_revisions WHERE product_id = v_product)
      <> v_snapshot_hash THEN RAISE EXCEPTION 'Synthetic R00 changed.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_targets WHERE id = v_target AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Unrelated target changed.'; END IF;
  v_clone := public.clone_product(v_ws, v_product, v_actor,
    'Synthetic surviving clone ' || gen_random_uuid()::text);
  IF v_clone->>'status' <> 'cloned' THEN RAISE EXCEPTION 'Synthetic clone failed.'; END IF;
  v_clone_id := (v_clone->'product'->>'id')::uuid;
  IF EXISTS (SELECT 1 FROM public.product_disciplines WHERE product_id = v_clone_id) OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE product_id = v_clone_id) THEN
    RAISE EXCEPTION 'Clone copied deleted hierarchy or missed independent R00.'; END IF;
  IF (SELECT count(DISTINCT operation_id) FROM (
    SELECT deletion_operation_id AS operation_id FROM public.product_disciplines WHERE product_id = v_product
    UNION ALL SELECT deletion_operation_id FROM public.discipline_stages WHERE product_id = v_product
    UNION ALL SELECT deletion_operation_id FROM public.stage_activities WHERE product_id = v_product
  ) AS affected) <> 3 THEN
    RAISE EXCEPTION 'Expected three linked deletion operations.'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.stage_activities SET deleted_at = NULL WHERE id = v_activity;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Direct resurrection was allowed.'; END IF;
  v_rejected := false;
  BEGIN
    DELETE FROM public.stage_activities WHERE id = v_activity;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Physical deletion was allowed.'; END IF;
  v_rejected := false;
  BEGIN
    UPDATE public.schedule_deletion_events SET reason = 'Synthetic audit forgery' WHERE operation_id = v_operation;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Audit mutation was allowed.'; END IF;
  v_other := gen_random_uuid();
  IF (public.preview_schedule_deletion(v_other, v_product, v_actor, 'discipline', v_discipline)->>'status')
    <> 'forbidden' THEN RAISE EXCEPTION 'Cross-workspace preview was allowed.'; END IF;
  IF (public.delete_schedule_subtree(v_other, v_product, v_actor, gen_random_uuid(),
    'discipline', v_discipline, repeat('0', 32), 'Synthetic isolation check')->>'status')
    <> 'forbidden' THEN RAISE EXCEPTION 'Cross-workspace deletion was allowed.'; END IF;
  RAISE NOTICE 'Synthetic logical deletion checks passed; outer transaction will roll back.';
END;
$$;

ROLLBACK;
