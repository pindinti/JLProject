-- Run as the limited Worker only on an approved disposable Development child with the documented synthetic fixture.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_calendar_apply_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'product', :'test_product', 'actor', :'test_actor', 'parent', :'test_parent',
  'first', :'test_first_child', 'second', :'test_second_child', 'unlinked', :'test_unlinked_activity',
  'emptyProduct', :'test_empty_product', 'emptyActivity', :'test_empty_activity', 'calendar', :'test_calendar_version')::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_calendar_apply_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_product uuid := (v_fixture->>'product')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_parent uuid := (v_fixture->>'parent')::uuid;
  v_first uuid := (v_fixture->>'first')::uuid;
  v_second uuid := (v_fixture->>'second')::uuid;
  v_unlinked uuid := (v_fixture->>'unlinked')::uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_activity uuid := (v_fixture->>'emptyActivity')::uuid;
  v_calendar bigint := (v_fixture->>'calendar')::bigint;
  v_reason constant text := 'Synthetic calendar apply dependency verification';
  v_batch uuid := gen_random_uuid();
  v_empty_batch uuid := gen_random_uuid();
  v_good jsonb;
  v_late jsonb;
  v_empty jsonb;
  v_result jsonb;
  v_cursor jsonb;
  v_after jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR v_unlinked >= v_first
     OR NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = v_workspace AND name = 'Synthetic Phase 4B.3b.1 workspace')
     OR NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND id = v_product
        AND name = 'Synthetic Phase 4B.3b.1 linked product')
     OR NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND id = v_empty_product
        AND name = 'Synthetic Phase 4B.3b.1 empty product') THEN RAISE EXCEPTION 'Expected the synthetic calendar apply fixture.'; END IF;
  IF has_function_privilege(current_user, 'public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege(current_user,
      'public.write_reviewed_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'The Worker can bypass the calendar apply entry point.';
  END IF;

  SELECT jsonb_agg(jsonb_build_object('activityId', a.id, 'disciplineId', a.discipline_id, 'stageId', a.stage_id,
    'expectedVersion', a.version, 'startDate', a.planned_start, 'currentEndDate', a.planned_end,
    'proposedEndDate', desired.finish, 'workingDays', a.working_day_duration,
    'savedCalendarVersion', a.planning_calendar_version) ORDER BY desired.sequence)
  INTO v_good FROM public.stage_activities AS a
    JOIN (VALUES (v_first, DATE '2026-11-09', 1), (v_second, DATE '2026-11-16', 2)) AS desired(id, finish, sequence) ON a.id = desired.id
    WHERE a.workspace_id = v_workspace AND a.product_id = v_product AND a.stage_id = v_parent;
  IF jsonb_array_length(v_good) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Missing synthetic linked activities.'; END IF;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS saved_cursor;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_batch::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true),
    set_config('jlproject.schedule_justification', v_reason, true);

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch, v_calendar - 1, v_reason, v_good);
  IF v_result->>'status' IS DISTINCT FROM 'stale_calendar' THEN RAISE EXCEPTION 'Stale calendar was accepted.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch, v_calendar, v_reason,
    jsonb_set(v_good, '{1,expectedVersion}', 'null'));
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'A null expected version bypassed the stale check.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch, v_calendar, v_reason,
    jsonb_set(v_good, '{1,proposedEndDate}', '"2026-11-19"'));
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict'
     OR v_result#>>'{conflict,predecessor,id}' IS DISTINCT FROM v_parent::text
     OR v_result#>>'{conflict,after,predecessorFinish}' IS DISTINCT FROM '2026-11-19' THEN
    RAISE EXCEPTION 'The final derived-stage conflict was not detected.';
  END IF;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_after FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS saved_cursor;
  IF v_after IS DISTINCT FROM v_cursor OR NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_first AND planned_end = DATE '2026-11-18') THEN RAISE EXCEPTION 'Rejected batch changed schedule state.'; END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch, v_calendar, v_reason, v_good);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'The complete improving batch was rejected.';
  END IF;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_after FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS saved_cursor;
  IF (v_after->>'schedule_version')::bigint IS DISTINCT FROM (v_cursor->>'schedule_version')::bigint + 1 THEN
    RAISE EXCEPTION 'The successful batch did not advance the schedule cursor once.';
  END IF;

  SELECT jsonb_build_array(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-16', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version)) INTO STRICT v_empty FROM public.stage_activities
    WHERE workspace_id = v_workspace AND product_id = v_empty_product AND id = v_empty_activity;
  PERFORM set_config('jlproject.schedule_operation_id', v_empty_batch::text, true);
  v_result := public.apply_calendar_reschedule(v_workspace, v_empty_product, v_actor, v_empty_batch, v_calendar, v_reason, v_empty);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'The empty graph changed calendar apply behavior.'; END IF;

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(), v_calendar, 'create', NULL,
    'company_shutdown', NULL, NULL, 'Synthetic extra closure', DATE '2026-11-09', DATE '2026-11-09');
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Expected the synthetic calendar to advance.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-16', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version)) INTO v_late FROM public.stage_activities
    WHERE workspace_id = v_workspace AND product_id = v_product AND id IN (v_unlinked, v_first);
  PERFORM set_config('jlproject.schedule_operation_id', v_batch::text, true);
  BEGIN
    -- The unlinked row sorts first. The first child's existing batch audit forces the later insert to fail.
    PERFORM public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch, v_calendar + 1, v_reason, v_late);
    RAISE EXCEPTION 'Expected a late calendar audit collision.';
  EXCEPTION WHEN unique_violation THEN
    IF SQLERRM NOT LIKE '%calendar_reschedule_one_activity_per_batch%' THEN RAISE; END IF;
  END;
  SELECT to_jsonb(saved_cursor) INTO STRICT v_cursor FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS saved_cursor;
  IF v_cursor IS DISTINCT FROM v_after OR NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_unlinked AND planned_end = DATE '2026-11-09') THEN
    RAISE EXCEPTION 'Late batch failure left a partial date or cursor change.';
  END IF;
END;
$$;

ROLLBACK;
