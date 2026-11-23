BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

DO $preflight$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.product_schedule_dependencies') IS NULL OR
     to_regprocedure('public.dependency_first_working_start(uuid,date)') IS NULL OR
     to_regprocedure('public.dependency_effective_date_interval(uuid,uuid,text,uuid,text,uuid,date,date)') IS NULL OR
     to_regprocedure('public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_activity_creation_dependency_guard' AND tgenabled IN ('O', 'A')) OR
     to_regprocedure('public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)') IS NOT NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'discipline_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'discipline_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'display_order', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'display_order', 'UPDATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Hierarchy movement dependency guard prerequisites differ from the reviewed dormant state.';
  END IF;
END;
$preflight$;

GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- Project source removal and destination addition together before evaluating
-- any stage edge. D065 explicit and partial intervals remain authoritative.
CREATE FUNCTION public.guard_activity_reparent_dependencies(
  p_workspace uuid, p_product uuid, p_activity uuid, p_source_stage uuid, p_destination_stage uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_activity public.stage_activities%ROWTYPE;
  v_edge record;
  v_source_before_start date;
  v_source_before_end date;
  v_source_after_start date;
  v_source_after_end date;
  v_destination_before_start date;
  v_destination_before_end date;
  v_destination_after_start date;
  v_destination_after_end date;
  v_old_finish date;
  v_new_finish date;
  v_old_start date;
  v_new_start date;
  v_old_bound date;
  v_new_bound date;
  v_reason text;
BEGIN
  IF p_source_stage IS NOT DISTINCT FROM p_destination_stage OR
     p_source_stage IS NULL AND p_destination_stage IS NULL OR
     NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies AS edge
       WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = 'stage'
         AND (edge.predecessor_stage_id = p_source_stage OR edge.successor_stage_id = p_source_stage OR
           edge.predecessor_stage_id = p_destination_stage OR edge.successor_stage_id = p_destination_stage)) THEN
    RETURN NULL;
  END IF;

  SELECT activity.* INTO v_activity FROM public.stage_activities AS activity
  WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
    AND activity.id = p_activity AND activity.deleted_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF p_source_stage IS NOT NULL THEN
    SELECT effective.start_date, effective.end_date INTO v_source_before_start, v_source_before_end
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage', p_source_stage,
      NULL, NULL, NULL, NULL) AS effective;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
          THEN projected.start_date ELSE stage.planned_start END,
      CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
          THEN projected.end_date ELSE stage.planned_end END
    INTO v_source_after_start, v_source_after_end
    FROM public.discipline_stages AS stage
    LEFT JOIN LATERAL (
      SELECT min(child.planned_start) AS start_date, max(child.planned_end) AS end_date
      FROM public.stage_activities AS child
      WHERE child.workspace_id = p_workspace AND child.product_id = p_product
        AND child.discipline_id IS NOT DISTINCT FROM stage.discipline_id
        AND child.stage_id = stage.id AND child.deleted_at IS NULL AND child.id <> p_activity
    ) AS projected ON true
    WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product
      AND stage.id = p_source_stage AND stage.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;

  IF p_destination_stage IS NOT NULL THEN
    SELECT effective.start_date, effective.end_date INTO v_destination_before_start, v_destination_before_end
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage', p_destination_stage,
      NULL, NULL, NULL, NULL) AS effective;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
          THEN projected.start_date ELSE stage.planned_start END,
      CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
          THEN projected.end_date ELSE stage.planned_end END
    INTO v_destination_after_start, v_destination_after_end
    FROM public.discipline_stages AS stage
    LEFT JOIN LATERAL (
      SELECT min(projected_range.start_date) AS start_date, max(projected_range.end_date) AS end_date
      FROM (
        SELECT child.planned_start AS start_date, child.planned_end AS end_date
        FROM public.stage_activities AS child
        WHERE child.workspace_id = p_workspace AND child.product_id = p_product
          AND child.discipline_id IS NOT DISTINCT FROM stage.discipline_id
          AND child.stage_id = stage.id AND child.deleted_at IS NULL
        UNION ALL
        SELECT v_activity.planned_start, v_activity.planned_end
      ) AS projected_range
    ) AS projected ON true
    WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product
      AND stage.id = p_destination_stage AND stage.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;

  FOR v_edge IN
    SELECT edge.id, edge.predecessor_stage_id, edge.successor_stage_id
    FROM public.product_schedule_dependencies AS edge
    WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = 'stage'
      AND (edge.predecessor_stage_id = p_source_stage OR edge.successor_stage_id = p_source_stage OR
        edge.predecessor_stage_id = p_destination_stage OR edge.successor_stage_id = p_destination_stage)
    ORDER BY edge.id
  LOOP
    SELECT effective.end_date INTO v_old_finish
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
      v_edge.predecessor_stage_id, NULL, NULL, NULL, NULL) AS effective;
    v_new_finish := v_old_finish;
    IF v_edge.predecessor_stage_id = p_source_stage THEN
      v_old_finish := v_source_before_end;
      v_new_finish := v_source_after_end;
    ELSIF v_edge.predecessor_stage_id = p_destination_stage THEN
      v_old_finish := v_destination_before_end;
      v_new_finish := v_destination_after_end;
    END IF;

    SELECT effective.start_date INTO v_old_start
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
      v_edge.successor_stage_id, NULL, NULL, NULL, NULL) AS effective;
    v_new_start := v_old_start;
    IF v_edge.successor_stage_id = p_source_stage THEN
      v_old_start := v_source_before_start;
      v_new_start := v_source_after_start;
    ELSIF v_edge.successor_stage_id = p_destination_stage THEN
      v_old_start := v_destination_before_start;
      v_new_start := v_destination_after_start;
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
        'predecessor', jsonb_build_object('id', v_edge.predecessor_stage_id, 'kind', 'stage'),
        'successor', jsonb_build_object('id', v_edge.successor_stage_id, 'kind', 'stage'),
        'before', jsonb_build_object('predecessorFinish', v_old_finish,
          'successorStart', v_old_start, 'earliestStart', v_old_bound),
        'after', jsonb_build_object('predecessorFinish', v_new_finish,
          'successorStart', v_new_start, 'earliestStart', v_new_bound)));
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

DO $install$
DECLARE
  v_source text := pg_get_functiondef(
    'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure);
  v_declaration constant text := '  v_descendants jsonb := ''[]''::jsonb;';
  v_audit_anchor constant text := '  PERFORM set_config(''jlproject.hierarchy_operation_id'', p_operation_id::text, true);';
BEGIN
  IF length(v_source) - length(replace(v_source, v_declaration, '')) <> length(v_declaration) OR
     length(v_source) - length(replace(v_source, v_audit_anchor, '')) <> length(v_audit_anchor) OR
     v_source NOT LIKE 'CREATE OR REPLACE FUNCTION public.move_schedule_item(%' OR
     position('IF v_same_parent AND v_source_before = v_source_after THEN' IN v_source) = 0 OR
     position('IF v_version <> p_expected_version THEN RETURN jsonb_build_object(''status'', ''stale''); END IF;' IN v_source) = 0 OR
     position('UPDATE public.stage_activities AS item SET' IN v_source) = 0 OR
     position('public.guard_activity_reparent_dependencies(' IN v_source) <> 0 THEN
    RAISE EXCEPTION 'Installed hierarchy movement function differs from the reviewed source and audit anchors.';
  END IF;
  v_source := replace(v_source, v_declaration, v_declaration || E'\n  v_dependency_conflict jsonb;');
  v_source := replace(v_source, v_audit_anchor, $guard$
  IF p_kind = 'activity' AND NOT v_same_parent THEN
    v_dependency_conflict := public.guard_activity_reparent_dependencies(p_workspace_id, p_product_id,
      p_target_id, v_original_stage_id, p_destination_stage_id);
    IF v_dependency_conflict IS NOT NULL THEN RETURN v_dependency_conflict; END IF;
  END IF;
  PERFORM set_config('jlproject.hierarchy_operation_id', p_operation_id::text, true);$guard$);
  EXECUTE v_source;
END;
$install$;

REVOKE ALL ON FUNCTION public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)
  FROM PUBLIC, jlproject_worker, neondb_owner;
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $postflight$
BEGIN
  IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure)
       <> 'jlproject_date_executor' OR
     position('public.guard_activity_reparent_dependencies(' IN pg_get_functiondef(
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure)) = 0 OR
     has_function_privilege('jlproject_worker',
       'public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Hierarchy movement dependency guard privileges or writer integration are incorrect.';
  END IF;
END;
$postflight$;

COMMIT;
