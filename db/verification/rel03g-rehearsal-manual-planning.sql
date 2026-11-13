-- REL-03G: manual planning/date-function verification on the approved rehearsal branch.
-- Execute only as jlproject_worker with an explicit branch ID. No real activity is edited.
\set ON_ERROR_STOP on

-- Keep baseline values in psql session variables across the write transaction.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'definitions', (SELECT count(*) FROM public.stage_definitions),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'activity_dates', (SELECT md5(COALESCE(string_agg(
    a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
    COALESCE(a.planned_end::text, ''), E'\n' ORDER BY a.id), ''))
    FROM public.stage_activities AS a),
  'activity_audit', (SELECT count(*) FROM public.activity_date_changes),
  'target_audit', (SELECT count(*) FROM public.business_target_date_changes),
  'r00_count', (SELECT count(*) FROM public.initial_schedule_revisions),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS baseline
\gset rel03g_
ROLLBACK;

SELECT 1 / CASE WHEN (:'rel03g_baseline'::jsonb->>'activities')::bigint = 73
  AND (:'rel03g_baseline'::jsonb->>'activity_audit')::bigint = 3
  AND (:'rel03g_baseline'::jsonb->>'target_audit')::bigint = 0
  AND (:'rel03g_baseline'::jsonb->>'r00_count')::bigint = 1
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
  v_activity uuid;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_name text;
  v_first_operation uuid := gen_random_uuid();
  v_second_operation uuid := gen_random_uuid();
  v_result jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'REL-03G requires neondb and the actual Worker role.';
  END IF;
  IF NOT has_function_privilege(current_user,
      'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)',
      'EXECUTE') OR NOT has_function_privilege(current_user,
      'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)',
      'EXECUTE') OR
      has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'UPDATE') OR
      has_table_privilege(current_user, 'public.activity_date_changes', 'INSERT') OR
      has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') THEN
    RAISE EXCEPTION 'REL-03G Worker privileges differ from the approved boundary.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger AS trigger
    JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public' AND relation.relname IN
      ('products', 'product_disciplines', 'stage_definitions',
       'discipline_stages', 'stage_activities')
      AND NOT trigger.tgisinternal AND (trigger.tgtype & 4) <> 0
  ) THEN
    RAISE EXCEPTION 'REL-03G unreviewed INSERT trigger; stop.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03G synthetic ') THEN
    RAISE EXCEPTION 'REL-03G synthetic marker already exists; stop.';
  END IF;

  -- Reuse an existing authorized identity only for FK and function authorization.
  -- No identity is returned, logged, or modified.
  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role IN ('admin', 'editor')
  ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'REL-03G requires an active editor/admin membership.';
  END IF;

  v_name := 'REL03G synthetic ' || v_marker;
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
  VALUES (v_workspace, v_name, v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'REL03G discipline', 'R3G', '#556677', 0,
          v_actor, v_actor)
  RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R3G' || left(v_marker, 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition,
          'REL03G stage', 0, v_actor, v_actor)
  RETURNING id INTO v_stage;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_stage, 'REL03G activity',
          DATE '2026-11-16', DATE '2026-11-18', 0, v_actor, v_actor)
  RETURNING id INTO v_activity;
  IF NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_activity AND version = 1
      AND planning_mode = 'manual' AND working_day_duration IS NULL
      AND planning_calendar_version IS NULL
  ) THEN
    RAISE EXCEPTION 'REL-03G synthetic manual defaults differ.';
  END IF;

  v_result := public.change_activity_planning(
    v_workspace, v_product, v_discipline, v_stage, v_activity, v_actor,
    v_first_operation, 'manual', DATE '2026-11-17', DATE '2026-11-19',
    NULL, NULL, 'REL03G audited manual planning change', 1);
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_activity AND version = 2
      AND planned_start = DATE '2026-11-17' AND planned_end = DATE '2026-11-19'
      AND planning_mode = 'manual' AND working_day_duration IS NULL
      AND planning_calendar_version IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes
    WHERE operation_id = v_first_operation AND activity_id = v_activity
      AND actor_id = v_actor AND version_before = 1 AND version_after = 2
      AND previous_start = DATE '2026-11-16' AND previous_end = DATE '2026-11-18'
      AND new_start = DATE '2026-11-17' AND new_end = DATE '2026-11-19'
      AND reason = 'REL03G audited manual planning change'
  ) THEN
    RAISE EXCEPTION 'REL-03G manual planning update or audit differs.';
  END IF;

  v_result := public.change_activity_dates(
    v_workspace, v_product, v_discipline, v_stage, v_activity, v_actor,
    v_second_operation, DATE '2026-11-18', DATE '2026-11-20',
    'REL03G audited date wrapper change', 2);
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_activity AND version = 3
      AND planned_start = DATE '2026-11-18' AND planned_end = DATE '2026-11-20'
      AND planning_mode = 'manual' AND working_day_duration IS NULL
      AND planning_calendar_version IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes
    WHERE operation_id = v_second_operation AND activity_id = v_activity
      AND actor_id = v_actor AND version_before = 2 AND version_after = 3
      AND previous_start = DATE '2026-11-17' AND previous_end = DATE '2026-11-19'
      AND new_start = DATE '2026-11-18' AND new_end = DATE '2026-11-20'
      AND reason = 'REL03G audited date wrapper change'
  ) THEN
    RAISE EXCEPTION 'REL-03G date wrapper update or audit differs.';
  END IF;

  v_result := public.change_activity_planning(
    v_workspace, v_product, v_discipline, v_stage, v_activity, v_actor,
    gen_random_uuid(), 'manual', DATE '2026-11-19', DATE '2026-11-21',
    NULL, NULL, 'REL03G stale version check', 1);
  IF v_result->>'status' <> 'stale' THEN
    RAISE EXCEPTION 'REL-03G stale version was not rejected.';
  END IF;
  v_result := public.change_activity_dates(
    v_workspace, v_product, v_discipline, v_stage, v_activity, gen_random_uuid(),
    gen_random_uuid(), DATE '2026-11-19', DATE '2026-11-21',
    'REL03G unauthorized actor check', 3);
  IF v_result->>'status' <> 'forbidden' OR
     (SELECT count(*) FROM public.activity_date_changes WHERE activity_id = v_activity) <> 2 OR
     (SELECT version FROM public.stage_activities WHERE id = v_activity) <> 3 THEN
    RAISE EXCEPTION 'REL-03G negative path mutated the activity or audit.';
  END IF;
  IF (SELECT count(*) FROM public.initial_schedule_revisions) <> 1 THEN
    RAISE EXCEPTION 'REL-03G existing R00 count changed.';
  END IF;

  RAISE NOTICE 'REL-03G manual planning/date functions, versions, audits, denial, and R00 assertions passed.';
END;
$test$;

-- The original activity set and immutable R00 must be unchanged even before rollback.
WITH original_activities AS (
  SELECT a.id, a.planned_start, a.planned_end
  FROM public.stage_activities AS a
  JOIN public.products AS p ON p.id = a.product_id
  WHERE left(p.name, 17) <> 'REL03G synthetic '
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
  AND date_fingerprint = :'rel03g_baseline'::jsonb->>'activity_dates'
  AND r00_fingerprint = :'rel03g_baseline'::jsonb->>'r00_fingerprint'
  AND (SELECT count(*) FROM public.activity_date_changes) = 5
  THEN 1 ELSE 0 END AS original_rows_unchanged_inside_transaction
FROM original_state;

-- Discard every synthetic fixture and audit row, including successful function calls.
ROLLBACK;

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
WITH after_state AS (
  SELECT jsonb_build_object(
    'products', (SELECT count(*) FROM public.products),
    'disciplines', (SELECT count(*) FROM public.product_disciplines),
    'definitions', (SELECT count(*) FROM public.stage_definitions),
    'stages', (SELECT count(*) FROM public.discipline_stages),
    'activities', (SELECT count(*) FROM public.stage_activities),
    'activity_dates', (SELECT md5(COALESCE(string_agg(
      a.id::text || '|' || COALESCE(a.planned_start::text, '') || '|' ||
      COALESCE(a.planned_end::text, ''), E'\n' ORDER BY a.id), ''))
      FROM public.stage_activities AS a),
    'activity_audit', (SELECT count(*) FROM public.activity_date_changes),
    'target_audit', (SELECT count(*) FROM public.business_target_date_changes),
    'r00_count', (SELECT count(*) FROM public.initial_schedule_revisions),
    'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r)
  ) AS value
)
SELECT 1 / CASE WHEN value = :'rel03g_baseline'::jsonb AND NOT EXISTS (
  SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03G synthetic '
) THEN 1 ELSE 0 END AS rollback_and_baseline_unchanged
FROM after_state;
ROLLBACK;
