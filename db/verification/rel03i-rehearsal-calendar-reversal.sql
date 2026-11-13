-- REL-03I: rollback-only reversal verification for the approved rehearsal branch.
-- Connect as jlproject_worker with an explicit branch ID. No real activity is edited.
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
\gset rel03i_
ROLLBACK;

SELECT 1 / CASE WHEN (:'rel03i_baseline'::jsonb->>'products')::bigint = 5
  AND (:'rel03i_baseline'::jsonb->>'stages')::bigint = 40
  AND (:'rel03i_baseline'::jsonb->>'activities')::bigint = 73
  AND (:'rel03i_baseline'::jsonb->>'date_audits')::bigint = 3
  AND (:'rel03i_baseline'::jsonb->>'r00_count')::bigint = 1
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
  v_calendar bigint;
  v_first_batch uuid := gen_random_uuid();
  v_second_batch uuid := gen_random_uuid();
  v_first_reversal uuid := gen_random_uuid();
  v_second_reversal uuid := gen_random_uuid();
  v_result jsonb;
  v_low_proposal jsonb;
  v_high_proposal jsonb;
  v_constraint text;
  v_collision_caught boolean := false;
  v_stale_caught boolean := false;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_apply_reason text := 'REL03I synthetic calendar apply';
  v_reverse_reason text := 'REL03I synthetic calendar reversal';
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
     NOT has_function_privilege(current_user,
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)',
       'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'INSERT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'UPDATE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'DELETE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') THEN
    RAISE EXCEPTION 'REL-03I requires the reviewed limited Worker role.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03I synthetic ') THEN
    RAISE EXCEPTION 'REL-03I synthetic marker already exists; stop.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
      AND c.relname IN ('products', 'product_disciplines', 'stage_definitions',
        'discipline_stages', 'stage_activities', 'activity_date_changes',
        'workspace_calendar_versions', 'workspace_calendar_exceptions',
        'workspace_calendar_events', 'calendar_reschedule_changes',
        'calendar_reschedule_reversals')
      AND ((t.tgtype & 4) <> 0 OR
        ((t.tgtype & 16) <> 0 AND c.relname IN
          ('stage_activities', 'workspace_calendar_versions',
           'workspace_calendar_exceptions') AND
         NOT (c.relname = 'stage_activities' AND
              t.tgname = 'stage_activities_dates_immutable')))
  ) THEN
    RAISE EXCEPTION 'REL-03I unreviewed write trigger could have side effects.';
  END IF;

  -- Select an authorized admin without a conflicting active calendar exception.
  -- Identity values remain internal to this transaction and are never printed.
  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.workspace_calendar_exceptions AS e
    WHERE e.workspace_id = m.workspace_id AND e.removed_at IS NULL
      AND e.start_date <= DATE '2030-01-09' AND e.end_date >= DATE '2030-01-07'
  ) ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN
    RAISE EXCEPTION 'REL-03I needs an active admin and clear test-date range.';
  END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
  VALUES (v_workspace, 'REL03I synthetic ' || v_marker, v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'REL03I discipline', 'R3I', '#556677', 0,
          v_actor, v_actor) RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R3I' || left(v_marker, 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition,
          'REL03I stage', 0, v_actor, v_actor) RETURNING id INTO v_stage;

  -- Monday 7 January 2030 plus two inclusive working days ends Tuesday 8.
  -- Closing the Tuesday produces Wednesday 9 as the selected reschedule end.
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'REL03I activity A', NULL,
    DATE '2030-01-07', DATE '2030-01-08', 0, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'id') IS NULL THEN RAISE EXCEPTION 'First plan creation failed.'; END IF;
  v_first := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'REL03I activity B', NULL,
    DATE '2030-01-07', DATE '2030-01-08', 1, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'id') IS NULL THEN RAISE EXCEPTION 'Second plan creation failed.'; END IF;
  v_second := (v_result->>'id')::uuid;
  v_low := LEAST(v_first, v_second);
  v_high := GREATEST(v_first, v_second);

  v_result := public.change_workspace_calendar(v_workspace, v_actor,
    gen_random_uuid(), v_calendar, 'create', NULL, 'company_shutdown',
    NULL, NULL, 'REL03I rollback-only closure',
    DATE '2030-01-08', DATE '2030-01-08');
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'version')::bigint IS DISTINCT FROM v_calendar + 1 THEN
    RAISE EXCEPTION 'Controlled calendar change failed.';
  END IF;
  v_low_proposal := jsonb_build_object('activityId', v_low,
    'disciplineId', v_discipline, 'stageId', v_stage, 'expectedVersion', 1,
    'startDate', '2030-01-07', 'currentEndDate', '2030-01-08',
    'proposedEndDate', '2030-01-09', 'workingDays', 2,
    'savedCalendarVersion', v_calendar);
  v_high_proposal := v_low_proposal || jsonb_build_object('activityId', v_high);

  -- First batch: apply and reverse one activity, establishing a reversal key.
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, v_calendar + 1, v_apply_reason,
    jsonb_build_array(v_high_proposal));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR
     (v_result->>'count')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'First reschedule did not update exactly one activity.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, v_first_reversal, v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR
     (v_result->>'count')::integer IS DISTINCT FROM 1 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_start = DATE '2030-01-07' AND planned_end = DATE '2030-01-08'
       AND planning_mode = 'working_days' AND working_day_duration = 2
       AND planning_calendar_version = v_calendar AND version = 3) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE activity_id = v_high AND actor_id = v_actor
         AND previous_end = DATE '2030-01-09' AND new_end = DATE '2030-01-08'
         AND version_before = 2 AND version_after = 3
         AND reason = v_reverse_reason) OR
     (SELECT count(*) FROM public.activity_date_changes WHERE activity_id = v_high) <> 2 THEN
    RAISE EXCEPTION 'First reversal, restored plan, or date audit differs.';
  END IF;

  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, gen_random_uuid(), v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'already_reversed' THEN
    RAISE EXCEPTION 'Duplicate reversal was accepted.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product,
    gen_random_uuid(), v_first_batch, gen_random_uuid(), v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Unknown actor was authorized.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    gen_random_uuid(), gen_random_uuid(), v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unknown original batch was accepted.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_first_batch, v_first_batch, v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Equal original/reversal batch IDs were accepted.';
  END IF;

  -- Second batch: both activities are rescheduled, then reversed together.
  v_high_proposal := v_high_proposal || jsonb_build_object('expectedVersion', 3);
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    v_second_batch, v_calendar + 1, v_apply_reason,
    jsonb_build_array(v_low_proposal, v_high_proposal));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR
     (v_result->>'count')::integer IS DISTINCT FROM 2 OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high)) <> 4 THEN
    RAISE EXCEPTION 'Two-activity reschedule failed.';
  END IF;

  -- A plan-only edit increments one version. The stale reversal must fail
  -- without touching the other activity; the nested block discards the edit.
  BEGIN
    v_result := public.change_activity_planning(v_workspace, v_product,
      v_discipline, v_stage, v_high, v_actor, gen_random_uuid(), 'manual',
      DATE '2030-01-07', DATE '2030-01-09', NULL, NULL,
      'REL03I synthetic stale-version edit', 4);
    IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
      RAISE EXCEPTION 'Stale-version setup failed.';
    END IF;
    v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
      v_second_batch, gen_random_uuid(), v_reverse_reason);
    IF v_result->>'status' IS DISTINCT FROM 'stale' OR
       (v_result->>'activityId') IS DISTINCT FROM v_high::text OR
       NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
         AND version = 2 AND planned_end = DATE '2030-01-09') THEN
      RAISE EXCEPTION 'Stale batch was reversed or another activity changed.';
    END IF;
    RAISE EXCEPTION 'Discard intentional stale-version edit.' USING ERRCODE = 'PZ018';
  EXCEPTION WHEN SQLSTATE 'PZ018' THEN
    v_stale_caught := true;
  END;
  IF NOT v_stale_caught OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_high
      AND version = 4 AND planning_mode = 'working_days'
      AND planned_end = DATE '2030-01-09'
  ) OR (SELECT count(*) FROM public.activity_date_changes
        WHERE activity_id IN (v_low, v_high)) <> 4 THEN
    RAISE EXCEPTION 'Stale-version probe left partial changes.';
  END IF;

  -- Reuse the first reversal ID: low can insert, but high collides with
  -- its existing (reversal_batch_operation_id, activity_id) unique key.
  BEGIN
    PERFORM public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
      v_second_batch, v_first_reversal, v_reverse_reason);
    RAISE EXCEPTION 'Expected reversal-ledger collision did not occur.';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint IS DISTINCT FROM 'calendar_reversal_one_activity_per_batch' THEN RAISE; END IF;
    v_collision_caught := true;
  END;
  IF NOT v_collision_caught OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
       AND planned_end = DATE '2030-01-09' AND version = 2
       AND planning_calendar_version = v_calendar + 1) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_end = DATE '2030-01-09' AND version = 4
       AND planning_calendar_version = v_calendar + 1) OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high)) <> 4 THEN
    RAISE EXCEPTION 'Failed reversal left partial activity or audit writes.';
  END IF;

  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_second_batch, v_second_reversal, v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR
     (v_result->>'count')::integer IS DISTINCT FROM 2 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_low
       AND planned_start = DATE '2030-01-07' AND planned_end = DATE '2030-01-08'
       AND planning_mode = 'working_days' AND working_day_duration = 2
       AND planning_calendar_version = v_calendar AND version = 3) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_high
       AND planned_start = DATE '2030-01-07' AND planned_end = DATE '2030-01-08'
       AND planning_mode = 'working_days' AND working_day_duration = 2
       AND planning_calendar_version = v_calendar AND version = 5) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE activity_id = v_low AND actor_id = v_actor
         AND previous_start = DATE '2030-01-07'
         AND previous_end = DATE '2030-01-09'
         AND new_start = DATE '2030-01-07'
         AND new_end = DATE '2030-01-08'
         AND version_before = 2 AND version_after = 3
         AND reason = v_reverse_reason) OR
     NOT EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE activity_id = v_high AND actor_id = v_actor
         AND previous_start = DATE '2030-01-07'
         AND previous_end = DATE '2030-01-09'
         AND new_start = DATE '2030-01-07'
         AND new_end = DATE '2030-01-08'
         AND version_before = 4 AND version_after = 5
         AND reason = v_reverse_reason) OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high)) <> 6 OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id IN (v_low, v_high) AND reason = v_reverse_reason) <> 3 THEN
    RAISE EXCEPTION 'Two-activity reversal or compensating audits differ.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_second_batch, gen_random_uuid(), v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'already_reversed' THEN
    RAISE EXCEPTION 'Second duplicate reversal was accepted.';
  END IF;

  RAISE NOTICE 'REL-03I reversal, duplicate, stale, authorization, audit, and atomicity assertions passed.';
END;
$test$;

-- The original activity set and immutable R00 must remain unchanged before rollback.
WITH original_activities AS (
  SELECT a.id, a.planned_start, a.planned_end
  FROM public.stage_activities AS a
  JOIN public.products AS p ON p.id = a.product_id
  WHERE left(p.name, 17) <> 'REL03I synthetic '
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
  AND date_fingerprint = (:'rel03i_baseline'::jsonb->>'dates')
  AND r00_fingerprint = (:'rel03i_baseline'::jsonb->>'r00')
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
SELECT 1 / CASE WHEN value = :'rel03i_baseline'::jsonb AND NOT EXISTS (
  SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03I synthetic '
) THEN 1 ELSE 0 END AS rollback_and_baseline_unchanged
FROM after_state;
ROLLBACK;
