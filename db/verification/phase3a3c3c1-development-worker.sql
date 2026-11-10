-- Run only with the limited Worker role on verified JLProject development.
-- Every synthetic write in this file is rolled back.
BEGIN;

DO $$
DECLARE
  v_workspace uuid;
  v_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_actor uuid;
  v_calendar bigint;
  v_first uuid;
  v_second uuid;
  v_low uuid;
  v_high uuid;
  v_first_batch uuid := gen_random_uuid();
  v_second_batch uuid := gen_random_uuid();
  v_third_batch uuid := gen_random_uuid();
  v_first_reversal uuid := gen_random_uuid();
  v_second_reversal uuid := gen_random_uuid();
  v_result jsonb;
  v_count bigint;
  v_r00_before text;
  v_constraint text;
  v_reason text := 'Synthetic audited calendar reversal verification';
BEGIN
  IF current_user <> 'jlproject_worker' OR current_database() <> 'neondb' OR
     NOT has_function_privilege(current_user,
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'INSERT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'UPDATE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'DELETE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Limited Worker reversal privileges are incorrect.';
  END IF;

  SELECT p.workspace_id, p.id, s.discipline_id, s.id, m.auth_user_id
    INTO v_workspace, v_product, v_discipline, v_stage, v_actor
    FROM public.products AS p
    JOIN public.discipline_stages AS s ON s.workspace_id = p.workspace_id AND s.product_id = p.id
    JOIN public.workspace_memberships AS m ON m.workspace_id = p.workspace_id
      AND m.active = true AND m.role = 'admin'
    WHERE p.name LIKE 'Synthetic 1C2 %' AND p.active = true
    ORDER BY p.name, s.id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'Synthetic development fixture is missing.'; END IF;
  SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, '|' ORDER BY r.id), ''))
    INTO v_r00_before FROM public.initial_schedule_revisions AS r
    WHERE workspace_id = v_workspace;
  IF EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions
    WHERE workspace_id = v_workspace AND removed_at IS NULL
      AND start_date <= DATE '2030-01-10' AND end_date >= DATE '2030-01-07') THEN
    RAISE EXCEPTION 'Synthetic test dates overlap an existing exception.';
  END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic reversal A ' || gen_random_uuid()::text,
    NULL, DATE '2030-01-07', DATE '2030-01-08', 999990, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'First synthetic activity failed.'; END IF;
  v_first := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic reversal B ' || gen_random_uuid()::text,
    NULL, DATE '2030-01-07', DATE '2030-01-08', 999991, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Second synthetic activity failed.'; END IF;
  v_second := (v_result->>'id')::uuid;
  v_low := LEAST(v_first, v_second);
  v_high := GREATEST(v_first, v_second);

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback closure', DATE '2030-01-08', DATE '2030-01-08');
  IF v_result->>'status' <> 'created' OR (v_result->>'version')::bigint <> v_calendar + 1 THEN
    RAISE EXCEPTION 'Synthetic calendar exception failed.';
  END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_first_batch,
    v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_high, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'First reschedule failed.'; END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, v_first_reversal, v_reason);
  IF v_result->>'status' <> 'reversed' OR (v_result->>'count')::integer <> 1 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-08' AND planning_calendar_version = v_calendar
       AND working_day_duration = 2 AND version = 3) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes WHERE activity_id = v_high
       AND previous_end = DATE '2030-01-09' AND new_end = DATE '2030-01-08'
       AND version_before = 2 AND version_after = 3 AND reason = v_reason) THEN
    RAISE EXCEPTION 'Compensating reversal or immutable date audit failed.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' <> 'already_reversed' THEN RAISE EXCEPTION 'Duplicate reversal was accepted.'; END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, gen_random_uuid(),
    v_first_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' <> 'forbidden' THEN RAISE EXCEPTION 'Unknown actor was authorized.'; END IF;
  v_result := public.reverse_calendar_reschedule(gen_random_uuid(), v_product, v_actor,
    v_first_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' <> 'not_found' THEN RAISE EXCEPTION 'Foreign workspace was authorized.'; END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_second_batch,
    v_calendar + 1, v_reason, jsonb_build_array(
      jsonb_build_object('activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
        'proposedEndDate', '2030-01-09', 'workingDays', 2, 'savedCalendarVersion', v_calendar),
      jsonb_build_object('activityId', v_high, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 3, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
        'proposedEndDate', '2030-01-09', 'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'updated' OR (v_result->>'count')::integer <> 2 THEN
    RAISE EXCEPTION 'Second reschedule batch failed.';
  END IF;

  -- The first activity update must roll back when the second audit insert collides.
  BEGIN
    PERFORM public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
      v_second_batch, v_first_reversal, v_reason);
    RAISE EXCEPTION 'Expected reversal audit collision did not occur.';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint <> 'calendar_reversal_one_activity_per_batch' THEN RAISE; END IF;
  END;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
    AND planned_end = DATE '2030-01-09' AND version = 2
    AND planning_calendar_version = v_calendar + 1) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-09' AND version = 4
       AND planning_calendar_version = v_calendar + 1) THEN
    RAISE EXCEPTION 'Failed reversal left partial activity changes.';
  END IF;
  SELECT count(*) INTO v_count FROM public.activity_date_changes WHERE activity_id IN (v_low, v_high);
  IF v_count <> 4 THEN RAISE EXCEPTION 'Failed reversal left partial date audit.'; END IF;

  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_second_batch, v_second_reversal, v_reason);
  IF v_result->>'status' <> 'reversed' OR (v_result->>'count')::integer <> 2 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
       AND planned_end = DATE '2030-01-08' AND planning_calendar_version = v_calendar
       AND version = 3) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-08' AND planning_calendar_version = v_calendar
       AND version = 5) THEN
    RAISE EXCEPTION 'Atomic two-activity reversal failed.';
  END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_third_batch,
    v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_high, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 5, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'Third reschedule failed.'; END IF;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline, v_stage,
    v_high, v_actor, gen_random_uuid(), 'working_days', DATE '2030-01-07',
    DATE '2030-01-10', 2, v_calendar + 1, v_reason, 6);
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'Synthetic concurrent edit failed.'; END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_third_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'Modified activity was reversed.'; END IF;
  IF (SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, '|' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r WHERE workspace_id = v_workspace)
     IS DISTINCT FROM v_r00_before THEN
    RAISE EXCEPTION 'R00 snapshot changed during reversal checks.';
  END IF;

  RAISE NOTICE 'Synthetic reversal, audit, duplicate, stale, permissions, and atomic rollback checks passed.';
END;
$$;

ROLLBACK;
