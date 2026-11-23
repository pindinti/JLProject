BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;
GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- The built-in dates mirror the Phase 4A calendar. The source test checks all supported years.
CREATE FUNCTION public.dependency_first_working_start(p_workspace uuid, p_finish date)
RETURNS date LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_fixed text[] := string_to_array($fixed$01-01 04-21 05-01 09-07 10-12 11-02 11-15 11-20 12-25$fixed$, ' ');
  v_dated date[] := regexp_split_to_array($dated$2026-02-16 2026-02-17 2026-02-18 2026-04-03 2026-04-20 2026-06-04 2026-06-05 2026-10-30
2026-12-24 2026-12-31 2027-03-26 2028-04-14 2029-03-30 2030-04-19 2031-04-11 2032-03-26
2033-04-15 2034-04-07 2035-03-23 2036-04-11 2037-04-03 2038-04-23 2039-04-08 2040-03-30
2041-04-19 2042-04-04 2043-03-27 2044-04-15 2045-04-07 2046-03-23 2047-04-12 2048-04-03
2049-04-16 2050-04-08 2051-03-31 2052-04-19 2053-04-04 2054-03-27 2055-04-16 2056-03-31
2057-04-20 2058-04-12 2059-03-28 2060-04-16 2061-04-08 2062-03-24 2063-04-13 2064-04-04
2065-03-27 2066-04-09 2067-04-01 2068-04-20 2069-04-12 2070-03-28 2071-04-17 2072-04-08
2073-03-24 2074-04-13 2075-04-05 2076-04-17 2077-04-09 2078-04-01 2079-04-21 2080-04-05
2081-03-28 2082-04-17 2083-04-02 2084-03-24 2085-04-13 2086-03-29 2087-04-18 2088-04-09
2089-04-01 2090-04-14 2091-04-06 2092-03-28 2093-04-10 2094-04-02 2095-04-22 2096-04-13
2097-03-29 2098-04-18 2099-04-10 2100-03-26$dated$, '[[:space:]]+')::date[];
  v_day date;
BEGIN
  IF p_finish IS NULL OR p_finish NOT BETWEEN DATE '2026-01-01' AND DATE '2100-12-31' THEN RETURN NULL; END IF;
  FOR v_step IN 1..(DATE '2100-12-31' - p_finish) LOOP
    v_day := p_finish + v_step;
    IF extract(isodow FROM v_day) BETWEEN 1 AND 5 AND to_char(v_day, 'MM-DD') <> ALL(v_fixed) AND v_day <> ALL(v_dated)
       AND NOT EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
         WHERE exception.workspace_id = p_workspace AND exception.removed_at IS NULL
           AND v_day BETWEEN exception.start_date AND exception.end_date) THEN RETURN v_day; END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

-- A single proposed edit overlays the stored interval. D065 applies before and after the edit.
CREATE FUNCTION public.dependency_effective_date_interval(p_workspace uuid, p_product uuid, p_kind text, p_id uuid,
  p_edit_kind text, p_edit_id uuid, p_start date, p_end date)
RETURNS TABLE(start_date date, end_date date) LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN p_edit_kind = 'activity' AND activity.id = p_edit_id THEN p_start ELSE activity.planned_start END,
    CASE WHEN p_edit_kind = 'activity' AND activity.id = p_edit_id THEN p_end ELSE activity.planned_end END
  FROM public.stage_activities AS activity
  WHERE p_kind = 'activity' AND activity.workspace_id = p_workspace AND activity.product_id = p_product
    AND activity.id = p_id AND activity.deleted_at IS NULL AND (activity.stage_id IS NULL OR EXISTS (
      SELECT 1 FROM public.discipline_stages AS stage JOIN public.product_disciplines AS discipline
        ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
        AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
      WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.id = activity.stage_id
        AND stage.discipline_id = activity.discipline_id AND stage.deleted_at IS NULL))
  UNION ALL
  SELECT CASE WHEN planned.start_date IS NULL AND planned.end_date IS NULL THEN derived.start_date ELSE planned.start_date END,
    CASE WHEN planned.start_date IS NULL AND planned.end_date IS NULL THEN derived.end_date ELSE planned.end_date END
  FROM public.discipline_stages AS stage JOIN public.product_disciplines AS discipline
    ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
    AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
  CROSS JOIN LATERAL (SELECT
    CASE WHEN p_edit_kind = 'stage' AND stage.id = p_edit_id THEN p_start ELSE stage.planned_start END AS start_date,
    CASE WHEN p_edit_kind = 'stage' AND stage.id = p_edit_id THEN p_end ELSE stage.planned_end END AS end_date) AS planned
  LEFT JOIN LATERAL (
    SELECT min(CASE WHEN p_edit_kind = 'activity' AND child.id = p_edit_id THEN p_start ELSE child.planned_start END) AS start_date,
      max(CASE WHEN p_edit_kind = 'activity' AND child.id = p_edit_id THEN p_end ELSE child.planned_end END) AS end_date
    FROM public.stage_activities AS child WHERE child.workspace_id = p_workspace AND child.product_id = p_product
      AND child.discipline_id = stage.discipline_id AND child.stage_id = stage.id AND child.deleted_at IS NULL
      AND planned.start_date IS NULL AND planned.end_date IS NULL) AS derived ON true
  WHERE p_kind = 'stage' AND stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.id = p_id
    AND stage.deleted_at IS NULL;
$$;

-- The writers call this only after the workspace, actor membership and product are locked.
CREATE FUNCTION public.guard_individual_dependency_date_change(p_workspace uuid, p_product uuid, p_kind text,
  p_id uuid, p_parent_stage uuid, p_start date, p_end date)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_edge record;
  v_before record;
  v_after record;
  v_other record;
  v_old_finish date;
  v_new_finish date;
  v_old_start date;
  v_new_start date;
  v_old_required date;
  v_new_required date;
  v_reason text;
BEGIN
  FOR v_edge IN
    WITH touched(kind, id) AS (VALUES (p_kind, p_id), ('stage', p_parent_stage)), incident AS (
      SELECT edge.id, edge.endpoint_kind AS kind, touched.id AS edited_id,
        COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id) AS predecessor,
        COALESCE(edge.successor_activity_id, edge.successor_stage_id) AS successor
      FROM public.product_schedule_dependencies AS edge JOIN touched ON touched.kind = edge.endpoint_kind
        AND touched.id IN (edge.predecessor_activity_id, edge.successor_activity_id, edge.predecessor_stage_id, edge.successor_stage_id)
      WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product)
    SELECT *, CASE WHEN edited_id = successor THEN 'inbound' ELSE 'outbound' END AS direction
      FROM incident ORDER BY direction, id
  LOOP
    SELECT * INTO v_before FROM public.dependency_effective_date_interval(p_workspace, p_product,
      v_edge.kind, v_edge.edited_id, NULL, NULL, NULL, NULL);
    SELECT * INTO v_after FROM public.dependency_effective_date_interval(p_workspace, p_product,
      v_edge.kind, v_edge.edited_id, p_kind, p_id, p_start, p_end);
    IF v_edge.direction = 'inbound' THEN
      IF v_before.start_date IS NOT DISTINCT FROM v_after.start_date THEN CONTINUE; END IF;
      SELECT * INTO v_other FROM public.dependency_effective_date_interval(p_workspace, p_product,
        v_edge.kind, v_edge.predecessor, NULL, NULL, NULL, NULL);
      v_old_finish := v_other.end_date;
      v_new_finish := v_other.end_date;
      v_old_start := v_before.start_date;
      v_new_start := v_after.start_date;
    ELSE
      IF v_before.end_date IS NOT DISTINCT FROM v_after.end_date THEN CONTINUE; END IF;
      SELECT * INTO v_other FROM public.dependency_effective_date_interval(p_workspace, p_product,
        v_edge.kind, v_edge.successor, NULL, NULL, NULL, NULL);
      v_old_finish := v_before.end_date;
      v_new_finish := v_after.end_date;
      v_old_start := v_other.start_date;
      v_new_start := v_other.start_date;
    END IF;

    v_old_required := public.dependency_first_working_start(p_workspace, v_old_finish);
    v_new_required := CASE WHEN v_new_finish = v_old_finish THEN v_old_required
      ELSE public.dependency_first_working_start(p_workspace, v_new_finish) END;
    v_reason := CASE
      WHEN v_old_finish IS NOT NULL AND v_new_finish IS NULL OR v_old_start IS NOT NULL AND v_new_start IS NULL
        THEN 'missing_boundary'
      WHEN v_new_finish IS NULL OR v_new_start IS NULL THEN NULL
      WHEN v_new_required IS NULL THEN 'calendar_range'
      WHEN v_new_start < v_new_required AND (v_old_start IS NULL OR v_old_required IS NULL
        OR v_new_start < v_old_start OR v_new_required > v_old_required) THEN 'finish_to_start' END;
    IF v_reason IS NOT NULL THEN
      RETURN jsonb_build_object('status', CASE WHEN v_edge.direction = 'outbound' AND v_reason = 'finish_to_start'
          THEN 'dependency_preview_required' ELSE 'dependency_conflict' END,
        'dependencyId', v_edge.id, 'direction', v_edge.direction, 'reason', v_reason,
        'before', jsonb_build_object('predecessorFinish', v_old_finish, 'successorStart', v_old_start, 'earliestStart', v_old_required),
        'after', jsonb_build_object('predecessorFinish', v_new_finish, 'successorStart', v_new_start, 'earliestStart', v_new_required));
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

DO $install$
DECLARE
  v_activity text := pg_get_functiondef('public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)'::regprocedure);
  v_stage text := pg_get_functiondef('public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)'::regprocedure);
  v_confirmation text := pg_get_functiondef('public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)'::regprocedure);
  v_batch text := pg_get_functiondef('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure);
  v_activity_audit constant text := '  IF v_dates_changed THEN';
  v_stage_audit constant text := '  PERFORM set_config(''jlproject.stage_date_operation_id'', p_operation_id::text, true);';
  v_stage_member constant text := '  PERFORM 1 FROM public.workspace_memberships';
  v_stage_row constant text := '  SELECT stage.id, stage.version, stage.planned_start, stage.planned_end';
  v_activity_call constant text := 'v_changed := public.change_activity_planning(';
  v_stage_call constant text := 'v_changed := public.change_discipline_stage_dates(';
  v_batch_call constant text := 'v_result := public.change_activity_planning(';
BEGIN
  IF length(v_activity) - length(replace(v_activity, v_activity_audit, '')) <> length(v_activity_audit)
     OR length(v_stage) - length(replace(v_stage, v_stage_audit, '')) <> length(v_stage_audit)
     OR length(v_stage) - length(replace(v_stage, v_stage_member, '')) <> length(v_stage_member)
     OR length(v_stage) - length(replace(v_stage, v_stage_row, '')) <> length(v_stage_row)
     OR length(v_confirmation) - length(replace(v_confirmation, v_activity_call, '')) <> length(v_activity_call)
     OR length(v_confirmation) - length(replace(v_confirmation, v_stage_call, '')) <> length(v_stage_call)
     OR length(v_batch) - length(replace(v_batch, v_batch_call, '')) <> length(v_batch_call)
     OR v_activity NOT LIKE 'CREATE OR REPLACE FUNCTION public.change_activity_planning(%'
     OR v_stage NOT LIKE 'CREATE OR REPLACE FUNCTION public.change_discipline_stage_dates(%'
     OR position('AND id = p_product_id AND active = true FOR UPDATE' IN v_activity) = 0 THEN
    RAISE EXCEPTION 'Installed date routines differ from the reviewed guard anchors.';
  END IF;

  -- Only the reviewed confirmation and existing batch functions can reach the original audited primitives.
  EXECUTE replace(v_activity, 'CREATE OR REPLACE FUNCTION public.change_activity_planning(',
    'CREATE FUNCTION public.write_reviewed_activity_planning(');
  EXECUTE replace(v_stage, 'CREATE OR REPLACE FUNCTION public.change_discipline_stage_dates(',
    'CREATE FUNCTION public.write_reviewed_stage_dates(');
  EXECUTE replace(replace(v_confirmation, v_activity_call, 'v_changed := public.write_reviewed_activity_planning('),
    v_stage_call, 'v_changed := public.write_reviewed_stage_dates(');
  -- The batch still awaits final-state protection. Preserve its current behavior in this checkpoint.
  EXECUTE replace(v_batch, v_batch_call, 'v_result := public.write_reviewed_activity_planning(');

  v_activity := replace(v_activity, '  v_dates_changed boolean;',
    E'  v_dates_changed boolean;\n  v_dependency_rejection jsonb;');
  EXECUTE replace(v_activity, v_activity_audit, v_activity_audit || $guard$
    v_dependency_rejection := public.guard_individual_dependency_date_change(p_workspace_id, p_product_id,
      'activity', p_activity_id, p_stage_id, p_start, p_end);
    IF v_dependency_rejection IS NOT NULL THEN RETURN v_dependency_rejection; END IF;$guard$);

  v_stage := replace(v_stage, '  v_reason text;', E'  v_reason text;\n  v_dependency_rejection jsonb;');
  v_stage := replace(v_stage, v_stage_member, $lock$  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
$lock$ || v_stage_member);
  v_stage := replace(v_stage, v_stage_row, $lock$  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace_id
    AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
$lock$ || v_stage_row);
  EXECUTE replace(v_stage, v_stage_audit, $guard$  v_dependency_rejection := public.guard_individual_dependency_date_change(
    p_workspace_id, p_product_id, 'stage', p_stage_id, NULL, p_start, p_end);
  IF v_dependency_rejection IS NOT NULL THEN RETURN v_dependency_rejection; END IF;
$guard$ || v_stage_audit);
END;
$install$;

REVOKE ALL ON FUNCTION public.dependency_first_working_start(uuid,date),
  public.dependency_effective_date_interval(uuid,uuid,text,uuid,text,uuid,date,date),
  public.guard_individual_dependency_date_change(uuid,uuid,text,uuid,uuid,date,date),
  public.write_reviewed_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint),
  public.write_reviewed_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)
  FROM PUBLIC, jlproject_worker, neondb_owner;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $check$
BEGIN
  IF pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
     OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR has_schema_privilege('jlproject_date_executor', 'public', 'CREATE')
     OR has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.discipline_stages', 'planned_start', 'UPDATE')
     OR has_column_privilege('jlproject_worker', 'public.discipline_stages', 'planned_end', 'UPDATE')
     OR EXISTS (SELECT 1 FROM pg_proc AS routine JOIN pg_namespace AS schema ON schema.oid = routine.pronamespace
       WHERE schema.nspname = 'public' AND routine.proname IN ('write_reviewed_activity_planning', 'write_reviewed_stage_dates',
         'guard_individual_dependency_date_change', 'dependency_effective_date_interval', 'dependency_first_working_start',
         'confirm_schedule_dependencies', 'read_schedule_dependencies', 'read_schedule_dependency_receipt')
       AND (has_function_privilege('jlproject_worker', routine.oid, 'EXECUTE') OR EXISTS (
         SELECT 1 FROM aclexplode(COALESCE(routine.proacl, acldefault('f', routine.proowner))) AS acl
         WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'))) THEN
    RAISE EXCEPTION 'Dependency guard permissions or activation boundary are incorrect.';
  END IF;
END;
$check$;

COMMIT;
