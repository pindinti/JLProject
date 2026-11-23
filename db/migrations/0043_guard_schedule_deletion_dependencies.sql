BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

DO $preflight$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.product_schedule_dependencies') IS NULL OR
     to_regprocedure('public.dependency_first_working_start(uuid,date)') IS NULL OR
     to_regprocedure('public.dependency_effective_date_interval(uuid,uuid,text,uuid,text,uuid,date,date)') IS NULL OR
     to_regprocedure('public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)') IS NULL OR
     to_regprocedure('public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb)') IS NOT NULL OR
     to_regprocedure('public.dependency_stage_interval_after_deletion(uuid,uuid,uuid,jsonb)') IS NOT NULL OR
     to_regprocedure('public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)') IS NULL OR
     to_regprocedure('public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)') IS NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure) <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'deleted_at', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'deletion_operation_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'deleted_at', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'deletion_operation_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.product_disciplines', 'deleted_at', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.product_disciplines', 'deletion_operation_id', 'UPDATE') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_deletion_guard' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.discipline_stages'::regclass
       AND tgname = 'discipline_stages_deletion_guard' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.product_disciplines'::regclass
       AND tgname = 'product_disciplines_deletion_guard' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.schedule_deletion_events'::regclass
       AND tgname = 'schedule_deletion_events_immutable' AND tgenabled IN ('O', 'A')) OR
     position('Physical schedule deletion is forbidden.' IN pg_get_functiondef(
       'public.guard_schedule_deletion()'::regprocedure)) = 0 OR
     position('IF v_preview->>''status'' <> ''ok'' THEN' IN pg_get_functiondef(
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure)) = 0 OR
     position('public.guard_schedule_deletion_dependencies(' IN pg_get_functiondef(
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)'::regprocedure)) <> 0 OR
     position('public.guard_schedule_deletion_dependencies(' IN pg_get_functiondef(
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure)) <> 0 OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Schedule deletion dependency guard prerequisites differ from the reviewed dormant state.';
  END IF;
END;
$preflight$;

GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- Apply the complete deletion set to every derived stage before comparing any edge.
CREATE FUNCTION public.dependency_stage_interval_after_deletion(
  p_workspace uuid, p_product uuid, p_stage uuid, p_deleted_items jsonb
) RETURNS TABLE(start_date date, end_date date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
         THEN projected.start_date ELSE stage.planned_start END,
    CASE WHEN stage.planned_start IS NULL AND stage.planned_end IS NULL
         THEN projected.end_date ELSE stage.planned_end END
  FROM public.discipline_stages AS stage
  LEFT JOIN LATERAL (
    SELECT min(activity.planned_start) AS start_date, max(activity.planned_end) AS end_date
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
      AND activity.discipline_id IS NOT DISTINCT FROM stage.discipline_id
      AND activity.stage_id = stage.id AND activity.deleted_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
        WHERE removed.kind = 'activity' AND removed.id = activity.id)
  ) AS projected ON true
  WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product
    AND stage.id = p_stage AND stage.deleted_at IS NULL;
$$;

-- Never remove dependency edges implicitly. Then validate remaining stage edges against all
-- post-deletion child sets, including when both edge boundaries are affected by one subtree.
CREATE FUNCTION public.guard_schedule_deletion_dependencies(
  p_workspace uuid, p_product uuid, p_deleted_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
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
  SELECT edge.id, edge.endpoint_kind,
    COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id) AS predecessor_id,
    COALESCE(edge.successor_activity_id, edge.successor_stage_id) AS successor_id,
    (SELECT jsonb_build_object('id', endpoint.id, 'kind', endpoint.kind)
      FROM (VALUES (edge.predecessor_activity_id, 'activity'::text),
                   (edge.successor_activity_id, 'activity'::text),
                   (edge.predecessor_stage_id, 'stage'::text),
                   (edge.successor_stage_id, 'stage'::text)) AS endpoint(id, kind)
      JOIN jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
        ON removed.kind = endpoint.kind AND removed.id = endpoint.id
      ORDER BY endpoint.kind, endpoint.id LIMIT 1) AS linked_endpoint
  INTO v_edge
  FROM public.product_schedule_dependencies AS edge
  WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product
    AND EXISTS (SELECT 1
      FROM (VALUES (edge.predecessor_activity_id, 'activity'::text),
                   (edge.successor_activity_id, 'activity'::text),
                   (edge.predecessor_stage_id, 'stage'::text),
                   (edge.successor_stage_id, 'stage'::text)) AS endpoint(id, kind)
      JOIN jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
        ON removed.kind = endpoint.kind AND removed.id = endpoint.id)
  ORDER BY edge.id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'dependency_conflict', 'conflict', jsonb_build_object(
      'dependencyId', v_edge.id, 'reason', 'linked_endpoint',
      'predecessor', jsonb_build_object('id', v_edge.predecessor_id, 'kind', v_edge.endpoint_kind),
      'successor', jsonb_build_object('id', v_edge.successor_id, 'kind', v_edge.endpoint_kind),
      'linkedEndpoint', v_edge.linked_endpoint));
  END IF;

  FOR v_edge IN
    SELECT edge.id, edge.predecessor_stage_id, edge.successor_stage_id
    FROM public.product_schedule_dependencies AS edge
    WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = 'stage'
      AND (
        edge.predecessor_stage_id IN (SELECT activity.stage_id
          FROM jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
          JOIN public.stage_activities AS activity
            ON removed.kind = 'activity' AND removed.id = activity.id
          WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
            AND activity.deleted_at IS NULL AND activity.stage_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items) AS deleted_stage(kind text, id uuid, version bigint)
              WHERE deleted_stage.kind = 'stage' AND deleted_stage.id = activity.stage_id))
        OR edge.successor_stage_id IN (SELECT activity.stage_id
          FROM jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
          JOIN public.stage_activities AS activity
            ON removed.kind = 'activity' AND removed.id = activity.id
          WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
            AND activity.deleted_at IS NULL AND activity.stage_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items) AS deleted_stage(kind text, id uuid, version bigint)
              WHERE deleted_stage.kind = 'stage' AND deleted_stage.id = activity.stage_id))
      )
    ORDER BY edge.id
  LOOP
    SELECT effective.end_date INTO v_old_finish
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
      v_edge.predecessor_stage_id, NULL, NULL, NULL, NULL) AS effective;
    v_new_finish := v_old_finish;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
        JOIN public.stage_activities AS activity ON removed.kind = 'activity' AND removed.id = activity.id
      WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
        AND activity.stage_id = v_edge.predecessor_stage_id AND activity.deleted_at IS NULL) THEN
      SELECT projected.end_date INTO v_new_finish
      FROM public.dependency_stage_interval_after_deletion(p_workspace, p_product,
        v_edge.predecessor_stage_id, p_deleted_items) AS projected;
    END IF;

    SELECT effective.start_date INTO v_old_start
    FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
      v_edge.successor_stage_id, NULL, NULL, NULL, NULL) AS effective;
    v_new_start := v_old_start;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items) AS removed(kind text, id uuid, version bigint)
        JOIN public.stage_activities AS activity ON removed.kind = 'activity' AND removed.id = activity.id
      WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
        AND activity.stage_id = v_edge.successor_stage_id AND activity.deleted_at IS NULL) THEN
      SELECT projected.start_date INTO v_new_start
      FROM public.dependency_stage_interval_after_deletion(p_workspace, p_product,
        v_edge.successor_stage_id, p_deleted_items) AS projected;
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
  v_preview_source text := pg_get_functiondef(
    'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)'::regprocedure);
  v_delete_source text := pg_get_functiondef(
    'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure);
  v_preview_declaration constant text := 'DECLARE v_items jsonb; v_role text;';
  v_preview_return constant text := '  RETURN jsonb_build_object(''status'', ''ok'', ''fingerprint'', md5(v_items::text),';
  v_workspace_lock constant text := '  PERFORM 1 FROM public.workspace_memberships AS m';
  v_delete_declaration constant text := 'DECLARE v_preview jsonb; v_id uuid; v_count integer; v_expected integer;';
  v_preview_status constant text := '  IF v_preview->>''status'' <> ''ok'' THEN RETURN jsonb_build_object(''status'', v_preview->>''status''); END IF;';
  v_preview_call constant text := '  v_preview := public.preview_schedule_deletion(p_workspace_id,p_product_id,p_actor_id,p_kind,p_target_id);';
BEGIN
  IF length(v_preview_source) - length(replace(v_preview_source, v_preview_declaration, '')) <> length(v_preview_declaration) OR
     length(v_preview_source) - length(replace(v_preview_source, v_preview_return, '')) <> length(v_preview_return) OR
     length(v_delete_source) - length(replace(v_delete_source, v_workspace_lock, '')) <> length(v_workspace_lock) OR
     length(v_delete_source) - length(replace(v_delete_source, v_delete_declaration, '')) <> length(v_delete_declaration) OR
     length(v_delete_source) - length(replace(v_delete_source, v_preview_status, '')) <> length(v_preview_status) OR
     position(v_preview_call IN v_delete_source) = 0 OR
     v_preview_source NOT LIKE 'CREATE OR REPLACE FUNCTION public.preview_schedule_deletion(%' OR
     v_delete_source NOT LIKE 'CREATE OR REPLACE FUNCTION public.delete_schedule_subtree(%' OR
     position('AND p.workspace_id = p_workspace_id AND p.active = true FOR UPDATE' IN v_delete_source) = 0 OR
     position('IF v_preview->>''fingerprint'' <> p_fingerprint THEN RETURN jsonb_build_object(''status'', ''stale''); END IF;' IN v_delete_source) = 0 OR
     position('INSERT INTO public.schedule_deletion_events' IN v_delete_source) = 0 OR
     position('public.guard_schedule_deletion_dependencies(' IN v_preview_source) <> 0 OR
     position('public.guard_schedule_deletion_dependencies(' IN v_delete_source) <> 0 THEN
    RAISE EXCEPTION 'Installed schedule deletion functions differ from the reviewed authorization, fingerprint, and write anchors.';
  END IF;

  v_preview_source := replace(v_preview_source, v_preview_declaration,
    'DECLARE v_items jsonb; v_role text; v_dependency_conflict jsonb;');
  v_preview_source := replace(v_preview_source, v_preview_return, $guard$
  v_dependency_conflict := public.guard_schedule_deletion_dependencies(p_workspace_id, p_product_id, v_items);
  IF v_dependency_conflict IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'dependency_conflict', 'fingerprint', md5(v_items::text),
      'conflict', v_dependency_conflict->'conflict');
  END IF;
  RETURN jsonb_build_object('status', 'ok', 'fingerprint', md5(v_items::text),$guard$);
  EXECUTE v_preview_source;

  v_delete_source := replace(v_delete_source, v_delete_declaration,
    'DECLARE v_preview jsonb; v_id uuid; v_count integer; v_expected integer;');
  v_delete_source := replace(v_delete_source, v_workspace_lock, $lock$
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships AS m$lock$);
  v_delete_source := replace(v_delete_source, v_preview_status, $conflict$
  IF v_preview->>'status' = 'dependency_conflict' THEN
    IF v_preview->>'fingerprint' <> p_fingerprint THEN RETURN jsonb_build_object('status', 'stale'); END IF;
    RETURN v_preview;
  END IF;
  IF v_preview->>'status' <> 'ok' THEN RETURN jsonb_build_object('status', v_preview->>'status'); END IF;$conflict$);
  EXECUTE v_delete_source;
END;
$install$;

REVOKE ALL ON FUNCTION public.dependency_stage_interval_after_deletion(uuid,uuid,uuid,jsonb),
  public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb) FROM PUBLIC, jlproject_worker, neondb_owner;
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $postflight$
DECLARE
  v_failed text[];
  v_preview_definition text := pg_get_functiondef(
    'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)'::regprocedure);
  v_delete_definition text := pg_get_functiondef(
    'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure);
  v_preview_call constant text :=
    'v_preview := public.preview_schedule_deletion(p_workspace_id,p_product_id,p_actor_id,p_kind,p_target_id);';
  v_conflict_handler constant text := 'IF v_preview->>''status'' = ''dependency_conflict'' THEN';
  v_conflict_stale_check constant text :=
    'IF v_preview->>''fingerprint'' <> p_fingerprint THEN RETURN jsonb_build_object(''status'', ''stale''); END IF;';
  v_conflict_return constant text := 'RETURN v_preview;';
BEGIN
  SELECT COALESCE(array_agg(checks.name ORDER BY checks.name), ARRAY[]::text[])
  INTO v_failed
  FROM (VALUES
    ('dependency_stage_interval_after_deletion_owner',
      (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
        'public.dependency_stage_interval_after_deletion(uuid,uuid,uuid,jsonb)'::regprocedure)
        IS DISTINCT FROM 'jlproject_date_executor'),
    ('guard_schedule_deletion_dependencies_owner',
      (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
        'public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb)'::regprocedure)
        IS DISTINCT FROM 'jlproject_date_executor'),
    ('preview_calls_deletion_guard',
      position('public.guard_schedule_deletion_dependencies(' IN v_preview_definition) = 0),
    ('delete_invokes_guarded_preview',
      position(v_preview_call IN v_delete_definition) = 0 OR
      position(v_preview_call IN v_delete_definition) >=
        position(v_conflict_handler IN v_delete_definition)),
    ('delete_handles_dependency_conflict_before_writes',
      position(v_conflict_handler IN v_delete_definition) = 0 OR
      position(v_conflict_stale_check IN v_delete_definition) <=
        position(v_conflict_handler IN v_delete_definition) OR
      position(v_conflict_return IN v_delete_definition) <=
        position(v_conflict_stale_check IN v_delete_definition) OR
      position(v_conflict_handler IN v_delete_definition) >=
        position('INSERT INTO public.schedule_deletion_events' IN v_delete_definition) OR
      position(v_conflict_handler IN v_delete_definition) >=
        position('UPDATE public.stage_activities AS a SET deleted_at =' IN v_delete_definition) OR
      position(v_conflict_handler IN v_delete_definition) >=
        position('UPDATE public.discipline_stages AS s SET deleted_at =' IN v_delete_definition) OR
      position(v_conflict_handler IN v_delete_definition) >=
        position('UPDATE public.product_disciplines AS d SET deleted_at =' IN v_delete_definition)),
    ('delete_takes_workspace_lock',
      position('PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE' IN v_delete_definition) = 0),
    ('worker_cannot_execute_deletion_guard',
      has_function_privilege('jlproject_worker',
        'public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb)', 'EXECUTE') IS DISTINCT FROM false),
    ('worker_cannot_execute_stage_interval_helper',
      has_function_privilege('jlproject_worker',
        'public.dependency_stage_interval_after_deletion(uuid,uuid,uuid,jsonb)', 'EXECUTE') IS DISTINCT FROM false),
    ('worker_can_execute_preview',
      has_function_privilege('jlproject_worker',
        'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') IS DISTINCT FROM true),
    ('worker_can_execute_delete',
      has_function_privilege('jlproject_worker',
        'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') IS DISTINCT FROM true),
    ('worker_cannot_update_activity_deleted_at',
      has_column_privilege('jlproject_worker', 'public.stage_activities', 'deleted_at', 'UPDATE') IS DISTINCT FROM false),
    ('worker_cannot_update_stage_deleted_at',
      has_column_privilege('jlproject_worker', 'public.discipline_stages', 'deleted_at', 'UPDATE') IS DISTINCT FROM false),
    ('worker_cannot_update_discipline_deleted_at',
      has_column_privilege('jlproject_worker', 'public.product_disciplines', 'deleted_at', 'UPDATE') IS DISTINCT FROM false),
    ('worker_is_not_date_executor_member',
      pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') IS DISTINCT FROM false),
    ('owner_cannot_set_date_executor',
      pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') IS DISTINCT FROM false),
    ('date_executor_has_no_public_create',
      has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') IS DISTINCT FROM false)
  ) AS checks(name, failed)
  WHERE checks.failed IS DISTINCT FROM false;

  IF cardinality(v_failed) > 0 THEN
    RAISE EXCEPTION 'Schedule deletion dependency guard postflight failed.'
      USING DETAIL = array_to_string(v_failed, ', ');
  END IF;
END;
$postflight$;

COMMIT;
