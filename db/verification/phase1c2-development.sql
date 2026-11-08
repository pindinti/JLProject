BEGIN;

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_disciplines jsonb;
  v_meta jsonb;
  v_targets jsonb;
  v_payload jsonb;
  v_failed jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_duplicate jsonb;
  v_key uuid := gen_random_uuid();
  v_product uuid;
  v_revision uuid;
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.workspace_memberships AS membership
    JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
    WHERE workspace.name = 'JLProject' AND membership.active = true AND membership.role = 'admin';
  IF v_count <> 1 THEN RAISE EXCEPTION 'Expected exactly one JLProject development administrator.'; END IF;
  SELECT membership.workspace_id, membership.auth_user_id INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
    WHERE workspace.name = 'JLProject' AND membership.active = true AND membership.role = 'admin';

  SELECT jsonb_agg(jsonb_build_object(
    'name', 'Synthetic discipline ' || discipline_number,
    'shortCode', 'D' || discipline_number, 'color', '#336699',
    'displayOrder', discipline_number - 1,
    'stages', (SELECT jsonb_agg(jsonb_build_object(
      'code', 'E' || stage_number, 'color', '#336699',
      'displayName', 'E' || stage_number, 'displayOrder', stage_number - 1,
      'activities', (SELECT jsonb_agg(jsonb_build_object(
        'sourceId', 'T' || lpad(activity_number::text, 3, '0'),
        'sourceRow', activity_number + 4, 'name', 'Synthetic activity ' || activity_number,
        'activityType', 'Análise', 'status', null, 'notes', null,
        'plannedStart', '2026-11-01', 'plannedEnd', '2026-11-03',
        'displayOrder', activity_number + 4) ORDER BY activity_number)
        FROM generate_series((discipline_number - 1) * 6 + (stage_number - 1) * 2 + 1,
          least((discipline_number - 1) * 6 + stage_number * 2, 41)) AS activity_number)
    ) ORDER BY stage_number) FROM generate_series(1, 3) AS stage_number)
  ) ORDER BY discipline_number) INTO v_disciplines FROM generate_series(1, 7) AS discipline_number;

  SELECT jsonb_agg(jsonb_build_object(
    'sourceId', 'T' || lpad((meta_number + 41)::text, 3, '0'),
    'sourceRow', meta_number + 45, 'name', 'Synthetic target ' || meta_number,
    'discipline', 'Synthetic discipline 1', 'stage', 'E1',
    'plannedStart', (date '2027-01-03' + (meta_number - 1) * 30)::text,
    'plannedEnd', (date '2027-01-03' + (meta_number - 1) * 30)::text,
    'status', null, 'notes', null
  ) ORDER BY meta_number) INTO v_meta FROM generate_series(1, 5) AS meta_number;

  SELECT jsonb_agg(jsonb_build_object(
    'name', 'Synthetic target ' || meta_number,
    'sourceRow', meta_number + 3,
    'targetDate', (date '2027-01-03' + (meta_number - 1) * 30)::text,
    'operationalDate', CASE WHEN meta_number = 1 THEN '2027-01-01' ELSE null END,
    'status', null, 'notes', null, 'displayOrder', meta_number - 1,
    'matchedSourceId', 'T' || lpad((meta_number + 41)::text, 3, '0'),
    'matchMethod', 'exact'
  ) ORDER BY meta_number) INTO v_targets FROM generate_series(1, 5) AS meta_number;

  v_payload := jsonb_build_object('idempotencyKey', v_key, 'productName',
    'Synthetic import verification ' || v_key, 'sourceFilename', 'synthetic.xlsx',
    'disciplines', v_disciplines, 'sourceMeta', v_meta, 'targets', v_targets);

  v_result := public.import_initial_schedule(v_workspace, v_actor, v_key,
    repeat('a', 64), repeat('b', 64), v_payload);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Synthetic import was not created.'; END IF;
  v_product := (v_result->>'productId')::uuid;
  v_revision := (v_result->>'revisionId')::uuid;

  SELECT count(*) INTO v_count FROM public.product_disciplines WHERE product_id = v_product;
  IF v_count <> 7 THEN RAISE EXCEPTION 'Discipline count mismatch.'; END IF;
  SELECT count(*) INTO v_count FROM public.discipline_stages WHERE product_id = v_product;
  IF v_count <> 21 THEN RAISE EXCEPTION 'Stage count mismatch.'; END IF;
  SELECT count(*) INTO v_count FROM public.stage_activities WHERE product_id = v_product;
  IF v_count <> 41 THEN RAISE EXCEPTION 'Activity count mismatch.'; END IF;
  SELECT count(*) INTO v_count FROM public.business_targets WHERE product_id = v_product;
  IF v_count <> 5 THEN RAISE EXCEPTION 'Target count mismatch.'; END IF;
  SELECT count(*) INTO v_count FROM public.import_source_rows AS source
    JOIN public.import_batches AS batch ON batch.id = source.import_batch_id
    WHERE batch.product_id = v_product;
  IF v_count <> 51 THEN RAISE EXCEPTION 'Provenance count mismatch.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
      WHERE id = v_revision AND label = 'R00' AND snapshot->'dependencies' = '[]'::jsonb
        AND jsonb_array_length(snapshot->'disciplines') = 7
        AND jsonb_array_length(snapshot->'targets') = 5) THEN
    RAISE EXCEPTION 'R00 snapshot mismatch.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_product
      AND (planned_start <> date '2026-11-01' OR planned_end <> date '2026-11-03')) THEN
    RAISE EXCEPTION 'Activity dates changed.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_targets WHERE product_id = v_product
      AND target_date = date '2027-01-03' AND operational_date = date '2027-01-01') THEN
    RAISE EXCEPTION 'Official and operational target dates were not preserved.';
  END IF;

  v_replay := public.import_initial_schedule(v_workspace, v_actor, v_key,
    repeat('a', 64), repeat('b', 64), v_payload);
  IF v_replay->>'status' <> 'replayed' OR v_replay->>'productId' <> v_product::text THEN
    RAISE EXCEPTION 'Idempotent replay failed.';
  END IF;
  v_duplicate := public.import_initial_schedule(v_workspace, v_actor, gen_random_uuid(),
    repeat('a', 64), repeat('c', 64), v_payload);
  IF v_duplicate->>'status' <> 'duplicate' THEN RAISE EXCEPTION 'Duplicate source was accepted.'; END IF;

  v_failed := jsonb_set(v_payload, '{disciplines,0,stages,0,activities,1,sourceId}', '"T001"'::jsonb);
  v_failed := jsonb_set(v_failed, '{productName}', to_jsonb('Synthetic failed import ' || v_key));
  BEGIN
    PERFORM public.import_initial_schedule(v_workspace, v_actor, gen_random_uuid(),
      repeat('d', 64), repeat('e', 64), v_failed);
    RAISE EXCEPTION 'Expected partial-failure test to fail.';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  IF EXISTS (SELECT 1 FROM public.products WHERE name = v_failed->>'productName') THEN
    RAISE EXCEPTION 'Failed import left a product.';
  END IF;

  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = snapshot WHERE id = v_revision;
    RAISE EXCEPTION 'R00 update was accepted.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET planned_end = planned_end + 1 WHERE product_id = v_product;
    RAISE EXCEPTION 'Existing activity date update was accepted.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'Phase 1C.2 synthetic import checks passed; transaction will roll back.';
END;
$$;

ROLLBACK;
