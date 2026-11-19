\set ON_ERROR_STOP on

-- Run only on a disposable Development-derived branch. The fixture commits.
CREATE TEMP TABLE phase21_archive_fixture (
  workspace_id uuid, actor_id uuid, product_id uuid
) ON COMMIT PRESERVE ROWS;

BEGIN;
DO $seed$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_seed uuid;
  v_discipline uuid;
  v_stage uuid;
  v_calendar bigint;
  v_operation uuid := gen_random_uuid();
  v_reason text := 'Isolated archived clone source fixture';
  v_result jsonb;
BEGIN
  SELECT workspace_id, auth_user_id INTO STRICT v_workspace, v_actor
    FROM public.workspace_memberships WHERE active AND role = 'admin'
    ORDER BY workspace_id, auth_user_id LIMIT 1;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, 'P2.1 archive seed ' || v_operation, v_actor, v_actor) RETURNING id INTO v_seed;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_seed, 'Synthetic discipline', 'A35', '#335577', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  PERFORM set_config('jlproject.schedule_operation_type', 'stage_created_with_dates', true);
  v_stage := public.create_discipline_stage_with_dates(v_workspace, v_seed, v_discipline,
    v_actor, v_operation, 'A35' || left(v_operation::text, 8), '#335577', 'Synthetic stage', 0,
    DATE '2030-02-04', DATE '2030-02-08', v_reason)::uuid;
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  v_result := public.create_activity_with_working_plan(v_workspace, v_seed, v_discipline, v_stage,
    v_actor, 'Synthetic stage activity', NULL, DATE '2030-02-04', DATE '2030-02-06', 0, NULL, 3, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Stage fixture failed.'; END IF;
  v_result := public.create_activity_with_working_plan(v_workspace, v_seed, NULL, NULL,
    v_actor, 'Synthetic root activity', NULL, DATE '2030-02-04', DATE '2030-02-05', 0, NULL, 2, v_calendar);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Root fixture failed.'; END IF;
  PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_cloned', true);
  v_result := public.clone_product(v_workspace, v_seed, v_actor, 'P2.1 archive source ' || v_operation);
  IF v_result->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Baseline fixture failed.'; END IF;
  INSERT INTO phase21_archive_fixture VALUES (v_workspace, v_actor, (v_result->'product'->>'id')::uuid);
END;
$seed$;
COMMIT;

BEGIN;
DO $archive$
DECLARE
  fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM phase21_archive_fixture;
  v_result := public.change_product_status(fixture.workspace_id, fixture.product_id, fixture.actor_id,
    'arquivado', 1, 'Archive the synthetic clone source');
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'Fixture archive failed.'; END IF;
END;
$archive$;
COMMIT;

BEGIN;
DO $verify$
DECLARE
  f record;
  v_clone uuid;
  v_result jsonb;
  v_product jsonb;
  v_source_r00 jsonb;
  v_clone_r00 jsonb;
  v_source_audit jsonb;
  v_source_activities jsonb;
  v_source_stages jsonb;
  v_name text := 'P2.1 archived clone ' || gen_random_uuid();
BEGIN
  SELECT * INTO STRICT f FROM phase21_archive_fixture;
  SELECT to_jsonb(p) INTO STRICT v_product FROM public.products AS p WHERE id = f.product_id AND NOT active;
  SELECT to_jsonb(r) INTO STRICT v_source_r00 FROM public.initial_schedule_revisions AS r
    WHERE product_id = f.product_id AND label = 'R00';
  SELECT jsonb_agg(to_jsonb(o) ORDER BY schedule_version) INTO v_source_audit
    FROM public.list_product_schedule_operations(f.workspace_id, f.product_id, f.actor_id, NULL, 10) AS o;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY id) INTO v_source_activities
    FROM public.stage_activities AS a WHERE product_id = f.product_id;
  SELECT jsonb_agg(to_jsonb(s) ORDER BY id) INTO v_source_stages
    FROM public.discipline_stages AS s WHERE product_id = f.product_id;
  v_result := public.clone_product(f.workspace_id, f.product_id, gen_random_uuid(), v_name);
  IF v_result->>'status' IS DISTINCT FROM 'denied' THEN RAISE EXCEPTION 'Nonmember clone was not denied.'; END IF;
  v_result := public.clone_product(gen_random_uuid(), f.product_id, f.actor_id, v_name);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'Foreign workspace was not rejected.'; END IF;
  PERFORM set_config('jlproject.schedule_actor_id', f.actor_id::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_cloned', true);
  PERFORM set_config('jlproject.schedule_justification', 'Verify archived synthetic source cloning', true);
  v_result := public.clone_product(f.workspace_id, f.product_id, f.actor_id, v_name);
  IF v_result->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Archived clone failed: %', v_result; END IF;
  v_clone := (v_result->'product'->>'id')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_clone AND active AND planning_classification = 'em_estudo') THEN
    RAISE EXCEPTION 'Archived clone did not start as Em estudo.';
  END IF;
  SELECT snapshot INTO STRICT v_clone_r00 FROM public.initial_schedule_revisions
    WHERE product_id = v_clone AND label = 'R00' AND to_jsonb(id) <> v_source_r00->'id';
  IF (SELECT count(*) FROM public.stage_activities WHERE product_id = v_clone) <> 2 OR
     (SELECT count(*) FROM public.stage_activities AS original
      JOIN public.stage_activities AS copy ON copy.product_id = v_clone AND copy.name = original.name
      WHERE original.product_id = f.product_id AND copy.id <> original.id
        AND (copy.stage_id IS NULL) = (original.stage_id IS NULL)
        AND (copy.planned_start, copy.planned_end, copy.planning_mode, copy.working_day_duration, copy.planning_calendar_version)
          IS NOT DISTINCT FROM (original.planned_start, original.planned_end, original.planning_mode,
            original.working_day_duration, original.planning_calendar_version)) <> 2 OR
     (SELECT count(*) FROM public.stage_activities AS a
      CROSS JOIN LATERAL jsonb_array_elements((v_clone_r00->'rootActivities') ||
        (v_clone_r00 #> '{disciplines,0,stages,0,activities}')) AS entry(value)
      WHERE a.product_id = v_clone AND entry.value @> jsonb_build_object('id', a.id,
        'plannedStart', a.planned_start, 'plannedEnd', a.planned_end, 'planningMode', a.planning_mode,
        'workingDayDuration', a.working_day_duration, 'planningCalendarVersion', a.planning_calendar_version)) <> 2 OR
     v_clone_r00 #>> '{disciplines,0,stages,0,plannedStart}' IS DISTINCT FROM '2030-02-04' OR
     v_clone_r00 #>> '{disciplines,0,stages,0,plannedEnd}' IS DISTINCT FROM '2030-02-08' THEN
    RAISE EXCEPTION 'Archived clone activities or new R00 differ from the initial schedule.';
  END IF;
  IF (SELECT to_jsonb(p) FROM public.products AS p WHERE id = f.product_id) IS DISTINCT FROM v_product OR
     (SELECT to_jsonb(r) FROM public.initial_schedule_revisions AS r WHERE product_id = f.product_id AND label = 'R00')
       IS DISTINCT FROM v_source_r00 OR
     (SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.stage_activities AS a WHERE product_id = f.product_id)
       IS DISTINCT FROM v_source_activities OR
     (SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.discipline_stages AS s WHERE product_id = f.product_id)
       IS DISTINCT FROM v_source_stages OR
     (SELECT jsonb_agg(to_jsonb(o) ORDER BY schedule_version)
      FROM public.list_product_schedule_operations(f.workspace_id, f.product_id, f.actor_id, NULL, 10) AS o)
       IS DISTINCT FROM v_source_audit THEN
    RAISE EXCEPTION 'Archived source, baseline, or audit history changed.';
  END IF;
  IF (SELECT schedule_version FROM public.read_product_schedule_cursor(f.workspace_id, v_clone, f.actor_id))
       IS DISTINCT FROM 1 OR
     (SELECT count(*) FROM public.list_product_schedule_operations(f.workspace_id, v_clone, f.actor_id, NULL, 2)) <> 1 OR
     NOT EXISTS (SELECT 1 FROM public.list_product_schedule_operations(f.workspace_id, v_clone, f.actor_id, NULL, 2) AS o
       WHERE o.schedule_version = 1 AND o.actor_id = f.actor_id AND o.operation_type = 'product_cloned'
         AND (SELECT count(*) FROM jsonb_array_elements(o.events) AS e(value)
           WHERE e.value->>'entityType' = 'stage_activities') = 2) OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Archived clone audit grouping or baseline permissions failed.';
  END IF;
END;
$verify$;
ROLLBACK;
