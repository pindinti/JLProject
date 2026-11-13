-- REL-03H: rollback-only calendar reschedule check on the approved rehearsal branch.
-- Connect as jlproject_worker with an explicit branch ID. Never use Production.
\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'dates', (SELECT md5(COALESCE(string_agg(
    a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
    COALESCE(a.planned_end::text, ''), E'\n' ORDER BY a.id), ''))
    FROM public.stage_activities AS a),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00_count', (SELECT count(*) FROM public.initial_schedule_revisions),
  'r00', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r),
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events)
) AS baseline
\gset rel03h_
ROLLBACK;

SELECT 1 / CASE WHEN (:'rel03h_baseline'::jsonb->>'products')::bigint = 5
  AND (:'rel03h_baseline'::jsonb->>'stages')::bigint = 40
  AND (:'rel03h_baseline'::jsonb->>'activities')::bigint = 73
  AND (:'rel03h_baseline'::jsonb->>'date_audits')::bigint = 3
  AND (:'rel03h_baseline'::jsonb->>'r00_count')::bigint = 1
  THEN 1 ELSE 0 END AS reported_baseline_counts_match;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_discipline uuid;
  v_definition uuid;
  v_stage uuid;
  v_first uuid;
  v_second uuid;
  v_low uuid;
  v_high uuid;
  v_old_calendar bigint;
  v_batch uuid := gen_random_uuid();
  v_result jsonb;
  v_low_proposal jsonb;
  v_high_proposal jsonb;
  v_collision text;
  v_caught boolean := false;
  v_reason text := 'REL03H synthetic calendar reschedule';
  v_marker text := replace(gen_random_uuid()::text, '-', '');
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.change_workspace_calendar(uuid,uuid,uuid,bigint,text,uuid,text,text,text,text,date,date)',
       'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)',
       'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)',
       'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') THEN
    RAISE EXCEPTION 'REL-03H requires the reviewed limited Worker role.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03H synthetic ') THEN
    RAISE EXCEPTION 'REL-03H synthetic marker already exists; stop.';
  END IF;

  -- Use an existing administrator only as the authorized actor and FK identity.
  -- Select a workspace without an active exception over the fixed test dates.
  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.workspace_calendar_exceptions AS e
    WHERE e.workspace_id = m.workspace_id AND e.removed_at IS NULL
      AND e.start_date <= DATE '2030-01-10' AND e.end_date >= DATE '2030-01-07'
  ) ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN
    RAISE EXCEPTION 'REL-03H needs an active admin and clear test-date range.';
  END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_old_calendar;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
  VALUES (v_workspace, 'REL03H synthetic ' || v_marker, v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'REL03H discipline', 'R3H', '#556677', 0,
          v_actor, v_actor) RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R3H' || left(v_marker, 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition,
          'REL03H stage', 0, v_actor, v_actor) RETURNING id INTO v_stage;

  -- 7 January 2030 is Monday; 8 January is Tuesday. With two working days,
  -- the initial end is 8 January; closing that Tuesday moves it to Wednesday.
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'REL03H activity A', NULL,
    DATE '2030-01-07', DATE '2030-01-08', 0, NULL, 2, v_old_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'First plan creation failed.'; END IF;
  v_first := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'REL03H activity B', NULL,
    DATE '2030-01-07', DATE '2030-01-08', 1, NULL, 2, v_old_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Second plan creation failed.'; END IF;
  v_second := (v_result->>'id')::uuid;
  v_low := LEAST(v_first, v_second);
  v_high := GREATEST(v_first, v_second);
  IF (SELECT count(*) FROM public.stage_activities WHERE id IN (v_low, v_high)
      AND planning_mode = 'working_days' AND working_day_duration = 2
      AND planning_calendar_version = v_old_calendar AND version = 1
      AND planned_start = DATE '2030-01-07'
      AND planned_end = DATE '2030-01-08') <> 2 THEN
    RAISE EXCEPTION 'Authorized working plans were not stored correctly.';
  END IF;

  v_result := public.change_workspace_calendar(v_workspace, v_actor,
    gen_random_uuid(), v_old_calendar, 'create', NULL, 'company_shutdown',
    NULL, NULL, 'REL03H rollback-only closure',
    DATE '2030-01-08', DATE '2030-01-08');
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'version')::bigint IS DISTINCT FROM v_old_calendar + 1 OR
     (SELECT count(*) FROM public.workspace_calendar_events
      WHERE workspace_id = v_workspace AND calendar_version = v_old_calendar + 1) <> 1 THEN
    RAISE EXCEPTION 'Authorized calendar event/version was not created.';
  END IF;

  v_low_proposal := jsonb_build_object('activityId', v_low,
    'disciplineId', v_discipline, 'stageId', v_stage, 'expectedVersion', 1,
    'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
    'proposedEndDate', '2030-01-09', 'workingDays', 2,
    'savedCalendarVersion', v_old_calendar);
  v_high_proposal := v_low_proposal || jsonb_build_object('activityId', v_high);
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    v_batch, v_old_calendar + 1, v_reason, jsonb_build_array(v_high_proposal));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::integer IS DISTINCT FROM 1 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_start = DATE '2030-01-07' AND planned_end = DATE '2030-01-09'
       AND planning_mode = 'working_days' AND working_day_duration = 2
       AND planning_calendar_version = v_old_calendar + 1 AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE activity_id = v_high AND actor_id = v_actor
         AND previous_start = DATE '2030-01-07'
         AND previous_end = DATE '2030-01-08'
         AND new_start = DATE '2030-01-07' AND new_end = DATE '2030-01-09'
         AND version_before = 1 AND version_after = 2 AND reason = v_reason) OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high)) <> 1 THEN
    RAISE EXCEPTION 'Successful reschedule, version, or date audit differs.';
  END IF;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product,
    gen_random_uuid(), gen_random_uuid(), v_old_calendar + 1,
    v_reason, jsonb_build_array(v_low_proposal));
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Unknown actor accepted.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_old_calendar + 1, v_reason,
    jsonb_build_array(v_low_proposal || jsonb_build_object('expectedVersion', 2)));
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'Stale version accepted.'; END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_old_calendar + 2, v_reason, jsonb_build_array(v_low_proposal));
  IF v_result->>'status' IS DISTINCT FROM 'stale_calendar' THEN
    RAISE EXCEPTION 'Future calendar version accepted.';
  END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), v_old_calendar + 1, v_reason,
    jsonb_build_array(v_low_proposal ||
      jsonb_build_object('proposedEndDate', '2030-01-08')));
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN RAISE EXCEPTION 'No-op proposal accepted.'; END IF;

  -- A second closure makes Thursday the two-day end for both saved plans.
  v_result := public.change_workspace_calendar(v_workspace, v_actor,
    gen_random_uuid(), v_old_calendar + 1, 'create', NULL, 'company_shutdown',
    NULL, NULL, 'REL03H rollback-only second closure',
    DATE '2030-01-09', DATE '2030-01-09');
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'version')::bigint IS DISTINCT FROM v_old_calendar + 2 THEN
    RAISE EXCEPTION 'Second calendar version was not created.';
  END IF;
  v_low_proposal := v_low_proposal ||
    jsonb_build_object('proposedEndDate', '2030-01-10');
  v_high_proposal := v_high_proposal || jsonb_build_object(
    'expectedVersion', 2, 'currentEndDate', '2030-01-09',
    'proposedEndDate', '2030-01-10',
    'savedCalendarVersion', v_old_calendar + 1);

  -- The first row can update; the second collides with the existing
  -- (batch_operation_id, activity_id) ledger key. The subtransaction must
  -- undo the first row's date and audit changes as well as the second row's.
  BEGIN
    PERFORM public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
      v_batch, v_old_calendar + 2, v_reason,
      jsonb_build_array(v_low_proposal, v_high_proposal));
    RAISE EXCEPTION 'Expected ledger collision did not occur.';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_collision = CONSTRAINT_NAME;
    IF v_collision IS DISTINCT FROM 'calendar_reschedule_one_activity_per_batch' THEN RAISE; END IF;
    v_caught := true;
  END;
  IF NOT v_caught OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
       AND planned_end = DATE '2030-01-08' AND version = 1
       AND planning_calendar_version = v_old_calendar) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-09' AND version = 2
       AND planning_calendar_version = v_old_calendar + 1) OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high)) <> 1 THEN
    RAISE EXCEPTION 'Failed two-proposal batch left partial changes.';
  END IF;
  RAISE NOTICE 'REL-03H planning, calendar, reschedule, audit, denial, and atomicity assertions passed.';
END;
$test$;

-- Check original activities and R00 while synthetic writes are still visible.
WITH original_activities AS (
  SELECT a.id, a.planned_start, a.planned_end
  FROM public.stage_activities AS a
  JOIN public.products AS p ON p.id = a.product_id
  WHERE left(p.name, 17) <> 'REL03H synthetic '
), original_state AS (
  SELECT (SELECT count(*) FROM original_activities) AS activity_count,
    (SELECT md5(COALESCE(string_agg(
      id::text || '|' || COALESCE(planned_start::text, '') || '|' ||
      COALESCE(planned_end::text, ''), E'\n' ORDER BY id), ''))
      FROM original_activities) AS date_fingerprint,
    (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r) AS r00_fingerprint
)
SELECT 1 / CASE WHEN activity_count = 73
  AND date_fingerprint = (:'rel03h_baseline'::jsonb->>'dates')
  AND r00_fingerprint = (:'rel03h_baseline'::jsonb->>'r00')
  THEN 1 ELSE 0 END AS original_dates_and_r00_unchanged
FROM original_state;

ROLLBACK;

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
WITH after_state AS (
  SELECT jsonb_build_object(
    'products', (SELECT count(*) FROM public.products),
    'stages', (SELECT count(*) FROM public.discipline_stages),
    'activities', (SELECT count(*) FROM public.stage_activities),
    'dates', (SELECT md5(COALESCE(string_agg(
      a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
      COALESCE(a.planned_end::text, ''), E'\n' ORDER BY a.id), ''))
      FROM public.stage_activities AS a),
    'date_audits', (SELECT count(*) FROM public.activity_date_changes),
    'r00_count', (SELECT count(*) FROM public.initial_schedule_revisions),
    'r00', (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r),
    'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
    'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
    'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events)
  ) AS value
)
SELECT 1 / CASE WHEN value = :'rel03h_baseline'::jsonb AND NOT EXISTS (
  SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03H synthetic '
) THEN 1 ELSE 0 END AS rollback_and_baseline_unchanged
FROM after_state;
ROLLBACK;
