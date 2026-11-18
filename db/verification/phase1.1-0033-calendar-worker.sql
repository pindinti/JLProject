\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $calendar_test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_definition uuid;
  v_activity_a uuid;
  v_activity_b uuid;
  v_operation uuid := gen_random_uuid();
  v_reversal uuid := gen_random_uuid();
  v_calendar_before bigint;
  v_start date;
  v_result jsonb;
  v_history jsonb;
  v_source_links jsonb;
  v_operation_actor uuid;
  v_calendar_detail_links integer;
  v_calendar_detail_event_ids integer;
  v_calendar_reversal_links integer;
  v_calendar_reversal_event_ids integer;
  v_calendar_activity_links integer;
  v_calendar_activity_event_ids integer;
  v_reversal_of_links integer;
  v_reversal_of_event_ids integer;
  v_reason text := 'P1-0030 rollback-only calendar verification';
  v_code text := 'PC' || left(replace(gen_random_uuid()::text, '-', ''), 12);
BEGIN
  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    CROSS JOIN LATERAL generate_series(DATE '2030-01-07', DATE '2099-12-01', INTERVAL '7 days') AS candidate(day)
    WHERE membership.active AND membership.role = 'admin'
      AND NOT EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
        WHERE exception.workspace_id = membership.workspace_id AND exception.removed_at IS NULL
          AND exception.start_date <= candidate.day::date + 2
          AND exception.end_date >= candidate.day::date)
    ORDER BY membership.workspace_id, candidate.day
    LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Calendar integration requires a Development admin and a clear weekday range.';
  END IF;
  SELECT candidate.day::date INTO v_start
    FROM generate_series(DATE '2030-01-07', DATE '2099-12-01', INTERVAL '7 days') AS candidate(day)
    WHERE NOT EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
      WHERE exception.workspace_id = v_workspace AND exception.removed_at IS NULL
        AND exception.start_date <= candidate.day::date + 2
        AND exception.end_date >= candidate.day::date)
    ORDER BY candidate.day LIMIT 1;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_before;

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, 'P1-0030 calendar ' || gen_random_uuid()::text, v_actor, v_actor)
    RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, 'Calendar synthetic discipline', 'PCA', '#335577', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  v_result := jsonb_build_object('id', public.create_discipline_stage(
    v_workspace, v_product, v_discipline, v_actor, v_code, '#335577', 'Calendar synthetic stage', 0));
  v_stage := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Calendar activity A', NULL, v_start, v_start + 1, 0, NULL, 2, v_calendar_before);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Working-plan creation A failed.'; END IF;
  v_activity_a := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Calendar activity B', NULL, v_start, v_start + 1, 1, NULL, 2, v_calendar_before);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Working-plan creation B failed.'; END IF;
  v_activity_b := (v_result->>'id')::uuid;

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar_before, 'create', NULL, 'company_shutdown', NULL, NULL,
    'P1-0030 synthetic one-day closure', v_start + 1, v_start + 1);
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'version')::bigint <> v_calendar_before + 1 THEN
    RAISE EXCEPTION 'Rollback-only workspace calendar change failed: %', v_result;
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true);
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_operation,
    v_calendar_before + 1, v_reason, jsonb_build_array(
      jsonb_build_object('activityId', v_activity_a, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 1, 'startDate', v_start::text, 'currentEndDate', (v_start + 1)::text,
        'proposedEndDate', (v_start + 2)::text, 'workingDays', 2,
        'savedCalendarVersion', v_calendar_before),
      jsonb_build_object('activityId', v_activity_b, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 1, 'startDate', v_start::text, 'currentEndDate', (v_start + 1)::text,
        'proposedEndDate', (v_start + 2)::text, 'workingDays', 2,
        'savedCalendarVersion', v_calendar_before)));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::integer <> 2 THEN
    RAISE EXCEPTION 'Multi-activity reschedule failed: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
      CROSS JOIN LATERAL jsonb_array_elements(operation.source_operations) AS source(value)
      WHERE operation.operation_id = v_operation
        AND source.value->>'ledger' = 'calendar_reschedule_changes'
        AND source.value->>'kind' = 'audit_detail'
        AND source.value->>'operationId' = v_operation::text) <> 2 THEN
    RAISE EXCEPTION 'The reschedule batch ledger is incomplete.';
  END IF;

  -- Keep the same operation ID because apply+reverse are deliberately tested
  -- as one rollback-only transaction group; the reversal ledger retains its own ID.
  PERFORM set_config('jlproject.schedule_operation_type', 'calendar_reschedule_reversed', true);
  PERFORM set_config('jlproject.schedule_reversal_of', v_operation::text, true);
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_operation, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR (v_result->>'count')::integer <> 2 OR
     (SELECT count(*) FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
       CROSS JOIN LATERAL jsonb_array_elements(operation.source_operations) AS source(value)
       WHERE operation.operation_id = v_operation
         AND source.value->>'ledger' = 'calendar_reschedule_reversals'
         AND source.value->>'kind' = 'audit_detail'
         AND source.value->>'operationId' = v_reversal::text) <> 2 OR
     (SELECT count(*) FROM public.stage_activities WHERE id IN (v_activity_a, v_activity_b)
       AND planned_start = v_start AND planned_end = v_start + 1 AND version = 3) <> 2 THEN
    RAISE EXCEPTION 'Rollback-only calendar reversal did not restore the two activity intervals.';
  END IF;

  SELECT operation.events, operation.source_operations, operation.actor_id
    INTO v_history, v_source_links, v_operation_actor
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_calendar_detail_links, v_calendar_detail_event_ids
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'calendar_reschedule_changes'
      AND source.value->>'kind' = 'audit_detail'
      AND source.value->>'operationId' = v_operation::text;
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_calendar_reversal_links, v_calendar_reversal_event_ids
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'calendar_reschedule_reversals'
      AND source.value->>'kind' = 'audit_detail'
      AND source.value->>'operationId' = v_reversal::text;
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_calendar_activity_links, v_calendar_activity_event_ids
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'activity_date_changes'
      AND source.value->>'kind' = 'audit_detail';
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_reversal_of_links, v_reversal_of_event_ids
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'calendar_reschedule_changes'
      AND source.value->>'kind' = 'reversal_of'
      AND source.value->>'operationId' = v_operation::text;
  IF v_operation_actor IS DISTINCT FROM v_actor OR
     v_calendar_detail_links <> 2 OR v_calendar_detail_event_ids <> 2 OR
     v_calendar_reversal_links <> 2 OR v_calendar_reversal_event_ids <> 2 OR
     v_calendar_activity_links <> 4 OR v_calendar_activity_event_ids <> 4 OR
     v_reversal_of_links <> 2 OR v_reversal_of_event_ids <> 2 OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS calendar(value)
       WHERE calendar.value->>'ledger' = 'calendar_reschedule_changes'
         AND calendar.value->>'kind' = 'audit_detail'
         AND calendar.value->>'operationId' = v_operation::text
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS activity(value)
           WHERE activity.value->>'ledger' = 'activity_date_changes'
             AND activity.value->>'kind' = 'audit_detail'
             AND activity.value->>'operationId' = calendar.value->>'eventId'
             AND activity.value->>'eventId' = calendar.value->>'eventId')) OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS reversal(value)
       WHERE reversal.value->>'ledger' = 'calendar_reschedule_reversals'
         AND reversal.value->>'kind' = 'audit_detail'
         AND reversal.value->>'operationId' = v_reversal::text
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS activity(value)
           WHERE activity.value->>'ledger' = 'activity_date_changes'
             AND activity.value->>'kind' = 'audit_detail'
             AND activity.value->>'operationId' = reversal.value->>'eventId'
             AND activity.value->>'eventId' = reversal.value->>'eventId')) OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS reversal_of(value)
       WHERE reversal_of.value->>'ledger' = 'calendar_reschedule_changes'
         AND reversal_of.value->>'kind' = 'reversal_of'
         AND reversal_of.value->>'operationId' = v_operation::text
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS original(value)
           WHERE original.value->>'ledger' = 'calendar_reschedule_changes'
             AND original.value->>'kind' = 'audit_detail'
             AND original.value->>'operationId' = v_operation::text
             AND original.value->>'eventId' = reversal_of.value->>'eventId')) OR
     (SELECT count(*) FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100)) <> 1 OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor)) <> 1 THEN
    RAISE EXCEPTION 'Calendar audit links or exactly-once schedule version are incorrect.';
  END IF;
  IF public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL)->>'status'
       IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'Existing history read failed after calendar reschedule/reversal.';
  END IF;
END;
$calendar_test$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
