BEGIN;

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_activity uuid;
  v_batch uuid;
  v_revision uuid;
  v_operation uuid := gen_random_uuid();
  v_result jsonb;
  v_count integer;
BEGIN
  SELECT workspace.id, membership.auth_user_id INTO v_workspace, v_actor
    FROM public.workspaces AS workspace
    JOIN public.workspace_memberships AS membership ON membership.workspace_id = workspace.id
    WHERE workspace.name = 'JLProject' AND membership.active = true AND membership.role = 'admin'
    ORDER BY membership.created_at LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Synthetic verification requires an active development administrator.';
  END IF;
  IF pg_has_role(current_user, 'jlproject_date_executor', 'usage') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'set') THEN
    RAISE EXCEPTION 'The application role must not use the date executor role.';
  END IF;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, 'Synthetic date audit ' || gen_random_uuid()::text, v_actor, v_actor)
    RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, 'Synthetic discipline', 'AUD', '#336699', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
    VALUES (v_workspace, 'A' || left(replace(v_product::text, '-', ''), 12), '#336699');
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
    SELECT v_workspace, v_product, v_discipline, definition.id, 'Synthetic stage', 0, v_actor, v_actor
      FROM public.stage_definitions AS definition
      WHERE definition.workspace_id = v_workspace
        AND definition.code = 'A' || left(replace(v_product::text, '-', ''), 12)
    RETURNING id INTO v_stage;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
      display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_stage, 'Synthetic activity',
      DATE '2026-11-01', DATE '2026-11-05', 0, v_actor, v_actor)
    RETURNING id INTO v_activity;

  INSERT INTO public.import_batches
    (workspace_id, product_id, idempotency_key, source_hash, request_hash, source_filename, created_by)
    VALUES (v_workspace, v_product, gen_random_uuid(),
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
      'synthetic-only.xlsx', v_actor)
    RETURNING id INTO v_batch;
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
    VALUES (v_workspace, v_product, v_batch,
      jsonb_build_object('dependencies', '[]'::jsonb,
        'activity', jsonb_build_object('id', v_activity, 'plannedStart', '2026-11-01')),
      v_actor)
    RETURNING id INTO v_revision;

  BEGIN
    UPDATE public.stage_activities SET planned_start = DATE '2026-11-02' WHERE id = v_activity;
    RAISE EXCEPTION 'Direct date update was accepted.';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;

  PERFORM set_config('jlproject.date_operation_id', gen_random_uuid()::text, true);
  PERFORM set_config('jlproject.date_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.date_change_reason', 'Forged context attempt', true);
  BEGIN
    UPDATE public.stage_activities SET planned_start = DATE '2026-11-02',
      version = version + 1, updated_by = v_actor WHERE id = v_activity;
    RAISE EXCEPTION 'Forged audit context was accepted.';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;

  SELECT public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_activity, v_actor, v_operation, DATE '2026-11-02', DATE '2026-11-06',
    'Synthetic approved date correction', 1) INTO v_result;
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'Audited update failed.'; END IF;
  SELECT count(*) INTO v_count FROM public.activity_date_changes WHERE activity_id = v_activity;
  IF v_count <> 1 THEN RAISE EXCEPTION 'Expected one audit event.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.activity_date_changes
      WHERE operation_id = v_operation AND actor_id = v_actor
        AND previous_start = DATE '2026-11-01' AND previous_end = DATE '2026-11-05'
        AND new_start = DATE '2026-11-02' AND new_end = DATE '2026-11-06'
        AND version_before = 1 AND version_after = 2) THEN
    RAISE EXCEPTION 'Audit before/after values are incorrect.';
  END IF;
  BEGIN
    INSERT INTO public.activity_date_changes (operation_id, workspace_id, product_id,
      discipline_id, stage_id, activity_id, actor_id, previous_start, previous_end,
      new_start, new_end, reason, version_before, version_after)
    VALUES (gen_random_uuid(), v_workspace, v_product, v_discipline, v_stage, v_activity,
      v_actor, DATE '2026-11-01', DATE '2026-11-05', DATE '2026-11-02', DATE '2026-11-06',
      'Forged audit insertion', 1, 2);
    RAISE EXCEPTION 'Direct audit insertion was accepted.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  SELECT public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_activity, v_actor, gen_random_uuid(), DATE '2026-11-02', DATE '2026-11-06', NULL, 2)
    INTO v_result;
  IF v_result->>'status' <> 'unchanged' THEN RAISE EXCEPTION 'No-op was not recognized.'; END IF;
  SELECT public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_activity, v_actor, gen_random_uuid(), DATE '2026-11-03', DATE '2026-11-07',
    'Synthetic stale attempt', 1) INTO v_result;
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'Stale edit was accepted.'; END IF;
  SELECT public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_activity, gen_random_uuid(), gen_random_uuid(), DATE '2026-11-03', DATE '2026-11-07',
    'Synthetic unauthorized attempt', 2) INTO v_result;
  IF v_result->>'status' <> 'forbidden' THEN RAISE EXCEPTION 'Unknown actor was accepted.'; END IF;

  BEGIN
    PERFORM public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
      v_activity, v_actor, v_operation, DATE '2026-11-03', DATE '2026-11-07',
      'Synthetic duplicate operation attempt', 2);
    RAISE EXCEPTION 'Duplicate operation was accepted.';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_activity AND planned_start = DATE '2026-11-02'
        AND planned_end = DATE '2026-11-06' AND version = 2) THEN
    RAISE EXCEPTION 'Audit failure did not roll back the date update.';
  END IF;
  SELECT count(*) INTO v_count FROM public.activity_date_changes WHERE activity_id = v_activity;
  IF v_count <> 1 THEN RAISE EXCEPTION 'Failed operations changed audit history.'; END IF;

  BEGIN
    UPDATE public.activity_date_changes SET reason = 'Tampered' WHERE operation_id = v_operation;
    RAISE EXCEPTION 'Audit history update was accepted.';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;
  BEGIN
    DELETE FROM public.activity_date_changes WHERE operation_id = v_operation;
    RAISE EXCEPTION 'Audit history deletion was accepted.';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = snapshot WHERE id = v_revision;
    RAISE EXCEPTION 'R00 update was accepted.';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;
  IF NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
      WHERE id = v_revision AND snapshot->'activity'->>'plannedStart' = '2026-11-01') THEN
    RAISE EXCEPTION 'R00 snapshot changed.';
  END IF;
END;
$$;

ROLLBACK;
