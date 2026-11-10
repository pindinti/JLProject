-- Run only on verified JLProject development with the limited Worker role.
-- All synthetic calendar and activity writes are rolled back.
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
  v_batch uuid := gen_random_uuid();
  v_result jsonb;
  v_reason text := 'Synthetic calendar reschedule verification';
  v_count bigint;
BEGIN
  IF current_user <> 'jlproject_worker' OR current_database() <> 'neondb' OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'INSERT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     NOT has_function_privilege(current_user,
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Limited-role privilege verification failed.';
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
  IF EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions
    WHERE workspace_id = v_workspace AND removed_at IS NULL
      AND start_date <= DATE '2030-01-09' AND end_date >= DATE '2030-01-07') THEN
    RAISE EXCEPTION 'Synthetic test dates overlap an existing exception.';
  END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic calendar test A ' || gen_random_uuid()::text,
    NULL, DATE '2030-01-07', DATE '2030-01-08', 999990, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'First synthetic activity creation failed.'; END IF;
  v_first := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic calendar test B ' || gen_random_uuid()::text,
    NULL, DATE '2030-01-07', DATE '2030-01-08', 999991, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Second synthetic activity creation failed.'; END IF;
  v_second := (v_result->>'id')::uuid;
  v_low := LEAST(v_first, v_second);
  v_high := GREATEST(v_first, v_second);

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback closure', DATE '2030-01-08', DATE '2030-01-08');
  IF v_result->>'status' <> 'created' OR (v_result->>'version')::bigint <> v_calendar + 1 THEN
    RAISE EXCEPTION 'Synthetic calendar change failed.';
  END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch,
    v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_high, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'updated' OR (v_result->>'count')::integer <> 1 THEN
    RAISE EXCEPTION 'Controlled reschedule failed.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
    AND planned_end = DATE '2030-01-09' AND planning_calendar_version = v_calendar + 1
    AND working_day_duration = 2 AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes WHERE activity_id = v_high
       AND new_end = DATE '2030-01-09' AND version_before = 1 AND version_after = 2
       AND reason = v_reason) THEN
    RAISE EXCEPTION 'Date persistence or immutable audit verification failed.';
  END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, gen_random_uuid(),
    gen_random_uuid(), v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'forbidden' THEN RAISE EXCEPTION 'Unknown actor was authorized.'; END IF;
  v_result := public.apply_calendar_reschedule(gen_random_uuid(), v_product, v_actor,
    gen_random_uuid(), v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'not_found' THEN RAISE EXCEPTION 'Foreign workspace was authorized.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 2, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-09', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'Stale activity version was accepted.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-08', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'invalid' THEN RAISE EXCEPTION 'Version-only proposal was applied.'; END IF;

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar + 1, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback closure', DATE '2030-01-09', DATE '2030-01-09');
  IF v_result->>'status' <> 'created' OR (v_result->>'version')::bigint <> v_calendar + 2 THEN
    RAISE EXCEPTION 'Second synthetic calendar change failed.';
  END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_calendar + 1, v_reason, jsonb_build_array(jsonb_build_object(
      'activityId', v_low, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
      'proposedEndDate', '2030-01-10', 'workingDays', 2,
      'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'stale_calendar' THEN RAISE EXCEPTION 'Stale calendar was accepted.'; END IF;

  -- Reusing the first batch ID makes the second row fail after the first row has changed.
  -- The exception subtransaction must undo both date and audit writes from that call.
  BEGIN
    PERFORM public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch,
      v_calendar + 2, v_reason, jsonb_build_array(
        jsonb_build_object('activityId', v_low, 'disciplineId', v_discipline,
          'stageId', v_stage, 'expectedVersion', 1, 'startDate', '2030-01-07',
          'currentEndDate', '2030-01-08', 'proposedEndDate', '2030-01-10',
          'workingDays', 2, 'savedCalendarVersion', v_calendar),
        jsonb_build_object('activityId', v_high, 'disciplineId', v_discipline,
          'stageId', v_stage, 'expectedVersion', 2, 'startDate', '2030-01-07',
          'currentEndDate', '2030-01-09', 'proposedEndDate', '2030-01-10',
          'workingDays', 2, 'savedCalendarVersion', v_calendar + 1)));
    RAISE EXCEPTION 'Expected audit collision did not occur.';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
    AND planned_end = DATE '2030-01-08' AND version = 1
    AND planning_calendar_version = v_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-09' AND version = 2
       AND planning_calendar_version = v_calendar + 1) THEN
    RAISE EXCEPTION 'Failed batch left a partial date change.';
  END IF;
  SELECT count(*) INTO v_count FROM public.activity_date_changes
    WHERE activity_id IN (v_low, v_high);
  IF v_count <> 1 THEN RAISE EXCEPTION 'Failed batch left partial audit history.'; END IF;
  RAISE NOTICE 'Synthetic permission, calendar, audit, concurrency, and rollback checks passed.';
END;
$$;

ROLLBACK;
