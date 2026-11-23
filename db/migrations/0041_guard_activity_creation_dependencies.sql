BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

DO $preflight$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.product_schedule_dependencies') IS NULL OR
     to_regprocedure('public.dependency_first_working_start(uuid,date)') IS NULL OR
     to_regprocedure('public.dependency_effective_date_interval(uuid,uuid,text,uuid,text,uuid,date,date)') IS NULL OR
     to_regprocedure('public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)') IS NULL OR
     position('proposedStartDate' IN pg_get_functiondef(
       'public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)'::regprocedure)) = 0 OR
     position('public.guard_calendar_reschedule_dependencies(' IN pg_get_functiondef(
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure)) = 0 OR
     position('public.guard_calendar_reschedule_dependencies(' IN pg_get_functiondef(
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)'::regprocedure)) = 0 OR
     to_regprocedure('public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)') IS NULL OR
     to_regprocedure('public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)') IS NOT NULL OR
     to_regprocedure('public.guard_activity_creation_before_insert()') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_activity_creation_dependency_guard' AND NOT tgisinternal) OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Activity creation guard prerequisites differ from the reviewed dormant dependency state.';
  END IF;
END;
$preflight$;

GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- A new child can only affect a fully derived D065 interval. Any explicit
-- boundary, including a partial interval, remains authoritative and unchanged.
CREATE FUNCTION public.guard_activity_creation_dependencies(
  p_workspace uuid, p_product uuid, p_stage uuid, p_start date, p_end date
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_edge record;
  v_before record;
  v_after_start date;
  v_after_end date;
  v_other record;
  v_old_finish date;
  v_new_finish date;
  v_old_start date;
  v_new_start date;
  v_old_bound date;
  v_new_bound date;
  v_reason text;
BEGIN
  IF p_stage IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies
      WHERE workspace_id = p_workspace AND product_id = p_product AND endpoint_kind = 'stage'
        AND (predecessor_stage_id = p_stage OR successor_stage_id = p_stage)) THEN
    RETURN NULL;
  END IF;

  SELECT effective.start_date, effective.end_date INTO v_before
  FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage', p_stage,
    NULL, NULL, NULL, NULL) AS effective;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF EXISTS (SELECT 1 FROM public.discipline_stages AS stage
      WHERE stage.workspace_id = p_workspace AND stage.product_id = p_product AND stage.id = p_stage
        AND (stage.planned_start IS NOT NULL OR stage.planned_end IS NOT NULL)) THEN
    RETURN NULL;
  END IF;

  SELECT min(projected.start_date), max(projected.end_date) INTO v_after_start, v_after_end
  FROM (
    SELECT activity.planned_start AS start_date, activity.planned_end AS end_date
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = p_workspace AND activity.product_id = p_product
      AND activity.stage_id = p_stage AND activity.deleted_at IS NULL
    UNION ALL
    SELECT p_start, p_end
  ) AS projected;

  FOR v_edge IN
    SELECT edge.id, edge.predecessor_stage_id, edge.successor_stage_id
    FROM public.product_schedule_dependencies AS edge
    WHERE edge.workspace_id = p_workspace AND edge.product_id = p_product AND edge.endpoint_kind = 'stage'
      AND (edge.predecessor_stage_id = p_stage OR edge.successor_stage_id = p_stage)
    ORDER BY edge.id
  LOOP
    IF v_edge.predecessor_stage_id = p_stage THEN
      v_old_finish := v_before.end_date;
      v_new_finish := v_after_end;
      SELECT effective.start_date INTO v_other
      FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
        v_edge.successor_stage_id, NULL, NULL, NULL, NULL) AS effective;
      v_old_start := v_other.start_date;
      v_new_start := v_old_start;
    ELSE
      v_old_start := v_before.start_date;
      v_new_start := v_after_start;
      SELECT effective.end_date INTO v_other
      FROM public.dependency_effective_date_interval(p_workspace, p_product, 'stage',
        v_edge.predecessor_stage_id, NULL, NULL, NULL, NULL) AS effective;
      v_old_finish := v_other.end_date;
      v_new_finish := v_old_finish;
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

-- The trigger name sorts before the existing deletion guard so direct inserts
-- acquire workspace then product locks before active-parent validation.
CREATE FUNCTION public.guard_activity_creation_before_insert()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_conflict jsonb;
  v_product_active boolean;
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = NEW.workspace_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Workspace was not found.' USING ERRCODE = '23503'; END IF;
  SELECT product.active INTO v_product_active FROM public.products AS product
  WHERE product.workspace_id = NEW.workspace_id AND product.id = NEW.product_id FOR UPDATE;
  IF NOT FOUND OR v_product_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Product is not active.' USING ERRCODE = '23514';
  END IF;
  v_conflict := public.guard_activity_creation_dependencies(NEW.workspace_id, NEW.product_id,
    NEW.stage_id, NEW.planned_start, NEW.planned_end);
  IF v_conflict IS NOT NULL THEN
    RAISE EXCEPTION 'Activity creation would worsen a schedule dependency.'
      USING ERRCODE = 'P4D01', DETAIL = v_conflict::text;
  END IF;
  RETURN NEW;
END;
$$;

DO $install$
DECLARE
  v_source text := pg_get_functiondef('public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)'::regprocedure);
  v_declaration constant text := '  v_activity_id uuid;';
  v_insert constant text := '  INSERT INTO public.stage_activities';
BEGIN
  IF length(v_source) - length(replace(v_source, v_declaration, '')) <> length(v_declaration) OR
     length(v_source) - length(replace(v_source, v_insert, '')) <> length(v_insert) OR
     v_source NOT LIKE 'CREATE OR REPLACE FUNCTION public.create_activity_with_working_plan(%' OR
     position('AND id = p_product_id AND active = true FOR UPDATE' IN v_source) = 0 OR
     position('PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE' IN v_source) = 0 THEN
    RAISE EXCEPTION 'Installed activity creation function differs from the reviewed lock and insert anchors.';
  END IF;
  v_source := replace(v_source, v_declaration, v_declaration || E'\n  v_conflict jsonb;');
  EXECUTE replace(v_source, v_insert, $guard$
  v_conflict := public.guard_activity_creation_dependencies(p_workspace_id, p_product_id, p_stage_id, p_start, p_end);
  IF v_conflict IS NOT NULL THEN RETURN v_conflict; END IF;
  INSERT INTO public.stage_activities$guard$);
END;
$install$;

REVOKE ALL ON FUNCTION public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date),
  public.guard_activity_creation_before_insert() FROM PUBLIC, jlproject_worker;
GRANT EXECUTE ON FUNCTION public.guard_activity_creation_before_insert() TO neondb_owner;

RESET ROLE;

CREATE TRIGGER stage_activities_activity_creation_dependency_guard
  BEFORE INSERT ON public.stage_activities
  FOR EACH ROW EXECUTE FUNCTION public.guard_activity_creation_before_insert();

SET ROLE jlproject_date_executor;
REVOKE ALL ON FUNCTION public.guard_activity_creation_before_insert() FROM neondb_owner;
REVOKE ALL ON FUNCTION public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date) FROM neondb_owner;
RESET ROLE;

REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $postflight$
BEGIN
  IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.guard_activity_creation_before_insert()'::regprocedure) <> 'jlproject_date_executor' OR
     NOT (SELECT prosecdef FROM pg_proc WHERE oid =
       'public.guard_activity_creation_before_insert()'::regprocedure) OR
     NOT has_function_privilege('jlproject_worker',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)', 'EXECUTE') OR
     has_function_privilege('jlproject_worker', 'public.guard_activity_creation_before_insert()', 'EXECUTE') OR
     has_function_privilege('neondb_owner',
       'public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)', 'EXECUTE') OR
     has_function_privilege('neondb_owner', 'public.guard_activity_creation_before_insert()', 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_activity_creation_dependency_guard' AND tgenabled IN ('O', 'A')) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Activity creation dependency guard privileges or trigger state are incorrect.';
  END IF;
END;
$postflight$;

COMMIT;
