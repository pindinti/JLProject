BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

-- Install dormant routines. Phase 4B.3 must close legacy bypasses before granting execution.
GRANT jlproject_calendar_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
SET ROLE jlproject_calendar_executor;
GRANT SELECT (id, workspace_id, kind, start_date, end_date, removed_at)
  ON public.workspace_calendar_exceptions TO jlproject_date_executor;
RESET ROLE;
REVOKE jlproject_calendar_executor FROM neondb_owner GRANTED BY neondb_owner;

GRANT SELECT, INSERT, DELETE ON public.product_schedule_dependencies TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

CREATE FUNCTION public.read_schedule_dependencies(p_workspace uuid, p_product uuid, p_actor uuid, p_graph_only boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_status text;
  v_version bigint;
  v_watermark bigint;
  v_edges jsonb;
  v_entities jsonb;
  v_targets jsonb;
  v_exceptions jsonb;
  v_snapshot jsonb;
BEGIN
  IF p_graph_only IS NULL THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace
      AND auth_user_id = p_actor AND active AND (p_graph_only OR role IN ('editor', 'admin'))) THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  SELECT CASE WHEN NOT p.active THEN 'arquivado' ELSE p.planning_classification END,
    state.schedule_version, state.history_watermark INTO v_status, v_version, v_watermark
  FROM public.products AS p JOIN public.product_schedule_state AS state
    ON state.workspace_id = p.workspace_id AND state.product_id = p.id
  WHERE p.workspace_id = p_workspace AND p.id = p_product;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF NOT p_graph_only AND v_status = 'arquivado' THEN RETURN jsonb_build_object('status', 'archived'); END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', edge.id,
    'predecessor', jsonb_build_object('productId', p_product, 'kind', edge.endpoint_kind,
      'id', COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id)),
    'successor', jsonb_build_object('productId', p_product, 'kind', edge.endpoint_kind,
      'id', COALESCE(edge.successor_activity_id, edge.successor_stage_id))) ORDER BY edge.id), '[]')
  INTO v_edges FROM (SELECT * FROM public.product_schedule_dependencies
    WHERE workspace_id = p_workspace AND product_id = p_product ORDER BY id LIMIT 5001) AS edge;
  IF jsonb_array_length(v_edges) > 5000 THEN RETURN jsonb_build_object('status', 'too_large'); END IF;
  IF p_graph_only THEN
    RETURN jsonb_build_object('status', 'ok', 'graph', jsonb_build_object('productId', p_product, 'status', v_status,
      'cursor', jsonb_build_object('scheduleVersion', v_version::text, 'historyWatermark', v_watermark::text),
      'edges', v_edges));
  END IF;

  WITH active_stages AS MATERIALIZED (
    SELECT stage.id, stage.discipline_id, stage.version, stage.planned_start, stage.planned_end
    FROM public.discipline_stages AS stage JOIN public.product_disciplines AS discipline
      ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
      AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
    WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.deleted_at IS NULL
  ), entities AS (
    SELECT 'stage'::text AS kind, stage.id, jsonb_build_object('kind', 'stage', 'id', stage.id,
      'productId', p_product, 'version', stage.version, 'dates', jsonb_build_object(
        'start', to_char(stage.planned_start, 'YYYY-MM-DD'), 'end', to_char(stage.planned_end, 'YYYY-MM-DD'))) AS value
    FROM active_stages AS stage
    UNION ALL
    SELECT 'activity', a.id, jsonb_build_object('kind', 'activity', 'id', a.id, 'productId', p_product,
      'version', a.version, 'stageId', a.stage_id, 'dates', jsonb_build_object(
        'start', to_char(a.planned_start, 'YYYY-MM-DD'), 'end', to_char(a.planned_end, 'YYYY-MM-DD')),
      'planning', CASE WHEN a.planning_mode = 'working_days' THEN jsonb_build_object('mode', a.planning_mode,
        'duration', a.working_day_duration, 'calendarVersion', a.planning_calendar_version)
        ELSE jsonb_build_object('mode', 'manual') END)
    FROM public.stage_activities AS a
    WHERE a.workspace_id = p_workspace AND a.product_id = p_product AND a.deleted_at IS NULL
      AND (a.stage_id IS NULL AND a.discipline_id IS NULL OR EXISTS (SELECT 1 FROM active_stages AS stage
        WHERE stage.id = a.stage_id AND stage.discipline_id = a.discipline_id))
  )
  SELECT COALESCE(jsonb_agg(value ORDER BY kind, id), '[]') INTO v_entities
  FROM (SELECT * FROM entities ORDER BY kind, id LIMIT 2001) AS bounded;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', target.id, 'date', to_char(target.target_date, 'YYYY-MM-DD'))
    ORDER BY target.id), '[]') INTO v_targets FROM (SELECT id, target_date FROM public.business_targets
      WHERE workspace_id = p_workspace AND product_id = p_product AND deleted_at IS NULL ORDER BY id LIMIT 2001) AS target;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', item.kind, 'startDate', to_char(item.start_date, 'YYYY-MM-DD'),
    'endDate', to_char(item.end_date, 'YYYY-MM-DD')) ORDER BY item.id), '[]') INTO v_exceptions
  FROM (SELECT id, kind, start_date, end_date FROM public.workspace_calendar_exceptions
    WHERE workspace_id = p_workspace AND removed_at IS NULL ORDER BY id LIMIT 2001) AS item;
  IF greatest(jsonb_array_length(v_entities), jsonb_array_length(v_targets), jsonb_array_length(v_exceptions)) > 2000 THEN
    RETURN jsonb_build_object('status', 'too_large');
  END IF;

  v_snapshot := jsonb_build_object('productId', p_product, 'scheduleVersion', v_version::text,
    'entities', v_entities, 'dependencies', v_edges, 'targets', v_targets, 'calendar', jsonb_build_object(
      'version', COALESCE((SELECT version FROM public.workspace_calendar_versions WHERE workspace_id = p_workspace), 0),
      'exceptions', v_exceptions));
  RETURN jsonb_build_object('status', 'ok', 'snapshot', v_snapshot,
    'fingerprint', encode(sha256(convert_to(v_snapshot::text, 'UTF8')), 'hex'));
END;
$$;

CREATE FUNCTION public.read_schedule_dependency_receipt(p_workspace uuid, p_product uuid, p_actor uuid,
  p_operation uuid, p_version bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_operation public.product_schedule_operations%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace
      AND auth_user_id = p_actor AND active AND role IN ('editor', 'admin')) THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  SELECT * INTO v_operation FROM public.product_schedule_operations
    WHERE workspace_id = p_workspace AND product_id = p_product AND operation_id = p_operation;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'missing'); END IF;
  IF v_operation.actor_id IS DISTINCT FROM p_actor OR v_operation.operation_type <> 'schedule_dependencies_confirmed'
     OR v_operation.justification IS DISTINCT FROM p_reason OR v_operation.schedule_version - 1 IS DISTINCT FROM p_version THEN
    RETURN jsonb_build_object('status', 'conflict');
  END IF;
  RETURN jsonb_build_object('status', 'replayed', 'operationId', p_operation,
    'scheduleVersion', v_operation.schedule_version::text);
END;
$$;

CREATE FUNCTION public.confirm_schedule_dependencies(p_workspace uuid, p_product uuid, p_actor uuid, p_operation uuid,
  p_version bigint, p_calendar_version bigint, p_fingerprint text, p_reason text, p_changes jsonb, p_edge_change jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_receipt jsonb;
  v_active boolean;
  v_read jsonb;
  v_snapshot jsonb;
  v_edge jsonb;
  v_edge_action text;
  v_edge_id uuid;
  v_edge_kind text;
  v_from uuid;
  v_to uuid;
  v_change jsonb;
  v_saved jsonb;
  v_kind text;
  v_id uuid;
  v_seen text[] := ARRAY[]::text[];
  v_start date;
  v_end date;
  v_expected bigint;
  v_discipline uuid;
  v_stage uuid;
  v_planning jsonb;
  v_changed jsonb;
  v_ledger text;
  v_source_operation uuid;
  v_event uuid;
  v_new_version bigint;
BEGIN
  IF p_workspace IS NULL OR p_product IS NULL OR p_actor IS NULL OR p_operation IS NULL
     OR p_version IS NULL OR p_version < 0 OR p_calendar_version IS NULL OR p_calendar_version < 0
     OR p_fingerprint IS NULL OR p_fingerprint !~ '^[0-9a-f]{64}$'
     OR p_reason IS NULL OR p_reason <> btrim(p_reason) OR char_length(p_reason) NOT BETWEEN 10 AND 2000
     OR p_reason ~ '[[:cntrl:]]' OR jsonb_typeof(p_changes) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF jsonb_array_length(p_changes) > 50 OR (p_edge_change IS NULL OR p_edge_change = 'null')
      AND jsonb_array_length(p_changes) = 0 THEN RETURN jsonb_build_object('status', 'invalid'); END IF;

  PERFORM 1 FROM public.workspaces WHERE id = p_workspace FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace AND auth_user_id = p_actor
    AND active AND role IN ('editor', 'admin') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;
  SELECT active INTO v_active FROM public.products WHERE workspace_id = p_workspace AND id = p_product FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  v_receipt := public.read_schedule_dependency_receipt(p_workspace, p_product, p_actor, p_operation, p_version, p_reason);
  IF v_receipt->>'status' <> 'missing' THEN RETURN v_receipt; END IF;
  IF NOT v_active THEN RETURN jsonb_build_object('status', 'archived'); END IF;

  -- Refresh the snapshot after obtaining the calendar, membership and product locks.
  v_read := public.read_schedule_dependencies(p_workspace, p_product, p_actor, false);
  v_snapshot := v_read->'snapshot';
  IF v_read->>'status' <> 'ok' OR v_read->>'fingerprint' IS DISTINCT FROM p_fingerprint
     OR (v_snapshot->>'scheduleVersion')::bigint IS DISTINCT FROM p_version
     OR (v_snapshot#>>'{calendar,version}')::bigint IS DISTINCT FROM p_calendar_version THEN
    RETURN jsonb_build_object('status', 'stale');
  END IF;

  IF p_edge_change IS NOT NULL AND p_edge_change <> 'null' THEN
    v_edge_action := p_edge_change->>'kind';
    v_edge := p_edge_change->'dependency';
    v_edge_id := (v_edge->>'id')::uuid;
    v_edge_kind := v_edge#>>'{predecessor,kind}';
    v_from := (v_edge#>>'{predecessor,id}')::uuid;
    v_to := (v_edge#>>'{successor,id}')::uuid;
    IF v_edge_action IS NULL OR v_edge_action NOT IN ('add', 'remove') OR v_edge_id IS NULL
       OR v_edge_kind IS NULL OR v_edge_kind NOT IN ('activity', 'stage')
       OR v_edge_kind IS DISTINCT FROM (v_edge#>>'{successor,kind}')
       OR (v_edge#>>'{predecessor,productId}')::uuid IS DISTINCT FROM p_product
       OR (v_edge#>>'{successor,productId}')::uuid IS DISTINCT FROM p_product
       OR v_from IS NULL OR v_to IS NULL OR v_from = v_to THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
    IF v_edge_action = 'add' THEN
      IF (SELECT count(*) FROM jsonb_array_elements(v_snapshot->'entities') AS entity
          WHERE entity->>'kind' = v_edge_kind AND (entity->>'id')::uuid IN (v_from, v_to)
            AND CASE WHEN v_edge_kind = 'stage' AND entity#>>'{dates,start}' IS NULL AND entity#>>'{dates,end}' IS NULL
              THEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot->'entities') AS child
                WHERE child->>'stageId' = entity->>'id' AND CASE WHEN (entity->>'id')::uuid = v_from
                  THEN child#>>'{dates,end}' IS NOT NULL ELSE child#>>'{dates,start}' IS NOT NULL END)
              WHEN (entity->>'id')::uuid = v_from THEN entity#>>'{dates,end}' IS NOT NULL
              ELSE entity#>>'{dates,start}' IS NOT NULL END) <> 2 THEN
        RETURN jsonb_build_object('status', 'invalid');
      END IF;
      IF jsonb_array_length(v_snapshot->'dependencies') >= 5000 OR EXISTS (
        SELECT 1 FROM public.product_schedule_dependencies AS edge WHERE edge.workspace_id = p_workspace
          AND edge.product_id = p_product AND (edge.id = v_edge_id OR edge.endpoint_kind = v_edge_kind
            AND COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id) = v_from
            AND COALESCE(edge.successor_activity_id, edge.successor_stage_id) = v_to)) OR EXISTS (
        WITH RECURSIVE downstream(id) AS (
          SELECT v_to
          UNION
          SELECT COALESCE(edge.successor_activity_id, edge.successor_stage_id)
          FROM downstream JOIN public.product_schedule_dependencies AS edge
            ON COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id) = downstream.id
          WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = v_edge_kind
        ) SELECT 1 FROM downstream WHERE id = v_from
      ) THEN RETURN jsonb_build_object('status', 'conflict'); END IF;
    ELSIF NOT (v_snapshot->'dependencies' @> jsonb_build_array(v_edge)) THEN
      RETURN jsonb_build_object('status', 'stale');
    ELSIF jsonb_array_length(p_changes) <> 0 THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  END IF;

  -- Validate the entire reviewed manifest before the first write. Reused row writers recheck row versions.
  FOR v_change IN SELECT value FROM jsonb_array_elements(p_changes) LOOP
    v_kind := v_change#>>'{entity,kind}';
    v_id := (v_change#>>'{entity,id}')::uuid;
    v_expected := (v_change->>'expectedVersion')::bigint;
    v_start := (v_change#>>'{after,start}')::date;
    v_end := (v_change#>>'{after,end}')::date;
    v_planning := v_change->'planningAfter';
    IF v_kind IS NULL OR v_kind NOT IN ('activity', 'stage') OR v_id IS NULL
       OR (v_change#>>'{entity,productId}')::uuid IS DISTINCT FROM p_product
       OR (v_kind || ':' || v_id::text) = ANY(v_seen) OR v_expected IS NULL OR v_expected < 1
       OR jsonb_typeof(v_change->'after') IS DISTINCT FROM 'object' OR NOT (v_change->'after' ?& ARRAY['start','end'])
       OR v_start > v_end OR v_change->>'source' IS NULL OR v_change->>'source' NOT IN ('direct', 'cascade') THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    v_seen := array_append(v_seen, v_kind || ':' || v_id::text);
    SELECT entity INTO v_saved FROM jsonb_array_elements(v_snapshot->'entities') AS entity
      WHERE entity->>'kind' = v_kind AND (entity->>'id')::uuid = v_id;
    IF NOT FOUND OR (v_saved->>'version')::bigint IS DISTINCT FROM v_expected
       OR v_saved->'dates' IS DISTINCT FROM v_change->'before'
       OR COALESCE(v_saved->'planning', 'null'::jsonb) IS DISTINCT FROM (v_change->'planningBefore') THEN
      RETURN jsonb_build_object('status', 'stale');
    END IF;
    IF (v_kind = 'activity' AND (v_start IS NULL OR v_end IS NULL OR NOT COALESCE(
        v_planning = '{"mode":"manual"}' OR v_planning->>'mode' = 'working_days'
          AND (v_planning->>'duration')::integer BETWEEN 1 AND 27393
          AND (v_planning->>'calendarVersion')::bigint = p_calendar_version, false)))
       OR (v_kind = 'stage' AND v_planning IS DISTINCT FROM 'null'::jsonb)
       OR (v_change->>'source' = 'cascade' AND (
         v_start IS NULL OR v_end IS NULL OR v_saved#>>'{dates,start}' IS NULL OR v_saved#>>'{dates,end}' IS NULL
         OR v_start < (v_saved#>>'{dates,start}')::date OR v_end < (v_saved#>>'{dates,end}')::date
         OR v_kind = 'activity' AND ((v_planning->>'mode') IS DISTINCT FROM (v_saved#>>'{planning,mode}')
           OR (v_planning->>'duration') IS DISTINCT FROM (v_saved#>>'{planning,duration}')))) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  END LOOP;

  PERFORM set_config('jlproject.schedule_actor_id', p_actor::text, true),
    set_config('jlproject.schedule_operation_id', p_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_dependencies_confirmed', true),
    set_config('jlproject.schedule_justification', p_reason, true),
    set_config('jlproject.schedule_reversal_of', '', true);

  IF v_edge_action IS NOT NULL THEN
    IF v_edge_action = 'add' THEN
      INSERT INTO public.product_schedule_dependencies (id, workspace_id, product_id, endpoint_kind,
        predecessor_activity_id, successor_activity_id, predecessor_stage_id, successor_stage_id)
      VALUES (v_edge_id, p_workspace, p_product, v_edge_kind, CASE WHEN v_edge_kind = 'activity' THEN v_from END,
        CASE WHEN v_edge_kind = 'activity' THEN v_to END, CASE WHEN v_edge_kind = 'stage' THEN v_from END,
        CASE WHEN v_edge_kind = 'stage' THEN v_to END);
    ELSE
      DELETE FROM public.product_schedule_dependencies WHERE workspace_id = p_workspace AND product_id = p_product AND id = v_edge_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'Dependency changed during confirmation.' USING ERRCODE = '40001'; END IF;
    END IF;
    PERFORM public.write_product_schedule_operation_event(p_workspace, p_product, p_actor, p_operation,
      'schedule_dependencies_confirmed', p_reason, NULL, 'product_schedule_dependencies', v_edge_id,
      CASE WHEN v_edge_action = 'add' THEN 'dependency_added' ELSE 'dependency_removed' END, NULL, NULL,
      CASE WHEN v_edge_action = 'remove' THEN v_edge END, CASE WHEN v_edge_action = 'add' THEN v_edge END);
  END IF;

  FOR v_change IN SELECT value FROM jsonb_array_elements(p_changes)
      ORDER BY value#>>'{entity,kind}', value#>>'{entity,id}' LOOP
    v_kind := v_change#>>'{entity,kind}';
    v_id := (v_change#>>'{entity,id}')::uuid;
    v_expected := (v_change->>'expectedVersion')::bigint;
    v_start := (v_change#>>'{after,start}')::date;
    v_end := (v_change#>>'{after,end}')::date;
    IF v_kind = 'activity' THEN
      SELECT discipline_id, stage_id INTO STRICT v_discipline, v_stage FROM public.stage_activities
        WHERE workspace_id = p_workspace AND product_id = p_product AND id = v_id;
      v_planning := v_change->'planningAfter';
      v_ledger := 'activity_date_changes';
      v_source_operation := gen_random_uuid();
      v_changed := public.change_activity_planning(p_workspace, p_product, v_discipline, v_stage, v_id,
        p_actor, v_source_operation, v_planning->>'mode', v_start, v_end,
        (v_planning->>'duration')::integer, (v_planning->>'calendarVersion')::bigint, p_reason, v_expected);
    ELSE
      SELECT discipline_id INTO STRICT v_discipline FROM public.discipline_stages
        WHERE workspace_id = p_workspace AND product_id = p_product AND id = v_id;
      v_ledger := 'stage_date_changes';
      v_source_operation := p_operation;
      v_changed := public.change_discipline_stage_dates(p_workspace, p_product, v_discipline, v_id, p_actor,
        v_source_operation, v_start, v_end, p_reason, v_expected);
    END IF;
    IF v_changed->>'status' IS DISTINCT FROM 'updated' THEN
      RAISE EXCEPTION 'Reviewed dates changed during confirmation.' USING ERRCODE = '40001';
    END IF;

    -- The first specialized insert can precede the grouped header. Complete its exact link here.
    IF v_change->'before' IS DISTINCT FROM v_change->'after' THEN
      IF v_kind = 'activity' THEN
        SELECT audit.operation_id INTO STRICT v_event FROM public.activity_date_changes AS audit
          WHERE audit.workspace_id = p_workspace AND audit.product_id = p_product AND audit.activity_id = v_id
            AND audit.operation_id = v_source_operation AND audit.version_after = v_expected + 1 AND audit.actor_id = p_actor
            AND audit.previous_start IS NOT DISTINCT FROM (v_change#>>'{before,start}')::date
            AND audit.previous_end IS NOT DISTINCT FROM (v_change#>>'{before,end}')::date
            AND audit.new_start IS NOT DISTINCT FROM v_start AND audit.new_end IS NOT DISTINCT FROM v_end AND audit.reason = p_reason;
      ELSE
        SELECT audit.event_id INTO STRICT v_event FROM public.stage_date_changes AS audit
          WHERE audit.workspace_id = p_workspace AND audit.product_id = p_product AND audit.stage_id = v_id
            AND audit.operation_id = v_source_operation AND audit.version_after = v_expected + 1 AND audit.actor_id = p_actor
            AND audit.previous_start IS NOT DISTINCT FROM (v_change#>>'{before,start}')::date
            AND audit.previous_end IS NOT DISTINCT FROM (v_change#>>'{before,end}')::date
            AND audit.new_start IS NOT DISTINCT FROM v_start AND audit.new_end IS NOT DISTINCT FROM v_end AND audit.reason = p_reason;
      END IF;
      INSERT INTO public.product_schedule_operation_links (workspace_id, product_id, schedule_version, operation_id,
        source_ledger, source_operation_id, link_kind)
      VALUES (p_workspace, p_product, p_version + 1, p_operation, v_ledger, v_source_operation, 'audit_detail')
      ON CONFLICT DO NOTHING;
      INSERT INTO public.product_schedule_operation_source_events (workspace_id, product_id, schedule_version, operation_id,
        source_ledger, source_operation_id, source_event_id, link_kind)
      VALUES (p_workspace, p_product, p_version + 1, p_operation, v_ledger, v_source_operation, v_event, 'audit_detail')
      ON CONFLICT DO NOTHING;
      IF NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_source_events WHERE workspace_id = p_workspace
          AND product_id = p_product AND schedule_version = p_version + 1 AND operation_id = p_operation
          AND source_ledger = v_ledger AND source_operation_id = v_source_operation AND source_event_id = v_event
          AND link_kind = 'audit_detail') THEN RAISE EXCEPTION 'Missing dependency date audit link.'; END IF;
    END IF;
  END LOOP;

  SELECT schedule_version INTO STRICT v_new_version FROM public.product_schedule_operations
    WHERE workspace_id = p_workspace AND product_id = p_product AND operation_id = p_operation
      AND transaction_id = pg_current_xact_id() AND actor_id = p_actor;
  IF v_new_version <> p_version + 1 OR NOT EXISTS (SELECT 1 FROM public.product_schedule_state
      WHERE workspace_id = p_workspace AND product_id = p_product AND schedule_version = v_new_version) THEN
    RAISE EXCEPTION 'Dependency confirmation did not create exactly one Living Schedule operation.';
  END IF;
  RETURN jsonb_build_object('status', 'applied', 'operationId', p_operation, 'scheduleVersion', v_new_version::text);
END;
$$;

REVOKE ALL ON FUNCTION public.read_schedule_dependencies(uuid,uuid,uuid,boolean),
  public.read_schedule_dependency_receipt(uuid,uuid,uuid,uuid,bigint,text),
  public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb) FROM PUBLIC, jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
     OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR pg_has_role('neondb_owner', 'jlproject_calendar_executor', 'SET')
     OR has_schema_privilege('jlproject_date_executor', 'public', 'CREATE')
     OR has_any_column_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT, INSERT, UPDATE')
     OR has_table_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'DELETE, TRUNCATE')
     OR EXISTS (SELECT 1 FROM pg_proc AS routine JOIN pg_namespace AS schema ON schema.oid = routine.pronamespace
       WHERE schema.nspname = 'public' AND routine.proname IN ('read_schedule_dependencies',
         'read_schedule_dependency_receipt', 'confirm_schedule_dependencies')
       AND (has_function_privilege('jlproject_worker', routine.oid, 'EXECUTE') OR EXISTS (
         SELECT 1 FROM aclexplode(COALESCE(routine.proacl, acldefault('f', routine.proowner))) AS acl
         WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'))) THEN
    RAISE EXCEPTION 'Controlled dependency operations must remain inaccessible to application roles.';
  END IF;
END;
$$;

COMMIT;
