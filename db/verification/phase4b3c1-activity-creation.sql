-- Run only as jlproject_worker against an approved disposable Development child.
-- The owner-provisioned fixture must contain one active administrator and one distinct active viewer, plus:
--   * linked_product: a derived predecessor ending 2026-11-05 linked to a derived successor starting 2026-11-06;
--   * explicit_stage and partial_stage, each linked as predecessor to a fixed successor, with explicit end 2026-11-05;
--   * existing_violation_product: a linked derived pair already in conflict, with boundaries unchanged by the test child;
--   * empty_product with empty_stage and no dependency rows.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_activity_creation_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'viewer', :'test_viewer',
  'linkedProduct', :'test_linked_product', 'derivedPredecessor', :'test_derived_predecessor_stage',
  'derivedSuccessor', :'test_derived_successor_stage', 'explicitStage', :'test_explicit_stage',
  'partialStage', :'test_partial_stage', 'violationProduct', :'test_violation_product',
  'violationStage', :'test_violation_stage', 'emptyProduct', :'test_empty_product',
  'emptyStage', :'test_empty_stage')::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_activity_creation_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_viewer uuid := (v_fixture->>'viewer')::uuid;
  v_linked_product uuid := (v_fixture->>'linkedProduct')::uuid;
  v_derived_predecessor uuid := (v_fixture->>'derivedPredecessor')::uuid;
  v_derived_successor uuid := (v_fixture->>'derivedSuccessor')::uuid;
  v_explicit_stage uuid := (v_fixture->>'explicitStage')::uuid;
  v_partial_stage uuid := (v_fixture->>'partialStage')::uuid;
  v_violation_product uuid := (v_fixture->>'violationProduct')::uuid;
  v_violation_stage uuid := (v_fixture->>'violationStage')::uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_stage uuid := (v_fixture->>'emptyStage')::uuid;
  v_result jsonb;
  v_conflict jsonb;
  v_detail text;
  v_calendar_version bigint;
  v_operation uuid;
  v_linked_operation uuid := gen_random_uuid();
  v_cursor_before jsonb;
  v_cursor_after jsonb;
  v_rows_before bigint;
  v_insert_count integer;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR NOT EXISTS (
      SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
        AND auth_user_id = v_actor AND active AND role = 'admin') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_viewer AND active AND role = 'viewer') OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND id = v_linked_product AND active) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND id = v_empty_product AND active) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND id = v_violation_product AND active) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND id = v_derived_predecessor AND planned_start IS NULL AND planned_end IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND stage_id = v_derived_predecessor AND deleted_at IS NULL
       GROUP BY stage_id HAVING max(planned_end) = DATE '2026-11-05') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND stage_id = v_derived_successor AND deleted_at IS NULL
       GROUP BY stage_id HAVING min(planned_start) = DATE '2026-11-06') OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND id = v_explicit_stage AND planned_end = DATE '2026-11-05') OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND id = v_partial_stage
       AND planned_start IS NULL AND planned_end = DATE '2026-11-05') OR
     has_table_privilege(current_user, 'public.product_schedule_dependencies', 'SELECT') OR
     has_function_privilege(current_user,
       'public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)', 'EXECUTE') OR
     has_function_privilege(current_user, 'public.guard_activity_creation_before_insert()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Expected the preprovisioned activity creation fixture and private guards.';
  END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions WHERE workspace_id = v_workspace), 0)
    INTO v_calendar_version;

  -- Root activities do not change any stage endpoint, even in a linked product.
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_linked_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic root creation check', true);
  INSERT INTO public.stage_activities (workspace_id, product_id, discipline_id, stage_id, name,
    activity_type, planned_start, planned_end, display_order, notes, created_by, updated_by)
  VALUES (v_workspace, v_linked_product, NULL, NULL, 'Synthetic dependency root', NULL,
    DATE '2026-11-03', DATE '2026-11-04', 900000, NULL, v_actor, v_actor);
  GET DIAGNOSTICS v_insert_count = ROW_COUNT;
  IF v_insert_count IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Root activity was not inserted.'; END IF;

  -- New children within an existing derived interval preserve the graph, including a standing violation.
  v_operation := v_linked_operation;
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic unchanged derived child', true);
  INSERT INTO public.stage_activities (workspace_id, product_id, discipline_id, stage_id, name,
    activity_type, planned_start, planned_end, display_order, notes, created_by, updated_by)
  SELECT v_workspace, v_linked_product, stage.discipline_id, v_derived_predecessor,
    'Synthetic valid derived child', NULL, DATE '2026-11-03', DATE '2026-11-04', 900001, NULL, v_actor, v_actor
  FROM public.discipline_stages AS stage WHERE stage.workspace_id = v_workspace
    AND stage.product_id = v_linked_product AND stage.id = v_derived_predecessor;
  GET DIAGNOSTICS v_insert_count = ROW_COUNT;
  IF v_insert_count IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Valid derived child was not inserted.'; END IF;

  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic unchanged violation child', true);
  INSERT INTO public.stage_activities (workspace_id, product_id, discipline_id, stage_id, name,
    activity_type, planned_start, planned_end, display_order, notes, created_by, updated_by)
  SELECT v_workspace, v_violation_product, stage.discipline_id, v_violation_stage,
    'Synthetic unchanged violation child', NULL, DATE '2026-11-03', DATE '2026-11-04', 900002, NULL, v_actor, v_actor
  FROM public.discipline_stages AS stage WHERE stage.workspace_id = v_workspace
    AND stage.product_id = v_violation_product AND stage.id = v_violation_stage;
  GET DIAGNOSTICS v_insert_count = ROW_COUNT;
  IF v_insert_count IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'Existing-violation child was not inserted.'; END IF;

  -- A newly extended derived predecessor returns a structured conflict without a write or cursor advance.
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS cursor_state;
  SELECT count(*) INTO v_rows_before FROM public.stage_activities
    WHERE workspace_id = v_workspace AND product_id = v_linked_product;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic blocked derived child', true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_linked_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_derived_predecessor), v_derived_predecessor,
    v_actor, 'Synthetic blocked derived predecessor', NULL, DATE '2026-11-09', DATE '2026-11-10',
    900003, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_result#>>'{conflict,predecessor,id}' IS DISTINCT FROM v_derived_predecessor::text OR
     v_result#>>'{conflict,successor,id}' IS DISTINCT FROM v_derived_successor::text THEN
    RAISE EXCEPTION 'Derived predecessor extension did not return the expected conflict.';
  END IF;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS cursor_state;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before OR (SELECT count(*) FROM public.stage_activities
      WHERE workspace_id = v_workspace AND product_id = v_linked_product) IS DISTINCT FROM v_rows_before OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_linked_product AND name = 'Synthetic blocked derived predecessor') THEN
    RAISE EXCEPTION 'Blocked creation changed rows or the schedule cursor.';
  END IF;

  -- A derived successor start moving earlier is also blocked by the same complete final-state check.
  v_result := public.create_activity_with_working_plan(v_workspace, v_linked_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_derived_successor), v_derived_successor,
    v_actor, 'Synthetic blocked derived successor', NULL, DATE '2026-11-05', DATE '2026-11-06',
    900004, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_result#>>'{conflict,successor,id}' IS DISTINCT FROM v_derived_successor::text THEN
    RAISE EXCEPTION 'Derived successor start change did not return the expected conflict.';
  END IF;

  -- The database trigger protects the manual direct INSERT path and exposes only structured SQL detail.
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS cursor_state;
  BEGIN
    PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true),
      set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
      set_config('jlproject.schedule_justification', 'Synthetic trigger conflict check', true);
    INSERT INTO public.stage_activities (workspace_id, product_id, discipline_id, stage_id, name,
      activity_type, planned_start, planned_end, display_order, notes, created_by, updated_by)
    SELECT v_workspace, v_linked_product, stage.discipline_id, v_derived_predecessor,
      'Synthetic trigger conflict', NULL, DATE '2026-11-09', DATE '2026-11-10', 900005, NULL, v_actor, v_actor
    FROM public.discipline_stages AS stage WHERE stage.workspace_id = v_workspace
      AND stage.product_id = v_linked_product AND stage.id = v_derived_predecessor;
    RAISE EXCEPTION 'Expected the activity creation trigger to reject this insert.' USING ERRCODE = 'ZX041';
  EXCEPTION WHEN SQLSTATE 'P4D01' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    v_conflict := v_detail::jsonb;
    IF v_conflict->>'status' IS DISTINCT FROM 'dependency_conflict' OR
       v_conflict#>>'{conflict,predecessor,id}' IS DISTINCT FROM v_derived_predecessor::text THEN RAISE; END IF;
  WHEN SQLSTATE 'ZX041' THEN RAISE;
  END;
  IF EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
      AND product_id = v_linked_product AND name = 'Synthetic trigger conflict') THEN
    RAISE EXCEPTION 'The rejected direct insert remained visible after rollback.';
  END IF;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_linked_product, v_actor) AS cursor_state;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before THEN
    RAISE EXCEPTION 'The rejected direct insert advanced the schedule cursor.';
  END IF;

  -- Explicit and partially explicit stages keep their dates; a child outside the fixed interval is allowed.
  v_operation := v_linked_operation;
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic fixed D065 boundary child', true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_linked_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_explicit_stage), v_explicit_stage,
    v_actor, 'Synthetic explicit stage child', NULL, DATE '2026-11-09', DATE '2026-11-10',
    900006, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The explicit D065 stage boundary was moved by child creation: %', v_result;
  END IF;
  v_operation := v_linked_operation;
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
    set_config('jlproject.schedule_justification', 'Synthetic partial D065 boundary child', true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_linked_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_partial_stage), v_partial_stage,
    v_actor, 'Synthetic partial stage child', NULL, DATE '2026-11-09', DATE '2026-11-10',
    900007, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The partial D065 stage boundary was moved by child creation: %', v_result;
  END IF;

  -- Worker authorization and empty-graph compatibility remain in force.
  PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_empty_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_empty_stage), v_empty_stage,
    v_viewer, 'Synthetic unauthorized child', NULL, DATE '2026-11-03', DATE '2026-11-04',
    900008, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Viewer activity creation was accepted.'; END IF;
  v_result := public.create_activity_with_working_plan(v_workspace, v_empty_product,
    (SELECT discipline_id FROM public.discipline_stages WHERE id = v_empty_stage), v_empty_stage,
    v_actor, 'Synthetic empty graph child', NULL, DATE '2026-11-03', DATE '2026-11-04',
    900009, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Empty-graph activity creation changed behavior.'; END IF;
END;
$$;

ROLLBACK;
