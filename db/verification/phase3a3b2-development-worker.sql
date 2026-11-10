BEGIN;

DO $$
DECLARE
  v_workspace_id uuid;
  v_actor_id uuid;
  v_product_id uuid;
  v_manual_activity_id uuid;
  v_working_activity_id uuid;
  v_discipline_id uuid;
  v_product_name constant text := '__JLProject 0014 synthetic rollback check__';
  v_stage_id uuid;
  v_stage_result text;
  v_calendar_version bigint;
  v_result jsonb;
  v_plan_mode text;
  v_duration integer;
  v_saved_calendar_version bigint;
  v_direct_update_succeeded boolean;
BEGIN
  IF current_user <> 'jlproject_worker' OR current_database() <> 'neondb' THEN
    RAISE EXCEPTION 'Synthetic check requires the limited Worker role on neondb.';
  END IF;
  IF has_table_privilege(current_user, 'public.stage_activities', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     has_table_privilege(current_user, 'public.activity_date_changes', 'INSERT') OR
     has_table_privilege(current_user, 'public.activity_date_changes', 'UPDATE') OR
     has_table_privilege(current_user, 'public.activity_date_changes', 'DELETE') THEN
    RAISE EXCEPTION 'The limited Worker role has an unexpected direct write privilege.';
  END IF;
  IF NOT has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'INSERT') OR
     NOT has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'INSERT') OR
     NOT has_function_privilege(current_user,
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)',
       'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'A required scoped Worker capability is missing.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE name = v_product_name) OR
     EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE operation_id IN (
         'e0143b8e-b516-4e42-85ed-7aa831a6030c',
         'e0143b8e-b516-4e42-85ed-7aa831a6030d',
         'e0143b8e-b516-4e42-85ed-7aa831a6030e')) THEN
    RAISE EXCEPTION 'Synthetic identifiers already exist; refusing to continue.';
  END IF;

  SELECT id INTO v_workspace_id FROM public.workspaces WHERE name = 'JLProject';
  IF v_workspace_id IS NULL OR
     (SELECT count(*) FROM public.workspaces WHERE name = 'JLProject') <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one JLProject workspace.';
  END IF;
  SELECT auth_user_id INTO v_actor_id FROM public.workspace_memberships
    WHERE workspace_id = v_workspace_id AND active = true AND role = 'admin'
    ORDER BY auth_user_id LIMIT 1;
  IF v_actor_id IS NULL THEN RAISE EXCEPTION 'No active development administrator is available.'; END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace_id), 0) INTO v_calendar_version;

  INSERT INTO public.products
    (workspace_id, name, description, created_by, updated_by)
  VALUES (v_workspace_id, v_product_name,
    'Synthetic database verification only.', v_actor_id, v_actor_id)
  RETURNING id INTO v_product_id;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id,
    'Synthetic 0014 discipline', 'S14-' || left(replace(v_product_id::text, '-', ''), 8),
    '#557799', 0, v_actor_id, v_actor_id)
  RETURNING id INTO v_discipline_id;

  SELECT public.create_discipline_stage(v_workspace_id, v_product_id, v_discipline_id,
    v_actor_id, 'S14-' || left(replace(v_product_id::text, '-', ''), 8),
    '#557799', 'Synthetic 0014 stage', 0) INTO v_stage_result;
  IF v_stage_result IS NULL OR v_stage_result IN ('not_found', 'conflict', 'duplicate') THEN
    RAISE EXCEPTION 'Synthetic stage creation failed.';
  END IF;
  v_stage_id := v_stage_result::uuid;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_id,
    v_stage_id, 'Synthetic manual planning activity', DATE '2026-11-11',
    DATE '2026-11-12', 0, v_actor_id, v_actor_id)
  RETURNING id INTO v_manual_activity_id;
  SELECT planning_mode, working_day_duration, planning_calendar_version
    INTO v_plan_mode, v_duration, v_saved_calendar_version
    FROM public.stage_activities WHERE id = v_manual_activity_id;
  IF v_plan_mode <> 'manual' OR v_duration IS NOT NULL OR v_saved_calendar_version IS NOT NULL THEN
    RAISE EXCEPTION 'Manual activity defaults are incorrect.';
  END IF;

  SELECT public.create_activity_with_working_plan(v_workspace_id, v_product_id,
    v_discipline_id, v_stage_id, v_actor_id, 'Synthetic working-day activity', NULL,
    DATE '2026-11-16', DATE '2026-11-17', 1, NULL, 2, v_calendar_version)
    INTO v_result;
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Working-plan creation failed.'; END IF;
  v_working_activity_id := (v_result->>'id')::uuid;
  SELECT planning_mode, working_day_duration, planning_calendar_version
    INTO v_plan_mode, v_duration, v_saved_calendar_version
    FROM public.stage_activities WHERE id = v_working_activity_id;
  IF v_plan_mode <> 'working_days' OR v_duration <> 2 OR
     v_saved_calendar_version <> v_calendar_version THEN
    RAISE EXCEPTION 'Working-plan metadata or calendar version was not persisted.';
  END IF;

  SELECT public.create_activity_with_working_plan(v_workspace_id, v_product_id,
    v_discipline_id, v_stage_id, v_actor_id, 'Synthetic stale calendar request', NULL,
    DATE '2026-11-16', DATE '2026-11-17', 2, NULL, 2, v_calendar_version + 1)
    INTO v_result;
  IF v_result->>'status' <> 'stale_calendar' THEN
    RAISE EXCEPTION 'Stale calendar version was not rejected.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stage_activities
    WHERE product_id = v_product_id AND name = 'Synthetic stale calendar request') THEN
    RAISE EXCEPTION 'Failed working-plan creation left an activity row.';
  END IF;

  SELECT public.create_activity_with_working_plan(v_workspace_id, v_product_id,
    v_discipline_id, v_stage_id, gen_random_uuid(), 'Synthetic unauthorized request', NULL,
    DATE '2026-11-16', DATE '2026-11-17', 2, NULL, 2, v_calendar_version)
    INTO v_result;
  IF v_result->>'status' <> 'forbidden' THEN
    RAISE EXCEPTION 'The controlled create function did not enforce active workspace membership.';
  END IF;
  SELECT public.create_activity_with_working_plan(gen_random_uuid(), v_product_id,
    v_discipline_id, v_stage_id, v_actor_id, 'Synthetic cross-workspace request', NULL,
    DATE '2026-11-16', DATE '2026-11-17', 2, NULL, 2, 0)
    INTO v_result;
  IF v_result->>'status' <> 'not_found' THEN
    RAISE EXCEPTION 'The controlled create function did not enforce workspace isolation.';
  END IF;

  SELECT public.change_activity_dates(v_workspace_id, v_product_id, v_discipline_id,
    v_stage_id, v_manual_activity_id, v_actor_id,
    'e0143b8e-b516-4e42-85ed-7aa831a6030c', DATE '2026-11-12', DATE '2026-11-13',
    'Synthetic audited date change', 1) INTO v_result;
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes
    WHERE operation_id = 'e0143b8e-b516-4e42-85ed-7aa831a6030c'
      AND previous_start = DATE '2026-11-11' AND previous_end = DATE '2026-11-12'
      AND new_start = DATE '2026-11-12' AND new_end = DATE '2026-11-13'
      AND reason = 'Synthetic audited date change') THEN
    RAISE EXCEPTION 'Audited manual date update was not recorded correctly.';
  END IF;
  SELECT public.change_activity_dates(v_workspace_id, v_product_id, v_discipline_id,
    v_stage_id, v_manual_activity_id, v_actor_id,
    'e0143b8e-b516-4e42-85ed-7aa831a6030d', DATE '2026-11-13', DATE '2026-11-14',
    'Synthetic stale update check', 1) INTO v_result;
  IF v_result->>'status' <> 'stale' THEN
    RAISE EXCEPTION 'Optimistic concurrency did not reject a stale version.';
  END IF;

  SELECT public.change_activity_planning(v_workspace_id, v_product_id, v_discipline_id,
    v_stage_id, v_working_activity_id, v_actor_id,
    'e0143b8e-b516-4e42-85ed-7aa831a6030e', 'working_days',
    DATE '2026-11-17', DATE '2026-11-18', 2, v_calendar_version,
    'Synthetic working plan audit', 1) INTO v_result;
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes
    WHERE activity_id = v_working_activity_id AND new_start = DATE '2026-11-17'
      AND new_end = DATE '2026-11-18' AND reason = 'Synthetic working plan audit') THEN
    RAISE EXCEPTION 'Audited working-plan update was not recorded correctly.';
  END IF;

  v_direct_update_succeeded := false;
  BEGIN
    UPDATE public.stage_activities SET planned_start = DATE '2026-11-10'
      WHERE id = v_manual_activity_id;
    v_direct_update_succeeded := true;
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_update_succeeded := false;
  END;
  IF v_direct_update_succeeded THEN RAISE EXCEPTION 'Direct Worker date update unexpectedly succeeded.'; END IF;

  RAISE NOTICE 'Synthetic manual/working plans, calendar version, audited edits, and stale-version checks passed.';
END;
$$;

ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.products
    WHERE name = '__JLProject 0014 synthetic rollback check__') OR
     EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE operation_id IN (
         'e0143b8e-b516-4e42-85ed-7aa831a6030c',
         'e0143b8e-b516-4e42-85ed-7aa831a6030d',
         'e0143b8e-b516-4e42-85ed-7aa831a6030e')) THEN
    RAISE EXCEPTION 'Synthetic rollback left database residue.';
  END IF;
  RAISE NOTICE 'Synthetic rollback left no product or audit residue.';
END;
$$;
