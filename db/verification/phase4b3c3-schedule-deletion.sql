-- Run only as jlproject_worker against an approved disposable Development child.
-- Owner-provisioned fixture requirements are listed in the phase checkpoint document.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_deletion_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'viewer', :'test_viewer',
  'linkedProduct', :'test_linked_product', 'linkedActivity', :'test_linked_activity',
  'linkedActivityDependency', :'test_linked_activity_dependency', 'linkedStage', :'test_linked_stage',
  'descendantProduct', :'test_descendant_product',
  'descendantDiscipline', :'test_descendant_discipline', 'descendantStage', :'test_descendant_stage',
  'descendantDependency', :'test_descendant_dependency', 'missingProduct', :'test_missing_product',
  'missingActivity', :'test_missing_activity', 'missingStage', :'test_missing_stage',
  'missingDependency', :'test_missing_dependency', 'validProduct', :'test_valid_product',
  'validActivity', :'test_valid_activity', 'validStage', :'test_valid_stage',
  'fixedProduct', :'test_fixed_product', 'explicitActivity', :'test_explicit_activity',
  'explicitStage', :'test_explicit_stage', 'partialActivity', :'test_partial_activity',
  'partialProduct', :'test_partial_product', 'partialStage', :'test_partial_stage', 'emptyProduct', :'test_empty_product',
  'emptyActivity', :'test_empty_activity', 'collisionOperation', :'test_late_colliding_operation')::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_deletion_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_viewer uuid := (v_fixture->>'viewer')::uuid;
  v_linked_product uuid := (v_fixture->>'linkedProduct')::uuid;
  v_linked_activity uuid := (v_fixture->>'linkedActivity')::uuid;
  v_linked_activity_dependency uuid := (v_fixture->>'linkedActivityDependency')::uuid;
  v_linked_stage uuid := (v_fixture->>'linkedStage')::uuid;
  v_descendant_product uuid := (v_fixture->>'descendantProduct')::uuid;
  v_descendant_discipline uuid := (v_fixture->>'descendantDiscipline')::uuid;
  v_descendant_stage uuid := (v_fixture->>'descendantStage')::uuid;
  v_descendant_dependency uuid := (v_fixture->>'descendantDependency')::uuid;
  v_missing_product uuid := (v_fixture->>'missingProduct')::uuid;
  v_missing_activity uuid := (v_fixture->>'missingActivity')::uuid;
  v_missing_stage uuid := (v_fixture->>'missingStage')::uuid;
  v_missing_dependency uuid := (v_fixture->>'missingDependency')::uuid;
  v_valid_product uuid := (v_fixture->>'validProduct')::uuid;
  v_valid_activity uuid := (v_fixture->>'validActivity')::uuid;
  v_valid_stage uuid := (v_fixture->>'validStage')::uuid;
  v_fixed_product uuid := (v_fixture->>'fixedProduct')::uuid;
  v_partial_product uuid := (v_fixture->>'partialProduct')::uuid;
  v_explicit_activity uuid := (v_fixture->>'explicitActivity')::uuid;
  v_explicit_stage uuid := (v_fixture->>'explicitStage')::uuid;
  v_partial_activity uuid := (v_fixture->>'partialActivity')::uuid;
  v_partial_stage uuid := (v_fixture->>'partialStage')::uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_activity uuid := (v_fixture->>'emptyActivity')::uuid;
  v_collision_operation uuid := (v_fixture->>'collisionOperation')::uuid;
  v_preview jsonb;
  v_result jsonb;
  v_fingerprint text;
  v_item_before jsonb;
  v_item_after jsonb;
  v_dates_before jsonb;
  v_dates_after jsonb;
  v_cursor_before jsonb;
  v_cursor_after jsonb;
  v_audit_before jsonb;
  v_audit_after jsonb;
  v_collision_constraint text;
  v_rejection record;
  v_observation integer;
  v_tree_state jsonb;
  v_tree_before jsonb;
  v_operation uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     has_function_privilege(current_user, 'public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege(current_user, 'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.product_schedule_dependencies', 'SELECT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'deleted_at', 'UPDATE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role = 'admin') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_viewer AND active AND role = 'viewer') THEN
    RAISE EXCEPTION 'Expected the preprovisioned Worker deletion fixture and private dependency guard.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
      AND product_id = v_missing_product AND id = v_missing_activity AND stage_id = v_missing_stage AND deleted_at IS NULL) OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_missing_product AND stage_id = v_missing_stage AND deleted_at IS NULL) <> 1 OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_missing_product AND id = v_missing_stage AND planned_start IS NULL AND planned_end IS NULL
       AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_valid_product AND id = v_valid_activity AND stage_id = v_valid_stage AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_valid_product AND id = v_valid_stage AND planned_start IS NULL AND planned_end IS NULL
       AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_fixed_product AND id = v_explicit_activity AND stage_id = v_explicit_stage AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_fixed_product AND id = v_explicit_stage AND planned_start IS NOT NULL
       AND planned_end IS NOT NULL AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
        AND product_id = v_partial_product AND id = v_partial_activity AND stage_id = v_partial_stage AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
        AND product_id = v_partial_product AND id = v_partial_stage AND
       ((planned_start IS NULL) <> (planned_end IS NULL)) AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_descendant_product AND id = v_descendant_stage
       AND discipline_id = v_descendant_discipline AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Owner-provisioned deletion scenarios do not match the documented boundary fixture.';
  END IF;

  -- A directly linked activity must be protected from deletion.
  SELECT to_jsonb(activity) INTO STRICT v_item_before FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_linked_product AND id = v_linked_activity;
  v_preview := public.preview_schedule_deletion(v_workspace, v_linked_product, v_actor, 'activity', v_linked_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_preview#>>'{conflict,reason}' IS DISTINCT FROM 'linked_endpoint' OR
     v_preview#>>'{conflict,dependencyId}' IS DISTINCT FROM v_linked_activity_dependency::text THEN
    RAISE EXCEPTION 'A directly linked activity was not blocked: %', v_preview;
  END IF;
  v_fingerprint := v_preview->>'fingerprint';
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic linked activity deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_linked_product, v_actor, v_operation,
    'activity', v_linked_activity, v_fingerprint, 'Synthetic linked activity deletion');
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' THEN
    RAISE EXCEPTION 'Confirmed linked activity deletion was not blocked: %', v_result;
  END IF;
  SELECT to_jsonb(activity) INTO STRICT v_item_after FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_linked_product AND id = v_linked_activity;
  IF v_item_after IS DISTINCT FROM v_item_before THEN RAISE EXCEPTION 'Linked activity changed despite rejection.'; END IF;

  -- The overlapping stage reports its linked child first. The separate product isolates direct stage linkage.
  FOR v_rejection IN
    SELECT * FROM (VALUES
      ('stage containing a linked activity', v_linked_product, 'stage', v_linked_stage,
        v_linked_activity_dependency, 'activity', v_linked_activity),
      ('directly linked stage', v_descendant_product, 'stage', v_descendant_stage,
        v_descendant_dependency, 'stage', v_descendant_stage),
      ('linked descendant', v_descendant_product, 'discipline', v_descendant_discipline,
        v_descendant_dependency, 'stage', v_descendant_stage)
    ) AS scenarios(label, product_id, target_kind, target_id, edge_id, endpoint_kind, endpoint_id)
  LOOP
    -- Compare every visible subtree row and the authorized audit and cursor before the fixture-wide rollback.
    FOR v_observation IN 1..2 LOOP
      SELECT jsonb_build_object(
        'disciplines', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM public.product_disciplines d
          WHERE d.workspace_id = v_workspace AND d.product_id = v_rejection.product_id),
        'stages', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM public.discipline_stages s
          WHERE s.workspace_id = v_workspace AND s.product_id = v_rejection.product_id),
        'activities', (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM public.stage_activities a
          WHERE a.workspace_id = v_workspace AND a.product_id = v_rejection.product_id),
        'audit', (SELECT jsonb_agg(to_jsonb(h) ORDER BY h.schedule_version)
          FROM public.list_product_schedule_operations(v_workspace, v_rejection.product_id, v_actor, NULL, 100) h),
        'cursor', (SELECT to_jsonb(c) FROM public.read_product_schedule_cursor(v_workspace, v_rejection.product_id, v_actor) c)
      ) INTO v_tree_state;
      IF v_observation = 1 THEN
        v_tree_before := v_tree_state;
        IF v_tree_before->'audit' = 'null'::jsonb OR v_tree_before->'cursor' = 'null'::jsonb THEN
          RAISE EXCEPTION 'Missing authorized audit or cursor for %.', v_rejection.label;
        END IF;
        v_preview := public.preview_schedule_deletion(v_workspace, v_rejection.product_id, v_actor,
          v_rejection.target_kind, v_rejection.target_id);
        IF v_preview->>'status' IS DISTINCT FROM 'dependency_conflict' OR
           v_preview#>>'{conflict,reason}' IS DISTINCT FROM 'linked_endpoint' OR
           v_preview#>>'{conflict,dependencyId}' IS DISTINCT FROM v_rejection.edge_id::text OR
           v_preview#>>'{conflict,linkedEndpoint,kind}' IS DISTINCT FROM v_rejection.endpoint_kind OR
           v_preview#>>'{conflict,linkedEndpoint,id}' IS DISTINCT FROM v_rejection.endpoint_id::text OR
           NOT COALESCE(v_preview->>'fingerprint' ~ '^[0-9a-f]{32}$', false) THEN
          RAISE EXCEPTION 'Unexpected deletion preview for %: %', v_rejection.label, v_preview;
        END IF;
        v_operation := gen_random_uuid();
        PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true),
          set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
          set_config('jlproject.schedule_justification', 'Synthetic linked subtree deletion', true);
        v_result := public.delete_schedule_subtree(v_workspace, v_rejection.product_id, v_actor, v_operation,
          v_rejection.target_kind, v_rejection.target_id, v_preview->>'fingerprint', 'Synthetic linked subtree deletion');
        IF v_result IS DISTINCT FROM v_preview THEN
          RAISE EXCEPTION 'Confirmed deletion for % did not return the preview conflict: %', v_rejection.label, v_result;
        END IF;
      ELSIF v_tree_state IS DISTINCT FROM v_tree_before THEN
        RAISE EXCEPTION 'Rejected deletion for % changed subtree rows, audit or cursor.', v_rejection.label;
      END IF;
    END LOOP;
  END LOOP;

  -- A stale fingerprint wins over a currently visible conflict, preserving optimistic concurrency.
  v_operation := gen_random_uuid();
  v_result := public.delete_schedule_subtree(v_workspace, v_missing_product, v_actor, v_operation,
    'activity', v_missing_activity, repeat('f', 32), 'Synthetic stale deletion request');
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'A stale deletion fingerprint was not rejected first: %', v_result;
  END IF;

  -- Removing the only child of a linked derived stage is blocked as a missing boundary.
  SELECT to_jsonb(activity) INTO STRICT v_item_before FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_missing_product AND id = v_missing_activity;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_missing_product, v_actor) AS cursor_state;
  v_preview := public.preview_schedule_deletion(v_workspace, v_missing_product, v_actor, 'activity', v_missing_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'dependency_conflict' OR
     v_preview#>>'{conflict,dependencyId}' IS DISTINCT FROM v_missing_dependency::text OR
     v_preview#>>'{conflict,reason}' IS DISTINCT FROM 'missing_boundary' THEN
    RAISE EXCEPTION 'Derived boundary loss was not reported: %', v_preview;
  END IF;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic missing boundary deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_missing_product, v_actor, v_operation,
    'activity', v_missing_activity, v_preview->>'fingerprint', 'Synthetic missing boundary deletion');
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' THEN
    RAISE EXCEPTION 'Derived boundary loss was not blocked: %', v_result;
  END IF;
  SELECT to_jsonb(activity) INTO STRICT v_item_after FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_missing_product AND id = v_missing_activity;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_missing_product, v_actor) AS cursor_state;
  IF v_item_after IS DISTINCT FROM v_item_before OR v_cursor_after IS DISTINCT FROM v_cursor_before THEN
    RAISE EXCEPTION 'Dependency-blocked deletion changed schedule or audit cursor.';
  END IF;

  -- An unlinked child may be deleted when the derived stage boundary remains safe.
  v_preview := public.preview_schedule_deletion(v_workspace, v_valid_product, v_actor, 'activity', v_valid_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Safe derived deletion preview failed: %', v_preview; END IF;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic valid derived deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_valid_product, v_actor, v_operation,
    'activity', v_valid_activity, v_preview->>'fingerprint', 'Synthetic valid derived deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR EXISTS (
      SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_valid_product
        AND id = v_valid_activity AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'A safe unlinked activity deletion failed: %', v_result;
  END IF;

  -- Complete explicit and partially explicit D065 intervals remain fixed during child deletion.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end)
      ORDER BY id), '[]') INTO v_dates_before
  FROM public.discipline_stages WHERE workspace_id = v_workspace
    AND ((product_id = v_fixed_product AND id = v_explicit_stage) OR
      (product_id = v_partial_product AND id = v_partial_stage));
  v_preview := public.preview_schedule_deletion(v_workspace, v_fixed_product, v_actor, 'activity', v_explicit_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Explicit-stage deletion was blocked: %', v_preview; END IF;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic explicit stage child deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_fixed_product, v_actor, v_operation,
    'activity', v_explicit_activity, v_preview->>'fingerprint', 'Synthetic explicit stage child deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN RAISE EXCEPTION 'Explicit-stage child delete failed: %', v_result; END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_partial_product, v_actor, 'activity', v_partial_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Partial-stage deletion was blocked: %', v_preview; END IF;
  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic partial stage child deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_partial_product, v_actor, v_operation,
    'activity', v_partial_activity, v_preview->>'fingerprint', 'Synthetic partial stage child deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN RAISE EXCEPTION 'Partial-stage child delete failed: %', v_result; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'start', planned_start, 'end', planned_end)
      ORDER BY id), '[]') INTO v_dates_after
  FROM public.discipline_stages WHERE workspace_id = v_workspace
    AND ((product_id = v_fixed_product AND id = v_explicit_stage) OR
      (product_id = v_partial_product AND id = v_partial_stage));
  IF v_dates_after IS DISTINCT FROM v_dates_before THEN RAISE EXCEPTION 'Fixed D065 stage dates changed.'; END IF;

  -- Viewer authorization and empty dependency graphs keep their existing outcomes.
  v_result := public.delete_schedule_subtree(v_workspace, v_empty_product, v_viewer, gen_random_uuid(),
    'activity', v_empty_activity, repeat('a', 32), 'Synthetic viewer deletion request');
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Viewer deletion was accepted.'; END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_empty_product, v_actor, 'activity', v_empty_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Empty graph preview changed behavior: %', v_preview; END IF;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_before
  FROM public.read_product_schedule_cursor(v_workspace, v_empty_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_before FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_empty_product AND id = v_empty_activity;
  SELECT jsonb_agg(to_jsonb(history) ORDER BY history.schedule_version) INTO v_audit_before
  FROM public.list_product_schedule_operations(v_workspace, v_empty_product, v_actor, NULL, 100) AS history;
  BEGIN
    PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
      set_config('jlproject.schedule_operation_id', v_collision_operation::text, true),
      set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
      set_config('jlproject.schedule_justification', 'Synthetic collision rollback check', true);
    v_result := public.delete_schedule_subtree(v_workspace, v_empty_product, v_actor, v_collision_operation,
      'activity', v_empty_activity, v_preview->>'fingerprint', 'Synthetic collision rollback check');
    RAISE EXCEPTION 'Expected a colliding deletion audit operation.';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_collision_constraint = CONSTRAINT_NAME;
    IF v_collision_constraint IS DISTINCT FROM 'schedule_deletion_events_pkey' THEN
      RAISE;
    END IF;
  END;
  SELECT to_jsonb(cursor_state) INTO STRICT v_cursor_after
  FROM public.read_product_schedule_cursor(v_workspace, v_empty_product, v_actor) AS cursor_state;
  SELECT to_jsonb(activity) INTO STRICT v_item_after FROM public.stage_activities AS activity
  WHERE workspace_id = v_workspace AND product_id = v_empty_product AND id = v_empty_activity;
  SELECT jsonb_agg(to_jsonb(history) ORDER BY history.schedule_version) INTO v_audit_after
  FROM public.list_product_schedule_operations(v_workspace, v_empty_product, v_actor, NULL, 100) AS history;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before OR v_item_after IS DISTINCT FROM v_item_before
     OR v_audit_before IS NULL OR v_audit_after IS DISTINCT FROM v_audit_before THEN
    RAISE EXCEPTION 'Failed deletion left partial schedule or audit writes.';
  END IF;

  v_operation := gen_random_uuid();
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic empty graph deletion', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_empty_product, v_actor, v_operation,
    'activity', v_empty_activity, v_preview->>'fingerprint', 'Synthetic empty graph deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN RAISE EXCEPTION 'Empty graph deletion failed: %', v_result; END IF;
END;
$$;

ROLLBACK;
