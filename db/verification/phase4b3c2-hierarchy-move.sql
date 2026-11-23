-- Run only as jlproject_worker against an approved disposable Development child.
-- Owner-provisioned fixture requirements are listed in the phase checkpoint document.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_hierarchy_move_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'viewer', :'test_viewer',
  'conflictProduct', :'test_conflict_product', 'conflictActivity', :'test_conflict_activity',
  'conflictSourceDiscipline', :'test_conflict_source_discipline', 'conflictSourceStage', :'test_conflict_source_stage',
  'conflictDestinationDiscipline', :'test_conflict_destination_discipline', 'conflictDestinationStage', :'test_conflict_destination_stage',
  'conflictDependency', :'test_conflict_dependency', 'validProduct', :'test_valid_product',
  'validActivity', :'test_valid_activity', 'validSourceDiscipline', :'test_valid_source_discipline',
  'validSourceStage', :'test_valid_source_stage', 'validDestinationDiscipline', :'test_valid_destination_discipline',
  'validDestinationStage', :'test_valid_destination_stage', 'fixedProduct', :'test_fixed_product',
  'fixedActivity', :'test_fixed_activity', 'fixedSourceDiscipline', :'test_fixed_source_discipline',
  'explicitStage', :'test_explicit_stage', 'fixedDestinationDiscipline', :'test_fixed_destination_discipline',
  'partialStage', :'test_partial_stage', 'rootProduct', :'test_root_product', 'rootActivity', :'test_root_activity',
  'rootStage', :'test_root_stage', 'rootDiscipline', :'test_root_discipline',
  'emptyProduct', :'test_empty_product', 'emptyActivity', :'test_empty_activity',
  'emptySourceDiscipline', :'test_empty_source_discipline', 'emptySourceStage', :'test_empty_source_stage',
  'emptyDestinationDiscipline', :'test_empty_destination_discipline', 'emptyDestinationStage', :'test_empty_destination_stage',
  'secondOperation', gen_random_uuid())::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_hierarchy_move_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_viewer uuid := (v_fixture->>'viewer')::uuid;
  v_conflict_product uuid := (v_fixture->>'conflictProduct')::uuid;
  v_conflict_activity uuid := (v_fixture->>'conflictActivity')::uuid;
  v_conflict_source_discipline uuid := (v_fixture->>'conflictSourceDiscipline')::uuid;
  v_conflict_source_stage uuid := (v_fixture->>'conflictSourceStage')::uuid;
  v_conflict_destination_discipline uuid := (v_fixture->>'conflictDestinationDiscipline')::uuid;
  v_conflict_destination_stage uuid := (v_fixture->>'conflictDestinationStage')::uuid;
  v_conflict_dependency uuid := (v_fixture->>'conflictDependency')::uuid;
  v_valid_product uuid := (v_fixture->>'validProduct')::uuid;
  v_valid_activity uuid := (v_fixture->>'validActivity')::uuid;
  v_valid_source_discipline uuid := (v_fixture->>'validSourceDiscipline')::uuid;
  v_valid_source_stage uuid := (v_fixture->>'validSourceStage')::uuid;
  v_valid_destination_discipline uuid := (v_fixture->>'validDestinationDiscipline')::uuid;
  v_valid_destination_stage uuid := (v_fixture->>'validDestinationStage')::uuid;
  v_fixed_product uuid := (v_fixture->>'fixedProduct')::uuid;
  v_fixed_activity uuid := (v_fixture->>'fixedActivity')::uuid;
  v_fixed_source_discipline uuid := (v_fixture->>'fixedSourceDiscipline')::uuid;
  v_explicit_stage uuid := (v_fixture->>'explicitStage')::uuid;
  v_fixed_destination_discipline uuid := (v_fixture->>'fixedDestinationDiscipline')::uuid;
  v_partial_stage uuid := (v_fixture->>'partialStage')::uuid;
  v_root_product uuid := (v_fixture->>'rootProduct')::uuid;
  v_root_activity uuid := (v_fixture->>'rootActivity')::uuid;
  v_root_stage uuid := (v_fixture->>'rootStage')::uuid;
  v_root_discipline uuid := (v_fixture->>'rootDiscipline')::uuid;
  v_root_boundary_child uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_activity uuid := (v_fixture->>'emptyActivity')::uuid;
  v_empty_source_discipline uuid := (v_fixture->>'emptySourceDiscipline')::uuid;
  v_empty_source_stage uuid := (v_fixture->>'emptySourceStage')::uuid;
  v_empty_destination_discipline uuid := (v_fixture->>'emptyDestinationDiscipline')::uuid;
  v_empty_destination_stage uuid := (v_fixture->>'emptyDestinationStage')::uuid;
  v_second_operation uuid := (v_fixture->>'secondOperation')::uuid;
  v_result jsonb;
  v_source_order jsonb;
  v_destination_order jsonb;
  v_cursor_before jsonb;
  v_cursor_after jsonb;
  v_item_before jsonb;
  v_item_after jsonb;
  v_dates_before jsonb;
  v_dates_after jsonb;
  v_fixed_dates_before jsonb;
  v_fixed_dates_after jsonb;
  v_operation uuid;
  v_version bigint;
  v_error_state text;
  v_error text;
  v_second_operation_rejected boolean := false;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     has_function_privilege(current_user,
       'public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.product_schedule_dependencies', 'SELECT') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role = 'admin') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_viewer AND active AND role = 'viewer') THEN
    RAISE EXCEPTION 'Expected the preprovisioned Worker hierarchy movement fixture and private guard.';
  END IF;

  -- A same-parent reorder of linked work must leave all activity dates intact.
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_conflict_product
    AND discipline_id = v_conflict_source_discipline AND stage_id = v_conflict_source_stage AND deleted_at IS NULL;
  IF jsonb_array_length(v_source_order) < 2 OR v_source_order->>0 IS DISTINCT FROM v_conflict_activity::text THEN
    RAISE EXCEPTION 'Pure reorder fixture must place the target first among multiple activities.';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end) ORDER BY id)
    INTO v_dates_before FROM public.stage_activities WHERE workspace_id = v_workspace
      AND product_id = v_conflict_product AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic pure reorder check', true);
  v_result := public.move_schedule_item(v_workspace, v_conflict_product, v_actor, v_operation, 'activity',
    v_conflict_activity, (SELECT version FROM public.stage_activities WHERE id = v_conflict_activity),
    v_conflict_source_discipline, v_conflict_source_stage, jsonb_array_length(v_source_order) - 1,
    v_source_order, v_source_order);
  IF v_result->>'status' IS DISTINCT FROM 'moved' THEN RAISE EXCEPTION 'Pure reorder was rejected: %', v_result; END IF;
  SELECT jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end) ORDER BY id)
    INTO v_dates_after FROM public.stage_activities WHERE workspace_id = v_workspace
      AND product_id = v_conflict_product AND deleted_at IS NULL;
  IF v_dates_after IS DISTINCT FROM v_dates_before THEN RAISE EXCEPTION 'Pure reorder changed activity dates.'; END IF;

  -- A multi-edge derived-stage conflict uses final source-child removal and destination-child addition together.
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_conflict_product
    AND discipline_id = v_conflict_source_discipline AND stage_id = v_conflict_source_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_conflict_product
    AND discipline_id = v_conflict_destination_discipline AND stage_id = v_conflict_destination_stage AND deleted_at IS NULL;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_conflict_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_before FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_conflict_product AND id = v_conflict_activity;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic blocked reparent check', true);
  v_result := public.move_schedule_item(v_workspace, v_conflict_product, v_actor, v_operation, 'activity',
    v_conflict_activity, (v_item_before->>'version')::bigint, v_conflict_destination_discipline,
    v_conflict_destination_stage, jsonb_array_length(v_destination_order), v_source_order, v_destination_order);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_result#>>'{conflict,dependencyId}' IS DISTINCT FROM v_conflict_dependency::text OR
     v_result#>>'{conflict,reason}' IS DISTINCT FROM 'finish_to_start' OR
     v_result#>>'{conflict,before,earliestStart}' IS DISTINCT FROM '2026-11-06' OR
     v_result#>>'{conflict,after,earliestStart}' IS DISTINCT FROM '2026-11-11' THEN
    RAISE EXCEPTION 'Conflicting final stage boundaries were not reported: %', v_result;
  END IF;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_conflict_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_after FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_conflict_product AND id = v_conflict_activity;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before OR v_item_after IS DISTINCT FROM v_item_before THEN
    RAISE EXCEPTION 'Blocked move changed the source row or schedule cursor.';
  END IF;

  -- Stale versions and viewer authorization fail before any movement or dependency write.
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  v_result := public.move_schedule_item(v_workspace, v_conflict_product, v_actor, v_operation, 'activity',
    v_conflict_activity, (v_item_before->>'version')::bigint + 1, v_conflict_source_discipline,
    v_conflict_source_stage, 0, v_source_order, v_source_order);
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'Stale version was accepted.'; END IF;
  v_result := public.move_schedule_item(v_workspace, v_conflict_product, v_viewer, gen_random_uuid(), 'activity',
    v_conflict_activity, (v_item_before->>'version')::bigint, v_conflict_source_discipline,
    v_conflict_source_stage, 0, v_source_order, v_source_order);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Viewer move was accepted.'; END IF;

  -- A valid final interval is allowed when source shrink and destination growth satisfy all linked edges.
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_valid_product
    AND discipline_id = v_valid_source_discipline AND stage_id = v_valid_source_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_valid_product
    AND discipline_id = v_valid_destination_discipline AND stage_id = v_valid_destination_stage AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic valid derived reparent', true);
  v_result := public.move_schedule_item(v_workspace, v_valid_product, v_actor, v_operation, 'activity',
    v_valid_activity, (SELECT version FROM public.stage_activities WHERE id = v_valid_activity),
    v_valid_destination_discipline, v_valid_destination_stage, jsonb_array_length(v_destination_order),
    v_source_order, v_destination_order);
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE workspace_id = v_workspace AND product_id = v_valid_product AND id = v_valid_activity
        AND stage_id = v_valid_destination_stage AND discipline_id = v_valid_destination_discipline) THEN
    RAISE EXCEPTION 'A valid final derived schedule was rejected: %', v_result;
  END IF;

  -- Fixed explicit and partial D065 intervals do not expand to include moved child dates.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end)
      ORDER BY id), '[]') INTO v_fixed_dates_before
  FROM public.discipline_stages WHERE workspace_id = v_workspace AND product_id = v_fixed_product
    AND id IN (v_explicit_stage, v_partial_stage);
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_fixed_product
    AND discipline_id = v_fixed_source_discipline AND stage_id = v_explicit_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_fixed_product
    AND discipline_id = v_fixed_destination_discipline AND stage_id = v_partial_stage AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic fixed D065 reparent', true);
  v_result := public.move_schedule_item(v_workspace, v_fixed_product, v_actor, v_operation, 'activity',
    v_fixed_activity, (SELECT version FROM public.stage_activities WHERE id = v_fixed_activity),
    v_fixed_destination_discipline, v_partial_stage, jsonb_array_length(v_destination_order),
    v_source_order, v_destination_order);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end)
      ORDER BY id), '[]') INTO v_fixed_dates_after
  FROM public.discipline_stages WHERE workspace_id = v_workspace AND product_id = v_fixed_product
    AND id IN (v_explicit_stage, v_partial_stage);
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR v_fixed_dates_after IS DISTINCT FROM v_fixed_dates_before THEN
    RAISE EXCEPTION 'Explicit or partial stage dates changed during reparenting: %', v_result;
  END IF;

  -- Moving the sole dated child out would remove the linked stage's derived finish.
  SELECT id INTO STRICT v_root_boundary_child FROM public.stage_activities
  WHERE workspace_id = v_workspace AND product_id = v_root_product
    AND discipline_id = v_root_discipline AND stage_id = v_root_stage
    AND deleted_at IS NULL AND planned_end IS NOT NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_root_product
    AND discipline_id = v_root_discipline AND stage_id = v_root_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_root_product
    AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic blocked stage to root move', true);
  v_result := public.move_schedule_item(v_workspace, v_root_product, v_actor, v_operation, 'activity',
    v_root_boundary_child, (SELECT version FROM public.stage_activities WHERE id = v_root_boundary_child),
    NULL, NULL, jsonb_array_length(v_destination_order), v_source_order, v_destination_order);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_result#>>'{conflict,reason}' IS DISTINCT FROM 'missing_boundary' THEN
    RAISE EXCEPTION 'Stage-to-root move failed to protect its derived boundary: %', v_result;
  END IF;

  -- Moving a different activity from the root preserves the stage's valid finish.
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_root_product
    AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_root_product
    AND discipline_id = v_root_discipline AND stage_id = v_root_stage AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic root to stage move', true);
  v_result := public.move_schedule_item(v_workspace, v_root_product, v_actor, v_operation, 'activity',
    v_root_activity, (SELECT version FROM public.stage_activities WHERE id = v_root_activity),
    v_root_discipline, v_root_stage, jsonb_array_length(v_destination_order), v_source_order, v_destination_order);
  IF v_result->>'status' IS DISTINCT FROM 'moved' THEN RAISE EXCEPTION 'Root-to-stage move failed: %', v_result; END IF;

  -- A second logical operation for the same product is rejected within one transaction.
  -- The nested block must roll back any partial hierarchy, audit, and cursor writes.
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_valid_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_before FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_valid_product AND id = v_valid_activity;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_valid_product
    AND discipline_id = v_valid_destination_discipline AND stage_id = v_valid_destination_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_valid_product
    AND discipline_id = v_valid_source_discipline AND stage_id = v_valid_source_stage AND deleted_at IS NULL;
  BEGIN
    PERFORM set_config('jlproject.schedule_operation_id', v_second_operation::text, true),
      set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
      set_config('jlproject.schedule_justification', 'Synthetic second-operation rejection', true);
    PERFORM public.move_schedule_item(v_workspace, v_valid_product, v_actor, v_second_operation, 'activity',
      v_valid_activity, (v_item_before->>'version')::bigint, v_valid_source_discipline, v_valid_source_stage,
      jsonb_array_length(v_destination_order), v_source_order, v_destination_order);
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_error_state = RETURNED_SQLSTATE, v_error = MESSAGE_TEXT;
    IF v_error_state <> '23514' OR
       v_error <> 'A product transaction cannot contain multiple Living Schedule operations.' THEN
      RAISE;
    END IF;
    v_second_operation_rejected := true;
  END;
  IF NOT v_second_operation_rejected THEN
    RAISE EXCEPTION 'The second product operation was not rejected with SQLSTATE 23514.';
  END IF;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_valid_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_after FROM public.stage_activities AS activity
    WHERE workspace_id = v_workspace AND product_id = v_valid_product AND id = v_valid_activity;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before OR v_item_after IS DISTINCT FROM v_item_before THEN
    RAISE EXCEPTION 'Failed hierarchy movement left partial ancestry, order, or cursor changes.';
  END IF;

  -- An empty graph still permits an ordinary reparent operation.
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_source_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_empty_product
    AND discipline_id = v_empty_source_discipline AND stage_id = v_empty_source_stage AND deleted_at IS NULL;
  SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]') INTO v_destination_order
  FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_empty_product
    AND discipline_id = v_empty_destination_discipline AND stage_id = v_empty_destination_stage AND deleted_at IS NULL;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true),
    set_config('jlproject.schedule_justification', 'Synthetic empty graph reparent', true);
  v_result := public.move_schedule_item(v_workspace, v_empty_product, v_actor, v_operation, 'activity',
    v_empty_activity, (SELECT version FROM public.stage_activities WHERE id = v_empty_activity),
    v_empty_destination_discipline, v_empty_destination_stage, jsonb_array_length(v_destination_order),
    v_source_order, v_destination_order);
  IF v_result->>'status' IS DISTINCT FROM 'moved' THEN RAISE EXCEPTION 'Empty-graph reparent changed behavior: %', v_result; END IF;
END;
$$;

ROLLBACK;
