BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;
GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- The caller holds the workspace calendar and product locks and has validated all proposals.
-- Calendar application changes finishes only, so an affected constraint always has a changed predecessor.
CREATE FUNCTION public.guard_calendar_reschedule_dependencies(p_workspace uuid, p_product uuid, p_proposals jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_edge record;
  v_successor_start date;
  v_previous_bound date;
  v_proposed_bound date;
  v_reason text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies
    WHERE workspace_id = p_workspace AND product_id = p_product) THEN RETURN NULL; END IF;

  FOR v_edge IN
    WITH proposed_activities AS MATERIALIZED (
      SELECT (item->>'activityId')::uuid AS id, (item->>'stageId')::uuid AS stage_id,
        (item->>'currentEndDate')::date AS previous_finish, (item->>'proposedEndDate')::date AS proposed_finish
      FROM jsonb_array_elements(p_proposals) AS item
    ), derived_predecessors AS (
      SELECT stage.id, stage.discipline_id
      FROM public.discipline_stages AS stage JOIN public.product_disciplines AS discipline
        ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
        AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
      WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.deleted_at IS NULL
        AND stage.planned_start IS NULL AND stage.planned_end IS NULL
        AND EXISTS (SELECT 1 FROM proposed_activities WHERE stage_id = stage.id)
        AND EXISTS (SELECT 1 FROM public.product_schedule_dependencies AS edge
          WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.predecessor_stage_id = stage.id)
    ), predecessor_finishes AS (
      SELECT 'activity'::text AS kind, id, previous_finish, proposed_finish FROM proposed_activities
      UNION ALL
      SELECT 'stage', parent.id, max(child.planned_end), max(COALESCE(proposed.proposed_finish, child.planned_end))
      FROM derived_predecessors AS parent JOIN public.stage_activities AS child
        ON child.workspace_id = p_workspace AND child.product_id = p_product AND child.discipline_id = parent.discipline_id
        AND child.stage_id = parent.id AND child.deleted_at IS NULL
      LEFT JOIN proposed_activities AS proposed ON proposed.id = child.id
      GROUP BY parent.id
    )
    SELECT edge.id, dates.kind, dates.id AS predecessor_id, dates.previous_finish, dates.proposed_finish,
      COALESCE(edge.successor_activity_id, edge.successor_stage_id) AS successor_id
    FROM predecessor_finishes AS dates JOIN public.product_schedule_dependencies AS edge
      ON edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = dates.kind
      AND (edge.predecessor_activity_id = dates.id OR edge.predecessor_stage_id = dates.id)
    WHERE dates.previous_finish IS DISTINCT FROM dates.proposed_finish
    ORDER BY edge.id
  LOOP
    SELECT effective.start_date INTO v_successor_start FROM public.dependency_effective_date_interval(
      p_workspace, p_product, v_edge.kind, v_edge.successor_id, NULL, NULL, NULL, NULL) AS effective;
    IF v_successor_start IS NULL THEN CONTINUE; END IF;
    v_previous_bound := public.dependency_first_working_start(p_workspace, v_edge.previous_finish);
    v_proposed_bound := public.dependency_first_working_start(p_workspace, v_edge.proposed_finish);
    v_reason := CASE
      WHEN v_proposed_bound IS NULL THEN 'calendar_range'
      WHEN v_successor_start < v_proposed_bound AND (v_previous_bound IS NULL OR v_proposed_bound > v_previous_bound)
        THEN 'finish_to_start' END;
    IF v_reason IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'dependency_conflict', 'conflict', jsonb_build_object(
        'dependencyId', v_edge.id, 'reason', v_reason,
        'predecessor', jsonb_build_object('id', v_edge.predecessor_id, 'kind', v_edge.kind),
        'successor', jsonb_build_object('id', v_edge.successor_id, 'kind', v_edge.kind),
        'before', jsonb_build_object('predecessorFinish', v_edge.previous_finish,
          'successorStart', v_successor_start, 'earliestStart', v_previous_bound),
        'after', jsonb_build_object('predecessorFinish', v_edge.proposed_finish,
          'successorStart', v_successor_start, 'earliestStart', v_proposed_bound)));
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

DO $install$
DECLARE
  v_source text := pg_get_functiondef('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure);
  v_write_loop constant text := $loop$  FOR v_item IN SELECT value FROM jsonb_array_elements(p_proposals) AS entry(value)
    ORDER BY value->>'activityId' LOOP
    SELECT * INTO STRICT v_activity FROM public.stage_activities$loop$;
  v_stale_check constant text := $stale$    IF v_activity.version <> (v_item->>'expectedVersion')::bigint OR
       v_activity.planning_mode <> 'working_days' OR
       v_activity.planned_start IS DISTINCT FROM (v_item->>'startDate')::date OR
       v_activity.planned_end IS DISTINCT FROM (v_item->>'currentEndDate')::date OR
       v_activity.working_day_duration IS DISTINCT FROM (v_item->>'workingDays')::integer OR
       v_activity.planning_calendar_version IS DISTINCT FROM (v_item->>'savedCalendarVersion')::bigint OR$stale$;
  v_end_check constant text := $end$    IF (v_item->>'proposedEndDate')::date <= DATE '2025-12-31' OR$end$;
BEGIN
  IF length(v_source) - length(replace(v_source, v_write_loop, '')) <> length(v_write_loop)
     OR length(v_source) - length(replace(v_source, v_stale_check, '')) <> length(v_stale_check)
     OR length(v_source) - length(replace(v_source, v_end_check, '')) <> length(v_end_check)
     OR position('AND id = p_product_id AND active = true FOR UPDATE' IN v_source) = 0
     OR position('v_result := public.write_reviewed_activity_planning(' IN v_source) = 0
     OR position('public.guard_calendar_reschedule_dependencies(' IN v_source) <> 0 THEN
    RAISE EXCEPTION 'Calendar apply differs from the reviewed Phase 4B.3a routine.';
  END IF;

  -- SQL NULL must never waive an expected row version or planning field during validation.
  v_source := replace(v_source, v_stale_check, $stale$    IF v_activity.version IS DISTINCT FROM (v_item->>'expectedVersion')::bigint OR
       v_activity.planning_mode <> 'working_days' OR
       v_activity.planned_start IS DISTINCT FROM (v_item->>'startDate')::date OR
       v_activity.planned_end IS DISTINCT FROM (v_item->>'currentEndDate')::date OR
       v_activity.working_day_duration IS DISTINCT FROM (v_item->>'workingDays')::integer OR
       v_activity.planning_calendar_version IS DISTINCT FROM (v_item->>'savedCalendarVersion')::bigint OR$stale$);
  v_source := replace(v_source, v_end_check, $end$    IF v_item->>'proposedEndDate' IS NULL OR
$end$ || replace(v_end_check, '    IF ', '       '));
  EXECUTE replace(v_source, v_write_loop, $guard$  v_result := public.guard_calendar_reschedule_dependencies(p_workspace_id, p_product_id, p_proposals);
  IF v_result IS NOT NULL THEN RETURN v_result; END IF;
$guard$ || v_write_loop);
END;
$install$;

REVOKE ALL ON FUNCTION public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)
  FROM PUBLIC, jlproject_worker, neondb_owner;
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $check$
BEGIN
  IF NOT has_function_privilege('jlproject_worker',
      'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE')
     OR has_function_privilege('jlproject_worker', 'public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('jlproject_worker',
      'public.write_reviewed_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE')
     OR has_function_privilege('jlproject_worker',
      'public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)', 'EXECUTE')
     OR pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
     OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Calendar apply dependency privilege boundary is incorrect.';
  END IF;
END;
$check$;

COMMIT;
