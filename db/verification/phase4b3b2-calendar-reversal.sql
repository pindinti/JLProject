-- Run as the limited Worker on an approved disposable Development child with the documented synthetic fixture.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_calendar_reversal_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'blockedProduct', :'test_blocked_product',
  'blockedDependency', '4b400000-0000-4000-8000-000000000201',
  'blockedPredStage', '4b400000-0000-4000-8000-000000000001',
  'blockedSuccStage', '4b400000-0000-4000-8000-000000000002',
  'blockedBatch', :'test_blocked_batch', 'staleActivity', :'test_stale_activity', 'linkedProduct', :'test_linked_product',
  'linkedBatch', :'test_linked_batch', 'collision', :'test_colliding_reversal',
  'emptyProduct', :'test_empty_product', 'emptyBatch', :'test_empty_batch')::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_calendar_reversal_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_blocked_product uuid := (v_fixture->>'blockedProduct')::uuid;
  v_blocked_batch uuid := (v_fixture->>'blockedBatch')::uuid;
  v_stale_activity uuid := (v_fixture->>'staleActivity')::uuid;
  v_blocked_dependency uuid := (v_fixture->>'blockedDependency')::uuid;
  v_blocked_predecessor_stage uuid := (v_fixture->>'blockedPredStage')::uuid;
  v_blocked_successor_stage uuid := (v_fixture->>'blockedSuccStage')::uuid;
  v_linked_product uuid := (v_fixture->>'linkedProduct')::uuid;
  v_linked_batch uuid := (v_fixture->>'linkedBatch')::uuid;
  v_collision uuid := (v_fixture->>'collision')::uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_batch uuid := (v_fixture->>'emptyBatch')::uuid;
  v_reversal uuid := gen_random_uuid();
  v_reason constant text := 'Synthetic calendar reversal dependency verification';
  v_result jsonb;
  v_cursor_before jsonb;
  v_cursor_after jsonb;
  v_rows_before jsonb;
  v_rows_after jsonb;
  v_operations_before jsonb;
  v_operations_after jsonb;
  v_event_ids uuid[];
  v_audit_before jsonb;
  v_audit_after jsonb;
  v_collision_constraint text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR NOT EXISTS (
    SELECT 1 FROM public.workspaces WHERE id = v_workspace AND name = 'Synthetic Phase 4B.3b.2 workspace'
  ) OR (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace AND
      (id, name) IN ((v_blocked_product, 'Synthetic Phase 4B.3b.2 blocked product'),
        (v_linked_product, 'Synthetic Phase 4B.3b.2 linked product'),
        (v_empty_product, 'Synthetic Phase 4B.3b.2 empty product'))) <> 3 THEN
    RAISE EXCEPTION 'Expected the synthetic reversal fixture.';
  END IF;
  IF has_function_privilege(current_user, 'public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)', 'EXECUTE')
    OR has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'UPDATE')
    OR has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') THEN
    RAISE EXCEPTION 'The Worker can bypass the reversal entry point.';
  END IF;

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_reversal::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_reschedule_reversed', true),
    set_config('jlproject.schedule_justification', v_reason, true),
    set_config('jlproject.schedule_reversal_of', v_blocked_batch::text, true);
  SELECT jsonb_agg(to_jsonb(activity) ORDER BY activity.id) INTO v_rows_before
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace AND activity.product_id = v_blocked_product;
  SELECT COALESCE(jsonb_agg(to_jsonb(operation) ORDER BY operation.schedule_version), '[]'::jsonb)
    INTO v_operations_before
    FROM public.list_product_schedule_operations(v_workspace, v_blocked_product, v_actor, NULL, 100) AS operation;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor_before
    FROM public.read_product_schedule_cursor(v_workspace, v_blocked_product, v_actor) AS saved_cursor;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_blocked_product, v_actor, NULL, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN RAISE EXCEPTION 'Missing original batch was accepted.'; END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_blocked_product, v_actor, v_blocked_batch, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict'
    OR v_result#>>'{conflict,reason}' IS DISTINCT FROM 'finish_to_start'
    OR v_result#>>'{conflict,dependencyId}' IS DISTINCT FROM v_blocked_dependency::text
    OR v_result#>>'{conflict,predecessor,id}' IS DISTINCT FROM v_blocked_predecessor_stage::text
    OR v_result#>>'{conflict,predecessor,kind}' IS DISTINCT FROM 'stage'
    OR v_result#>>'{conflict,successor,id}' IS DISTINCT FROM v_blocked_successor_stage::text
    OR v_result#>>'{conflict,successor,kind}' IS DISTINCT FROM 'stage'
    OR v_result#>>'{conflict,before,predecessorFinish}' IS DISTINCT FROM '2026-11-11'
    OR v_result#>>'{conflict,before,successorStart}' IS DISTINCT FROM '2026-11-12'
    OR v_result#>>'{conflict,before,earliestStart}' IS DISTINCT FROM '2026-11-12'
    OR v_result#>>'{conflict,after,predecessorFinish}' IS DISTINCT FROM '2026-11-13'
    OR v_result#>>'{conflict,after,successorStart}' IS DISTINCT FROM '2026-11-12'
    OR v_result#>>'{conflict,after,earliestStart}' IS DISTINCT FROM '2026-11-16' THEN
    RAISE EXCEPTION 'Unexpected derived-stage reversal response payload: %', v_result;
  END IF;
  RAISE NOTICE 'Expected derived-stage reversal conflict payload: %', v_result;
  SELECT jsonb_agg(to_jsonb(activity) ORDER BY activity.id) INTO v_rows_after
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace AND activity.product_id = v_blocked_product;
  SELECT COALESCE(jsonb_agg(to_jsonb(operation) ORDER BY operation.schedule_version), '[]'::jsonb)
    INTO v_operations_after
    FROM public.list_product_schedule_operations(v_workspace, v_blocked_product, v_actor, NULL, 100) AS operation;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor_after
    FROM public.read_product_schedule_cursor(v_workspace, v_blocked_product, v_actor) AS saved_cursor;
  IF v_rows_after IS DISTINCT FROM v_rows_before OR v_operations_after IS DISTINCT FROM v_operations_before
    OR v_cursor_after IS DISTINCT FROM v_cursor_before THEN
    RAISE EXCEPTION 'Blocked reversal changed schedule dates/versions, audit history, or cursor.';
  END IF;

  BEGIN
    UPDATE public.stage_activities SET version = version + 1
      WHERE workspace_id = v_workspace AND product_id = v_blocked_product AND id = v_stale_activity;
    IF NOT FOUND THEN RAISE EXCEPTION 'Missing stale-test activity.'; END IF;
    v_result := public.reverse_calendar_reschedule(v_workspace, v_blocked_product, v_actor, v_blocked_batch, v_reversal, v_reason);
    IF v_result->>'status' IS DISTINCT FROM 'stale' OR v_result->>'activityId' IS DISTINCT FROM v_stale_activity::text THEN
      RAISE EXCEPTION 'Reversal accepted a stale historical row token.';
    END IF;
    RAISE EXCEPTION 'Rollback the synthetic version change.' USING ERRCODE = 'ZX043';
  EXCEPTION WHEN SQLSTATE 'ZX043' THEN NULL;
  END;

  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor_before
    FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS saved_cursor;
  SELECT jsonb_agg(to_jsonb(activity) ORDER BY activity.id) INTO v_rows_before FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_linked_product;
  SELECT array_agg(DISTINCT (source->>'eventId')::uuid) INTO v_event_ids
    FROM public.list_product_schedule_operations(v_workspace, v_linked_product, v_actor, NULL, 100) AS batch
    CROSS JOIN LATERAL jsonb_array_elements(batch.source_operations) AS source
    WHERE batch.operation_id = v_linked_batch AND source->>'ledger' = 'activity_date_changes' AND source->>'kind' = 'audit_detail';
  IF cardinality(v_event_ids) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Expected two exact original activity audit IDs.'; END IF;
  SELECT jsonb_agg(to_jsonb(audit) ORDER BY audit.operation_id) INTO v_audit_before FROM public.activity_date_changes AS audit
    WHERE workspace_id = v_workspace AND product_id = v_linked_product AND operation_id = ANY(v_event_ids);
  IF jsonb_array_length(v_audit_before) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Original activity audit payloads are missing.'; END IF;

  PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true),
    set_config('jlproject.schedule_reversal_of', v_linked_batch::text, true);
  BEGIN
    -- The collision is restricted to the second activity's reversal ledger row. The generic operation UUID is fresh.
    PERFORM public.reverse_calendar_reschedule(v_workspace, v_linked_product, v_actor, v_linked_batch, v_collision, v_reason);
    RAISE EXCEPTION 'Expected a late reversal audit collision.';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_collision_constraint = CONSTRAINT_NAME;
    IF v_collision_constraint IS DISTINCT FROM 'calendar_reversal_one_activity_per_batch' THEN RAISE; END IF;
  END;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor_after
    FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS saved_cursor;
  SELECT jsonb_agg(to_jsonb(activity) ORDER BY activity.id) INTO v_rows_after FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_linked_product;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before OR v_rows_after IS DISTINCT FROM v_rows_before THEN
    RAISE EXCEPTION 'Late reversal failure left partial dates or cursor changes.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_id', v_reversal::text, true);
  v_result := public.reverse_calendar_reschedule(v_workspace, v_linked_product, v_actor, v_linked_batch, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR (v_result->>'count')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'A valid or improving linked reversal was rejected.';
  END IF;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor_after
    FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS saved_cursor;
  IF (v_cursor_after->>'schedule_version')::bigint IS DISTINCT FROM (v_cursor_before->>'schedule_version')::bigint + 1 THEN
    RAISE EXCEPTION 'Successful reversal did not advance the cursor once.';
  END IF;
  SELECT jsonb_agg(to_jsonb(audit) ORDER BY audit.operation_id) INTO v_audit_after FROM public.activity_date_changes AS audit
    WHERE workspace_id = v_workspace AND product_id = v_linked_product AND operation_id = ANY(v_event_ids);
  IF v_audit_after IS DISTINCT FROM v_audit_before OR (SELECT count(DISTINCT source->>'eventId')
    FROM public.list_product_schedule_operations(v_workspace, v_linked_product, v_actor, NULL, 100) AS batch
    CROSS JOIN LATERAL jsonb_array_elements(batch.source_operations) AS source
    WHERE batch.operation_id = v_reversal AND batch.reversal_of_operation_id = v_linked_batch
      AND source->>'ledger' = 'calendar_reschedule_reversals' AND source->>'kind' = 'audit_detail') <> 2 THEN
    RAISE EXCEPTION 'The reversal did not preserve original audit payloads and append two exact reversal links.';
  END IF;

  v_reversal := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_reversal::text, true),
    set_config('jlproject.schedule_reversal_of', v_empty_batch::text, true);
  v_result := public.reverse_calendar_reschedule(v_workspace, v_empty_product, v_actor, v_empty_batch, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' THEN RAISE EXCEPTION 'Empty-graph reversal behavior changed.'; END IF;
END;
$$;

ROLLBACK;
