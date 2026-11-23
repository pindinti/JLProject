-- Run as jlproject_worker on a verified disposable Development child only after separate migration approval.
-- The caller supplies the synthetic fixture IDs described in the Phase 4B.3a notes.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_date_guard_fixture', jsonb_build_object(
  'workspace', :'test_workspace', 'product', :'test_product', 'actor', :'test_actor',
  'discipline', :'test_discipline', 'parent', :'test_parent', 'child', :'test_child',
  'linkedRoot', :'test_linked_root', 'emptyProduct', :'test_empty_product', 'emptyRoot', :'test_empty_root')::text, true);

DO $$
DECLARE
  v_fixture jsonb := current_setting('jlproject.test_date_guard_fixture')::jsonb;
  v_workspace uuid := (v_fixture->>'workspace')::uuid;
  v_product uuid := (v_fixture->>'product')::uuid;
  v_actor uuid := (v_fixture->>'actor')::uuid;
  v_discipline uuid := (v_fixture->>'discipline')::uuid;
  v_parent uuid := (v_fixture->>'parent')::uuid;
  v_child uuid := (v_fixture->>'child')::uuid;
  v_linked_root uuid := (v_fixture->>'linkedRoot')::uuid;
  v_empty_product uuid := (v_fixture->>'emptyProduct')::uuid;
  v_empty_root uuid := (v_fixture->>'emptyRoot')::uuid;
  v_cursor bigint;
  v_version bigint;
  v_result jsonb;
  v_reason constant text := 'Synthetic individual date guard verification';
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR NOT EXISTS (
    SELECT 1 FROM public.workspaces WHERE id = v_workspace AND name = 'Synthetic Phase 4B.3a date guard workspace'
  ) OR NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND id = v_product
    AND name = 'Synthetic Phase 4B.3a linked product') OR NOT EXISTS (SELECT 1 FROM public.products
    WHERE workspace_id = v_workspace AND id = v_empty_product AND name = 'Synthetic Phase 4B.3a empty product') THEN
    RAISE EXCEPTION 'Expected a limited Worker and the synthetic date guard fixture.';
  END IF;
  IF has_function_privilege(current_user,
      'public.write_reviewed_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE')
    OR has_function_privilege(current_user,
      'public.write_reviewed_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE')
    OR has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE')
    OR has_column_privilege(current_user, 'public.discipline_stages', 'planned_end', 'UPDATE') THEN
    RAISE EXCEPTION 'The Worker can bypass the individual date guard.';
  END IF;

  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline, v_parent, v_child, v_actor,
    gen_random_uuid(), '2026-11-05', '2026-11-09', v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_preview_required' OR v_result->>'direction' IS DISTINCT FROM 'outbound'
    OR v_result#>>'{after,earliestStart}' IS DISTINCT FROM '2026-11-10' THEN
    RAISE EXCEPTION 'An individual child edit bypassed the downstream stage guard.';
  END IF;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline, v_parent, v_child, v_actor,
    gen_random_uuid(), 'working_days', '2026-11-05', '2026-11-09', 3, 0, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_preview_required' THEN RAISE EXCEPTION 'Working-day bypass.'; END IF;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline, v_parent, v_child, v_actor,
    gen_random_uuid(), 'working_days', '2026-11-05', '2026-11-09', 3, 1, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'stale_calendar' THEN RAISE EXCEPTION 'Stale calendar was accepted.'; END IF;
  v_result := public.change_activity_dates(v_workspace, v_product, NULL, NULL, v_linked_root, v_actor,
    gen_random_uuid(), '2026-11-05', '2026-11-09', v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR v_result->>'direction' IS DISTINCT FROM 'inbound' THEN
    RAISE EXCEPTION 'A root activity bypassed the inbound guard.';
  END IF;
  v_result := public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_parent, v_actor,
    gen_random_uuid(), '2026-11-05', NULL, v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'dependency_conflict' OR v_result->>'reason' IS DISTINCT FROM 'missing_boundary' THEN
    RAISE EXCEPTION 'A start-only explicit stage incorrectly borrowed a derived finish.';
  END IF;
  v_result := public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_parent, v_actor,
    gen_random_uuid(), '2026-11-05', NULL, v_reason, 99);
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'Stage optimistic version bypass.'; END IF;
  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline, v_parent, v_child, gen_random_uuid(),
    gen_random_uuid(), '2026-11-05', '2026-11-09', v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN RAISE EXCEPTION 'Date operation membership bypass.'; END IF;
  SELECT schedule_version INTO STRICT v_version FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_version <> v_cursor THEN RAISE EXCEPTION 'Blocked edits advanced the schedule cursor.'; END IF;

  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline, v_parent, v_child, v_actor,
    gen_random_uuid(), '2026-11-05', '2026-11-06', v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'A valid derived-stage edit was blocked.'; END IF;
  SELECT schedule_version INTO STRICT v_version FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_version <> v_cursor + 1 THEN RAISE EXCEPTION 'Valid edit did not advance the cursor exactly once.'; END IF;

  v_result := public.change_activity_dates(v_workspace, v_empty_product, NULL, NULL, v_empty_root, v_actor,
    gen_random_uuid(), '2025-12-30', '2025-12-31', v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'Empty graph changed manual date behavior.'; END IF;
END;
$$;

ROLLBACK;
