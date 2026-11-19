\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $clone_test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_source uuid;
  v_clone uuid;
  v_discipline uuid;
  v_stage uuid;
  v_partial_stage uuid;
  v_root uuid;
  v_stage_activity uuid;
  v_clone_stage uuid;
  v_result jsonb;
  v_operation uuid := gen_random_uuid();
  v_code text := 'C35' || left(replace(gen_random_uuid()::text, '-', ''), 10);
  v_calendar_version bigint;
  v_source_fingerprint text;
  v_duplicate_name text := 'P2.1 clone ' || gen_random_uuid()::text;
  v_reason text := 'Rollback-only clone planning metadata verification';
BEGIN
  SELECT workspace_id, auth_user_id INTO v_workspace, v_actor
    FROM public.workspace_memberships WHERE active AND role = 'admin'
    ORDER BY workspace_id, auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'No active Development administrator is available.'; END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_version;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, 'P2.1 source ' || gen_random_uuid()::text, v_actor, v_actor)
    RETURNING id INTO v_source;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_source, 'Synthetic discipline', 'P35', '#335577', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  PERFORM set_config('jlproject.schedule_operation_type', 'stage_created_with_dates', true);
  v_stage := public.create_discipline_stage_with_dates(v_workspace, v_source, v_discipline,
    v_actor, v_operation, v_code, '#335577', 'Full stage', 0,
    DATE '2030-02-02', DATE '2030-02-06', v_reason)::uuid;
  v_partial_stage := public.create_discipline_stage_with_dates(v_workspace, v_source, v_discipline,
    v_actor, v_operation, v_code || 'P', '#335577', 'Partial stage', 1,
    DATE '2030-05-10', NULL, v_reason)::uuid;
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_source,
    v_discipline, v_stage, v_actor, 'Stage working activity', NULL,
    DATE '2030-02-02', DATE '2030-02-04', 0, NULL, 3, v_calendar_version);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Stage fixture failed: %', v_result; END IF;
  v_stage_activity := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_source,
    NULL, NULL, v_actor, 'Root working activity', NULL,
    DATE '2030-03-01', DATE '2030-03-05', 0, NULL, 3, v_calendar_version);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Root fixture failed: %', v_result; END IF;
  v_root := (v_result->>'id')::uuid;
  SELECT md5(to_jsonb(product)::text) INTO v_source_fingerprint
    FROM public.products AS product WHERE id = v_source;
  PERFORM set_config('jlproject.schedule_operation_type', 'product_cloned', true);
  v_result := public.clone_product(v_workspace, v_source, v_actor, v_duplicate_name);
  IF v_result->>'status' <> 'cloned' OR
     v_result->'product'->>'planningClassification' <> 'em_estudo' THEN
    RAISE EXCEPTION 'Product clone failed: %', v_result;
  END IF;
  v_clone := (v_result->'product'->>'id')::uuid;
  SELECT id INTO v_clone_stage FROM public.discipline_stages
    WHERE product_id = v_clone AND display_name = 'Full stage';
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities AS copy
      WHERE copy.product_id = v_clone AND copy.name = 'Stage working activity'
        AND copy.id <> v_stage_activity AND copy.planning_mode = 'working_days'
        AND copy.working_day_duration = 3 AND copy.planning_calendar_version = v_calendar_version
        AND copy.planned_start = DATE '2030-02-02' AND copy.planned_end = DATE '2030-02-04') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS copy
      WHERE copy.product_id = v_clone AND copy.name = 'Root working activity'
        AND copy.id <> v_root AND copy.stage_id IS NULL AND copy.planning_mode = 'working_days'
        AND copy.working_day_duration = 3 AND copy.planning_calendar_version = v_calendar_version) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE product_id = v_clone AND planned_start = DATE '2030-02-02'
         AND planned_end = DATE '2030-02-06') OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE product_id = v_clone AND planned_start = DATE '2030-05-10'
         AND planned_end IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions AS revision
       CROSS JOIN LATERAL jsonb_array_elements(revision.snapshot->'disciplines') AS discipline(value)
       CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage(value)
       CROSS JOIN LATERAL jsonb_array_elements(stage.value->'activities') AS activity(value)
       WHERE revision.product_id = v_clone AND revision.label = 'R00'
         AND activity.value->>'planningMode' = 'working_days'
         AND activity.value->>'workingDayDuration' = '3'
         AND activity.value->>'planningCalendarVersion' = v_calendar_version::text) OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions AS revision
       CROSS JOIN LATERAL jsonb_array_elements(revision.snapshot->'disciplines') AS discipline(value)
       CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage(value)
       WHERE revision.product_id = v_clone AND revision.label = 'R00'
         AND stage.value->>'plannedStart' = '2030-05-10'
         AND stage.value->>'plannedEnd' IS NULL) OR
     (SELECT md5(to_jsonb(product)::text) FROM public.products AS product WHERE id = v_source)
       <> v_source_fingerprint THEN
    RAISE EXCEPTION 'Clone planning metadata, stage dates, R00, or source integrity failed.';
  END IF;
  IF has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Clone migration broadened runtime privileges.';
  END IF;
  IF (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_clone, v_actor))
       IS DISTINCT FROM 1 OR
     (SELECT count(*) FROM public.list_product_schedule_operations(v_workspace, v_clone, v_actor, NULL, 2)) <> 1 OR
     NOT EXISTS (SELECT 1
       FROM public.list_product_schedule_operations(v_workspace, v_clone, v_actor, NULL, 2) AS operation
       CROSS JOIN LATERAL jsonb_array_elements(operation.events) AS event(value)
       WHERE operation.schedule_version = 1 AND operation.operation_type = 'product_cloned'
         AND operation.actor_id = v_actor AND event.value->>'entityType' = 'stage_activities') THEN
    RAISE EXCEPTION 'Clone audit/version grouping failed.';
  END IF;
  BEGIN
    PERFORM public.clone_stage_activity(v_workspace, v_source, v_clone,
      gen_random_uuid(), v_stage_activity, v_discipline, v_clone_stage);
    RAISE EXCEPTION 'Unauthorized helper call succeeded.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  v_result := public.clone_product(v_workspace, v_source, v_actor, v_duplicate_name);
  IF v_result->>'status' IS DISTINCT FROM 'duplicate' OR
     (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace
       AND name = v_duplicate_name) <> 1 OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_clone, v_actor))
       IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Rejected duplicate clone changed data or audit state.';
  END IF;
END;
$clone_test$;

ROLLBACK;
