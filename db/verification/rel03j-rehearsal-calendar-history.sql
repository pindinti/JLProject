-- REL-03J: rollback-only reschedule history check for the approved rehearsal branch.
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
\gset rel03j_
ROLLBACK;

SELECT 1 / CASE WHEN (:'rel03j_baseline'::jsonb->>'products')::bigint = 5
  AND (:'rel03j_baseline'::jsonb->>'stages')::bigint = 40
  AND (:'rel03j_baseline'::jsonb->>'activities')::bigint = 73
  AND (:'rel03j_baseline'::jsonb->>'date_audits')::bigint = 3
  AND (:'rel03j_baseline'::jsonb->>'r00_count')::bigint = 1
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
  v_other_product uuid;
  v_discipline uuid;
  v_definition uuid;
  v_stage uuid;
  v_activity uuid;
  v_calendar bigint;
  v_batch uuid := gen_random_uuid();
  v_reversal uuid := gen_random_uuid();
  v_result jsonb;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_apply_reason text := 'REL03J synthetic calendar apply';
  v_reverse_reason text := 'REL03J synthetic calendar reversal';
  v_unused_count bigint;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.list_calendar_reschedule_history(uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') THEN
    RAISE EXCEPTION 'REL-03J requires the limited Worker function boundary.';
  END IF;
  -- An actual direct read must fail. The result is never printed.
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.calendar_reschedule_changes' INTO v_unused_count;
    RAISE EXCEPTION 'Worker unexpectedly read reschedule ledger.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.calendar_reschedule_reversals' INTO v_unused_count;
    RAISE EXCEPTION 'Worker unexpectedly read reversal ledger.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF EXISTS (SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03J synthetic ') THEN
    RAISE EXCEPTION 'REL-03J synthetic marker already exists; stop.';
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
    RAISE EXCEPTION 'REL-03J unreviewed write trigger could have side effects.';
  END IF;

  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role = 'admin' AND EXISTS (
    SELECT 1 FROM public.products AS p
    WHERE p.workspace_id = m.workspace_id AND p.active
  ) AND NOT EXISTS (
    SELECT 1 FROM public.workspace_calendar_exceptions AS e
    WHERE e.workspace_id = m.workspace_id AND e.removed_at IS NULL
      AND e.start_date <= DATE '2030-01-09' AND e.end_date >= DATE '2030-01-07'
  ) ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN
    RAISE EXCEPTION 'REL-03J needs an active admin/product and clear test-date range.';
  END IF;
  SELECT id INTO v_other_product FROM public.products
  WHERE workspace_id = v_workspace AND active
  ORDER BY id LIMIT 1;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
  VALUES (v_workspace, 'REL03J synthetic ' || v_marker, v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'REL03J discipline', 'R3J', '#556677', 0,
          v_actor, v_actor) RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R3J' || left(v_marker, 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition,
          'REL03J stage', 0, v_actor, v_actor) RETURNING id INTO v_stage;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'REL03J activity', NULL,
    DATE '2030-01-07', DATE '2030-01-08', 0, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'id') IS NULL THEN
    RAISE EXCEPTION 'Synthetic working plan creation failed.';
  END IF;
  v_activity := (v_result->>'id')::uuid;

  v_result := public.change_workspace_calendar(v_workspace, v_actor,
    gen_random_uuid(), v_calendar, 'create', NULL, 'company_shutdown',
    NULL, NULL, 'REL03J rollback-only closure',
    DATE '2030-01-08', DATE '2030-01-08');
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     (v_result->>'version')::bigint IS DISTINCT FROM v_calendar + 1 THEN
    RAISE EXCEPTION 'Controlled calendar change failed.';
  END IF;
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor,
    v_batch, v_calendar + 1, v_apply_reason,
    jsonb_build_array(jsonb_build_object(
      'activityId', v_activity, 'disciplineId', v_discipline, 'stageId', v_stage,
      'expectedVersion', 1, 'startDate', '2030-01-07',
      'currentEndDate', '2030-01-08', 'proposedEndDate', '2030-01-09',
      'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR
     (v_result->>'count')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Synthetic calendar reschedule failed.';
  END IF;

  PERFORM set_config('rel03j.workspace_id', v_workspace::text, true);
  PERFORM set_config('rel03j.actor_id', v_actor::text, true);
  PERFORM set_config('rel03j.product_id', v_product::text, true);
  PERFORM set_config('rel03j.other_product_id', v_other_product::text, true);
  PERFORM set_config('rel03j.activity_id', v_activity::text, true);
  PERFORM set_config('rel03j.batch_id', v_batch::text, true);
  PERFORM set_config('rel03j.reversal_id', v_reversal::text, true);
END;
$test$;

-- The STABLE reader must run in a later SQL statement to see the apply writes.
DO $applied$
DECLARE
  v_workspace uuid := current_setting('rel03j.workspace_id')::uuid;
  v_actor uuid := current_setting('rel03j.actor_id')::uuid;
  v_product uuid := current_setting('rel03j.product_id')::uuid;
  v_activity uuid := current_setting('rel03j.activity_id')::uuid;
  v_batch uuid := current_setting('rel03j.batch_id')::uuid;
  v_reversal uuid := current_setting('rel03j.reversal_id')::uuid;
  v_history jsonb;
  v_operation jsonb;
  v_item jsonb;
  v_result jsonb;
  v_apply_reason text := 'REL03J synthetic calendar apply';
  v_reverse_reason text := 'REL03J synthetic calendar reversal';
BEGIN

  -- 0019 exposes the apply batch as one operation. The reversal is nested
  -- in that operation after reversal; it is not a second top-level operation.
  v_history := public.list_calendar_reschedule_history(v_workspace, v_product, v_actor);
  IF v_history->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_typeof(v_history->'operations') IS DISTINCT FROM 'array' OR
     jsonb_array_length(v_history->'operations') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Applied batch was not returned as one operation.';
  END IF;
  v_operation := v_history->'operations'->0;
  v_item := v_operation->'activities'->0;
  IF v_operation->>'operationId' IS DISTINCT FROM v_batch::text OR
     v_operation->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_operation->>'reason' IS DISTINCT FROM v_apply_reason OR
     v_operation->>'status' IS DISTINCT FROM 'eligible' OR
     jsonb_typeof(v_operation->'changedAt') IS DISTINCT FROM 'string' OR
     (v_operation->'reversal') IS DISTINCT FROM 'null'::jsonb OR
     jsonb_typeof(v_operation->'activities') IS DISTINCT FROM 'array' OR
     jsonb_array_length(v_operation->'activities') IS DISTINCT FROM 1 OR
     v_item->>'activityId' IS DISTINCT FROM v_activity::text OR
     v_item->>'name' IS DISTINCT FROM 'REL03J activity' OR
     v_item->>'previousStart' IS DISTINCT FROM '2030-01-07' OR
     v_item->>'previousEnd' IS DISTINCT FROM '2030-01-08' OR
     v_item->>'newStart' IS DISTINCT FROM '2030-01-07' OR
     v_item->>'newEnd' IS DISTINCT FROM '2030-01-09' OR
     v_item->>'currentEnd' IS DISTINCT FROM '2030-01-09' OR
     (v_item->>'currentVersion')::bigint IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Applied history details or relationships differ.';
  END IF;

  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_batch, v_reversal, v_reverse_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR
     (v_result->>'count')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Synthetic reversal failed.';
  END IF;
END;
$applied$;

-- A further statement gives the STABLE reader a snapshot containing reversal.
DO $reversed$
DECLARE
  v_workspace uuid := current_setting('rel03j.workspace_id')::uuid;
  v_actor uuid := current_setting('rel03j.actor_id')::uuid;
  v_product uuid := current_setting('rel03j.product_id')::uuid;
  v_other_product uuid := current_setting('rel03j.other_product_id')::uuid;
  v_activity uuid := current_setting('rel03j.activity_id')::uuid;
  v_batch uuid := current_setting('rel03j.batch_id')::uuid;
  v_history jsonb;
  v_operation jsonb;
  v_item jsonb;
  v_result jsonb;
  v_reverse_reason text := 'REL03J synthetic calendar reversal';
BEGIN
  v_history := public.list_calendar_reschedule_history(v_workspace, v_product, v_actor);
  IF v_history->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_typeof(v_history->'operations') IS DISTINCT FROM 'array' OR
     jsonb_array_length(v_history->'operations') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Reversed batch disappeared from history.';
  END IF;
  v_operation := v_history->'operations'->0;
  v_item := v_operation->'activities'->0;
  IF v_operation->>'operationId' IS DISTINCT FROM v_batch::text OR
     v_operation->>'status' IS DISTINCT FROM 'already_reversed' OR
     jsonb_typeof(v_operation->'reversal') IS DISTINCT FROM 'object' OR
     jsonb_typeof(v_operation->'reversal'->'changedAt') IS DISTINCT FROM 'string' OR
     v_operation->'reversal'->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_operation->'reversal'->>'reason' IS DISTINCT FROM v_reverse_reason OR
     v_item->>'activityId' IS DISTINCT FROM v_activity::text OR
     v_item->>'previousEnd' IS DISTINCT FROM '2030-01-08' OR
     v_item->>'newEnd' IS DISTINCT FROM '2030-01-09' OR
     v_item->>'currentEnd' IS DISTINCT FROM '2030-01-08' OR
     (v_item->>'currentVersion')::bigint IS DISTINCT FROM 3 OR
     (SELECT count(*) FROM public.activity_date_changes
      WHERE activity_id = v_activity) <> 2 THEN
    RAISE EXCEPTION 'Reversal history details or date audit differ.';
  END IF;

  v_result := public.list_calendar_reschedule_history(v_workspace, v_product,
    gen_random_uuid());
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Unauthorized history reader was accepted.';
  END IF;
  v_result := public.list_calendar_reschedule_history(v_workspace,
    gen_random_uuid(), v_actor);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unrelated product history was exposed.';
  END IF;
  v_result := public.list_calendar_reschedule_history(v_workspace,
    v_other_product, v_actor);
  IF v_result->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_typeof(v_result->'operations') IS DISTINCT FROM 'array' OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'operations') AS item(value)
       WHERE item.value->>'operationId' = v_batch::text) THEN
    RAISE EXCEPTION 'Synthetic operation leaked to an existing product.';
  END IF;
  v_result := public.list_calendar_reschedule_history(gen_random_uuid(),
    v_product, v_actor);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unrelated workspace history was exposed.';
  END IF;
  v_result := public.list_calendar_reschedule_history(v_workspace,
    v_product, NULL::uuid);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Null actor was accepted.';
  END IF;

  RAISE NOTICE 'REL-03J scoped history, nested reversal, denial, and ledger privilege assertions passed.';
END;
$reversed$;

-- Existing project dates and R00 must be unchanged while fixtures are visible.
WITH original_activities AS (
  SELECT a.id, a.planned_start, a.planned_end
  FROM public.stage_activities AS a
  JOIN public.products AS p ON p.id = a.product_id
  WHERE left(p.name, 17) <> 'REL03J synthetic '
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
  AND date_fingerprint = (:'rel03j_baseline'::jsonb->>'dates')
  AND r00_fingerprint = (:'rel03j_baseline'::jsonb->>'r00')
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
SELECT 1 / CASE WHEN value = :'rel03j_baseline'::jsonb AND NOT EXISTS (
  SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03J synthetic '
) THEN 1 ELSE 0 END AS rollback_and_baseline_unchanged
FROM after_state;
ROLLBACK;
