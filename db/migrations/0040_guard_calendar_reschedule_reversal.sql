BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

DO $prerequisite$
BEGIN
  IF to_regprocedure('public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)') IS NULL
     OR position('public.guard_calendar_reschedule_dependencies(' IN pg_get_functiondef(
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'The guarded calendar apply migration is required before calendar reversal protection.';
  END IF;
END;
$prerequisite$;

GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- Both calendar writers validate their own inputs before calling this guard under the same locks.
-- Apply supplies unchanged starts. Reversal supplies both boundaries from the checked historical row.
CREATE OR REPLACE FUNCTION public.guard_calendar_reschedule_dependencies(p_workspace uuid, p_product uuid, p_proposals jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_edge record;
  v_old_finish date;
  v_new_finish date;
  v_old_start date;
  v_new_start date;
  v_old_bound date;
  v_new_bound date;
  v_reason text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies
    WHERE workspace_id = p_workspace AND product_id = p_product) THEN RETURN NULL; END IF;

  FOR v_edge IN
    WITH proposed_activities AS MATERIALIZED (
      SELECT (item->>'activityId')::uuid AS id, (item->>'stageId')::uuid AS stage_id,
        (item->>'startDate')::date AS old_start, (item->>'currentEndDate')::date AS old_finish,
        COALESCE((item->>'proposedStartDate')::date, (item->>'startDate')::date) AS new_start,
        (item->>'proposedEndDate')::date AS new_finish
      FROM jsonb_array_elements(p_proposals) AS item
    ), derived_stages AS (
      SELECT stage.id, stage.discipline_id FROM public.discipline_stages AS stage
      JOIN public.product_disciplines AS discipline ON discipline.workspace_id = stage.workspace_id
        AND discipline.product_id = stage.product_id AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
      WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.deleted_at IS NULL
        AND stage.planned_start IS NULL AND stage.planned_end IS NULL
        AND EXISTS (SELECT 1 FROM proposed_activities WHERE stage_id = stage.id)
        AND EXISTS (SELECT 1 FROM public.product_schedule_dependencies AS edge
          WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product
            AND (edge.predecessor_stage_id = stage.id OR edge.successor_stage_id = stage.id))
    ), projected_intervals AS MATERIALIZED (
      SELECT 'activity'::text AS kind, id, old_start, old_finish, new_start, new_finish FROM proposed_activities
      UNION ALL
      SELECT 'stage', parent.id, min(child.planned_start), max(child.planned_end),
        min(COALESCE(proposed.new_start, child.planned_start)), max(COALESCE(proposed.new_finish, child.planned_end))
      FROM derived_stages AS parent JOIN public.stage_activities AS child
        ON child.workspace_id = p_workspace AND child.product_id = p_product AND child.discipline_id = parent.discipline_id
        AND child.stage_id = parent.id AND child.deleted_at IS NULL
      LEFT JOIN proposed_activities AS proposed ON proposed.id = child.id
      GROUP BY parent.id
    )
    SELECT edge.id, edge.endpoint_kind AS kind, COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id) AS predecessor_id,
      COALESCE(edge.successor_activity_id, edge.successor_stage_id) AS successor_id,
      predecessor.id IS NOT NULL AS predecessor_projected, predecessor.old_finish, predecessor.new_finish,
      successor.id IS NOT NULL AS successor_projected, successor.old_start, successor.new_start
    FROM public.product_schedule_dependencies AS edge
    LEFT JOIN projected_intervals AS predecessor ON predecessor.kind = edge.endpoint_kind
      AND predecessor.id = COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id)
    LEFT JOIN projected_intervals AS successor ON successor.kind = edge.endpoint_kind
      AND successor.id = COALESCE(edge.successor_activity_id, edge.successor_stage_id)
    WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product
      AND (predecessor.old_finish IS DISTINCT FROM predecessor.new_finish OR successor.old_start IS DISTINCT FROM successor.new_start)
    ORDER BY edge.id
  LOOP
    IF v_edge.predecessor_projected THEN
      v_old_finish := v_edge.old_finish;
      v_new_finish := v_edge.new_finish;
    ELSE
      SELECT effective.end_date INTO v_old_finish FROM public.dependency_effective_date_interval(
        p_workspace, p_product, v_edge.kind, v_edge.predecessor_id, NULL, NULL, NULL, NULL) AS effective;
      v_new_finish := v_old_finish;
    END IF;
    IF v_edge.successor_projected THEN
      v_old_start := v_edge.old_start;
      v_new_start := v_edge.new_start;
    ELSE
      SELECT effective.start_date INTO v_old_start FROM public.dependency_effective_date_interval(
        p_workspace, p_product, v_edge.kind, v_edge.successor_id, NULL, NULL, NULL, NULL) AS effective;
      v_new_start := v_old_start;
    END IF;
    v_old_bound := public.dependency_first_working_start(p_workspace, v_old_finish);
    v_new_bound := CASE WHEN v_new_finish IS NOT DISTINCT FROM v_old_finish THEN v_old_bound
      ELSE public.dependency_first_working_start(p_workspace, v_new_finish) END;
    v_reason := CASE
      WHEN v_old_finish IS NOT NULL AND v_new_finish IS NULL OR v_old_start IS NOT NULL AND v_new_start IS NULL
        THEN 'missing_boundary'
      WHEN v_new_finish IS NULL OR v_new_start IS NULL THEN NULL
      WHEN v_new_bound IS NULL THEN 'calendar_range'
      WHEN v_new_start < v_new_bound AND (v_old_start IS NULL OR v_old_bound IS NULL
        OR v_new_bound - v_new_start > v_old_bound - v_old_start) THEN 'finish_to_start' END;
    IF v_reason IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'dependency_conflict', 'conflict', jsonb_build_object(
        'dependencyId', v_edge.id, 'reason', v_reason,
        'predecessor', jsonb_build_object('id', v_edge.predecessor_id, 'kind', v_edge.kind),
        'successor', jsonb_build_object('id', v_edge.successor_id, 'kind', v_edge.kind),
        'before', jsonb_build_object('predecessorFinish', v_old_finish, 'successorStart', v_old_start, 'earliestStart', v_old_bound),
        'after', jsonb_build_object('predecessorFinish', v_new_finish, 'successorStart', v_new_start, 'earliestStart', v_new_bound)));
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

DO $install$
DECLARE
  v_source text := pg_get_functiondef('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)'::regprocedure);
  v_variables constant text := '  v_affected integer;';
  v_row_lock constant text := '        AND id = v_change.activity_id FOR UPDATE;';
  v_stale constant text := '    IF NOT FOUND OR v_activity.version <> v_change.version_after OR';
  v_write_loop constant text := $loop$  FOR v_change IN
    SELECT c.*, d.discipline_id, d.stage_id
    FROM public.calendar_reschedule_changes AS c$loop$;
BEGIN
  IF length(v_source) - length(replace(v_source, v_variables, '')) <> length(v_variables)
     OR length(v_source) - length(replace(v_source, v_row_lock, '')) <> length(v_row_lock)
     OR length(v_source) - length(replace(v_source, v_stale, '')) <> length(v_stale)
     OR length(v_source) - length(replace(v_source, v_write_loop, '')) <> length(v_write_loop)
     OR position('AND id = p_product_id AND active = true FOR UPDATE' IN v_source) = 0
     OR position('IF v_change.audit_matches IS NOT TRUE THEN' IN v_source) = 0
     OR position('public.guard_calendar_reschedule_dependencies(' IN v_source) <> 0 THEN
    RAISE EXCEPTION 'Calendar reversal differs from the reviewed audited routine.';
  END IF;
  v_source := replace(v_source, v_variables, v_variables || E'\n  v_proposals jsonb;\n  v_conflict jsonb;');
  v_source := replace(v_source, v_row_lock, '        AND id = v_change.activity_id AND deleted_at IS NULL FOR UPDATE;');
  v_source := replace(v_source, v_stale,
    '    IF NOT FOUND OR v_change.version_after IS NULL OR v_activity.version IS DISTINCT FROM v_change.version_after OR');
  EXECUTE replace(v_source, v_write_loop, $guard$  IF EXISTS (SELECT 1 FROM public.product_schedule_dependencies
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id) THEN
    SELECT jsonb_agg(jsonb_build_object('activityId', c.activity_id, 'stageId', d.stage_id,
      'startDate', c.new_start, 'currentEndDate', c.new_end,
      'proposedStartDate', c.previous_start, 'proposedEndDate', c.previous_end) ORDER BY c.activity_id)
    INTO v_proposals FROM public.calendar_reschedule_changes AS c
    JOIN public.activity_date_changes AS d ON d.operation_id = c.date_operation_id
    WHERE c.workspace_id = p_workspace_id AND c.product_id = p_product_id AND c.batch_operation_id = p_original_batch_id;
    IF jsonb_array_length(v_proposals) IS DISTINCT FROM v_count THEN
      RAISE EXCEPTION 'Original calendar reschedule audit is incomplete.' USING ERRCODE = '23514';
    END IF;
    v_conflict := public.guard_calendar_reschedule_dependencies(p_workspace_id, p_product_id, v_proposals);
    IF v_conflict IS NOT NULL THEN RETURN v_conflict; END IF;
  END IF;
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
  IF NOT has_function_privilege('jlproject_worker', 'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('public', 'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('jlproject_worker', 'public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('jlproject_worker',
      'public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)', 'EXECUTE')
     OR pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
     OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Calendar reversal dependency privilege boundary is incorrect.';
  END IF;
END;
$check$;

COMMIT;
