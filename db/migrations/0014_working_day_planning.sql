BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin = true
      AND rolsuper = false AND rolcreaterole = false AND rolcreatedb = false
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND rolcanlogin = false
  ) THEN
    RAISE EXCEPTION 'Apply this migration once with the reviewed JLProject development roles.';
  END IF;
END;
$$;

ALTER TABLE public.stage_activities
  ADD COLUMN planning_mode text NOT NULL DEFAULT 'manual',
  ADD COLUMN working_day_duration integer,
  ADD COLUMN planning_calendar_version bigint,
  ADD CONSTRAINT stage_activities_planning_check CHECK (
    (planning_mode = 'manual' AND working_day_duration IS NULL AND planning_calendar_version IS NULL) OR
    (planning_mode = 'working_days' AND planned_start IS NOT NULL AND planned_end IS NOT NULL AND
      working_day_duration IS NOT NULL AND working_day_duration BETWEEN 1 AND 27393 AND
      planning_calendar_version IS NOT NULL AND planning_calendar_version >= 0)
  );

-- Preserve manual creation while forcing working-plan inserts through the checked function.
REVOKE INSERT ON public.stage_activities FROM jlproject_worker;
GRANT INSERT (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
  planned_start, planned_end, display_order, notes, created_by, updated_by)
  ON public.stage_activities TO jlproject_worker;

GRANT SELECT ON public.workspaces, public.workspace_calendar_versions,
  public.workspace_calendar_exceptions TO jlproject_date_executor;
GRANT UPDATE (name) ON public.workspaces TO jlproject_date_executor;
GRANT UPDATE (active) ON public.products TO jlproject_date_executor;
GRANT UPDATE (planning_mode, working_day_duration, planning_calendar_version)
  ON public.stage_activities TO jlproject_date_executor;
GRANT INSERT ON public.stage_activities TO jlproject_date_executor;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

CREATE FUNCTION public.change_activity_planning(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_activity_id uuid, p_actor_id uuid, p_operation_id uuid, p_planning_mode text,
  p_start date, p_end date, p_working_day_duration integer,
  p_calendar_version bigint, p_reason text, p_expected_version bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_activity public.stage_activities%ROWTYPE;
  v_reason text;
  v_calendar_version bigint;
  v_dates_changed boolean;
  v_plan_changed boolean;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_discipline_id IS NULL OR
     p_stage_id IS NULL OR p_activity_id IS NULL OR p_actor_id IS NULL OR
     p_operation_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 OR
     p_start IS NULL OR p_end IS NULL OR p_start > p_end OR
     p_planning_mode NOT IN ('manual', 'working_days') OR p_planning_mode IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF p_planning_mode = 'manual' AND
     (p_working_day_duration IS NOT NULL OR p_calendar_version IS NOT NULL) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF p_planning_mode = 'working_days' AND
     (p_start < DATE '2026-01-01' OR p_end > DATE '2100-12-31' OR
      p_working_day_duration IS NULL OR p_working_day_duration NOT BETWEEN 1 AND 27393 OR
      p_calendar_version IS NULL OR p_calendar_version < 0) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF p_planning_mode = 'working_days' THEN
    SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
      WHERE workspace_id = p_workspace_id), 0) INTO v_calendar_version;
    IF v_calendar_version <> p_calendar_version THEN
      RETURN jsonb_build_object('status', 'stale_calendar');
    END IF;
  END IF;

  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;

  PERFORM 1 FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  SELECT activity.* INTO v_activity
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_product_id
      AND activity.discipline_id = p_discipline_id AND activity.stage_id = p_stage_id
      AND activity.id = p_activity_id
    FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_activity.version <> p_expected_version THEN RETURN jsonb_build_object('status', 'stale'); END IF;

  v_dates_changed := v_activity.planned_start IS DISTINCT FROM p_start OR
    v_activity.planned_end IS DISTINCT FROM p_end;
  v_plan_changed := v_activity.planning_mode IS DISTINCT FROM p_planning_mode OR
    v_activity.working_day_duration IS DISTINCT FROM p_working_day_duration OR
    v_activity.planning_calendar_version IS DISTINCT FROM p_calendar_version;
  IF NOT v_dates_changed AND NOT v_plan_changed THEN
    RETURN jsonb_build_object('status', 'unchanged');
  END IF;

  IF p_reason IS NOT NULL THEN
    v_reason := btrim(p_reason);
    IF char_length(v_reason) NOT BETWEEN 10 AND 2000 OR v_reason ~ '[[:cntrl:]]' THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  END IF;
  IF (v_dates_changed OR v_plan_changed) AND v_reason IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF v_dates_changed THEN
    PERFORM set_config('jlproject.date_operation_id', p_operation_id::text, true);
    PERFORM set_config('jlproject.date_change_reason', v_reason, true);
    PERFORM set_config('jlproject.date_actor_id', p_actor_id::text, true);
  END IF;

  UPDATE public.stage_activities
    SET planned_start = p_start, planned_end = p_end,
      planning_mode = p_planning_mode, working_day_duration = p_working_day_duration,
      planning_calendar_version = p_calendar_version,
      version = version + 1, updated_by = p_actor_id, updated_at = clock_timestamp()
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND discipline_id = p_discipline_id AND stage_id = p_stage_id AND id = p_activity_id;
  RETURN jsonb_build_object('status', 'updated');
END;
$$;

CREATE OR REPLACE FUNCTION public.change_activity_dates(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_activity_id uuid, p_actor_id uuid, p_operation_id uuid,
  p_start date, p_end date, p_reason text, p_expected_version bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN public.change_activity_planning(p_workspace_id, p_product_id, p_discipline_id,
    p_stage_id, p_activity_id, p_actor_id, p_operation_id, 'manual', p_start, p_end,
    NULL, NULL, p_reason, p_expected_version);
END;
$$;

CREATE FUNCTION public.create_activity_with_working_plan(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_actor_id uuid, p_name text, p_activity_type text, p_start date, p_end date,
  p_display_order integer, p_notes text, p_working_day_duration integer,
  p_calendar_version bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_calendar_version bigint;
  v_activity_id uuid;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_discipline_id IS NULL OR
     p_stage_id IS NULL OR p_actor_id IS NULL OR p_name IS NULL OR
     char_length(btrim(p_name)) NOT BETWEEN 1 AND 300 OR p_name <> btrim(p_name) OR
     p_start IS NULL OR p_end IS NULL OR p_start > p_end OR
     p_start < DATE '2026-01-01' OR p_end > DATE '2100-12-31' OR
     p_display_order IS NULL OR p_display_order NOT BETWEEN 0 AND 1000000 OR
     p_working_day_duration IS NULL OR p_working_day_duration NOT BETWEEN 1 AND 27393 OR
     p_calendar_version IS NULL OR p_calendar_version < 0 THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = p_workspace_id), 0) INTO v_calendar_version;
  IF v_calendar_version <> p_calendar_version THEN
    RETURN jsonb_build_object('status', 'stale_calendar');
  END IF;

  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;

  PERFORM 1 FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND discipline_id = p_discipline_id AND id = p_stage_id) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
     planned_start, planned_end, display_order, notes, created_by, updated_by,
     planning_mode, working_day_duration, planning_calendar_version)
  VALUES (p_workspace_id, p_product_id, p_discipline_id, p_stage_id, btrim(p_name),
    p_activity_type, p_start, p_end, p_display_order, p_notes, p_actor_id, p_actor_id,
    'working_days', p_working_day_duration, p_calendar_version)
  RETURNING id INTO v_activity_id;
  RETURN jsonb_build_object('status', 'created', 'id', v_activity_id);
END;
$$;

REVOKE ALL ON FUNCTION public.change_activity_planning(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  text, date, date, integer, bigint, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_activity_with_working_plan(uuid, uuid, uuid, uuid, uuid,
  text, text, date, date, integer, text, integer, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_activity_planning(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  text, date, date, integer, bigint, text, bigint) TO jlproject_worker;
GRANT EXECUTE ON FUNCTION public.create_activity_with_working_plan(uuid, uuid, uuid, uuid, uuid,
  text, text, date, date, integer, text, integer, bigint) TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)',
       'execute') OR
     NOT has_function_privilege('jlproject_worker',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)',
       'execute') OR
     has_function_privilege('public',
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)',
       'execute') OR
     has_function_privilege('public',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)',
       'execute') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'update') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'update') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'update') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'update') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'update') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'insert') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'insert') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'insert') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'insert') THEN
    RAISE EXCEPTION 'Activity planning privileges are not correctly restricted.';
  END IF;
END;
$$;

COMMIT;
