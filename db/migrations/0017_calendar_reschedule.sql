BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     to_regclass('public.calendar_reschedule_changes') IS NOT NULL OR
     to_regprocedure('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)') IS NOT NULL OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspaces', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_calendar_versions', 'SELECT') OR
     NOT has_function_privilege('jlproject_date_executor',
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Calendar reschedule migration prerequisites are not satisfied.';
  END IF;
END;
$$;

-- The executor owns both audit tables; the Worker receives only function EXECUTE.
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

CREATE TABLE public.calendar_reschedule_changes (
  date_operation_id uuid PRIMARY KEY REFERENCES public.activity_date_changes(operation_id) ON DELETE RESTRICT,
  batch_operation_id uuid NOT NULL,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  activity_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  previous_start date NOT NULL,
  previous_end date NOT NULL,
  new_start date NOT NULL,
  new_end date NOT NULL,
  working_day_duration integer NOT NULL CHECK (working_day_duration BETWEEN 1 AND 27393),
  previous_calendar_version bigint NOT NULL CHECK (previous_calendar_version >= 0),
  new_calendar_version bigint NOT NULL CHECK (new_calendar_version > previous_calendar_version),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 10 AND 2000 AND reason = btrim(reason)
    AND reason !~ '[[:cntrl:]]'),
  CONSTRAINT calendar_reschedule_one_activity_per_batch UNIQUE (batch_operation_id, activity_id),
  CONSTRAINT calendar_reschedule_actual_date_change CHECK
    (previous_start <> new_start OR previous_end <> new_end)
);
CREATE INDEX calendar_reschedule_changes_scope_idx ON public.calendar_reschedule_changes
  (workspace_id, product_id, activity_id, changed_at DESC);
REVOKE ALL ON public.calendar_reschedule_changes FROM PUBLIC;
GRANT SELECT ON public.calendar_reschedule_changes TO neondb_owner;

CREATE TRIGGER calendar_reschedule_changes_append_only
  BEFORE UPDATE OR DELETE ON public.calendar_reschedule_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_activity_date_change_mutation();

CREATE FUNCTION public.apply_calendar_reschedule(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid, p_batch_id uuid,
  p_calendar_version bigint, p_reason text, p_proposals jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_item jsonb;
  v_activity public.stage_activities%ROWTYPE;
  v_calendar_version bigint;
  v_date_operation_id uuid;
  v_result jsonb;
  v_count integer := 0;
  v_seen uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_batch_id IS NULL OR p_calendar_version IS NULL OR p_calendar_version < 1 OR
     p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 10 AND 2000 OR
     p_reason <> btrim(p_reason) OR p_reason ~ '[[:cntrl:]]' OR
     p_proposals IS NULL OR jsonb_typeof(p_proposals) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF jsonb_array_length(p_proposals) NOT BETWEEN 1 AND 50 THEN
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

  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace_id
    AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  -- Lock every selected row in a stable order before the first update.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_proposals) AS entry(value)
    ORDER BY value->>'activityId' LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_item)) <> 9 OR
       NOT (v_item ?& ARRAY['activityId', 'disciplineId', 'stageId', 'expectedVersion',
         'startDate', 'currentEndDate', 'proposedEndDate', 'workingDays', 'savedCalendarVersion']) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    IF (v_item->>'activityId')::uuid = ANY(v_seen) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    v_seen := array_append(v_seen, (v_item->>'activityId')::uuid);
    SELECT * INTO v_activity FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND id = (v_item->>'activityId')::uuid
        AND discipline_id = (v_item->>'disciplineId')::uuid
        AND stage_id = (v_item->>'stageId')::uuid FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF v_activity.version <> (v_item->>'expectedVersion')::bigint OR
       v_activity.planning_mode <> 'working_days' OR
       v_activity.planned_start IS DISTINCT FROM (v_item->>'startDate')::date OR
       v_activity.planned_end IS DISTINCT FROM (v_item->>'currentEndDate')::date OR
       v_activity.working_day_duration IS DISTINCT FROM (v_item->>'workingDays')::integer OR
       v_activity.planning_calendar_version IS DISTINCT FROM (v_item->>'savedCalendarVersion')::bigint OR
       v_activity.planning_calendar_version >= p_calendar_version THEN
      RETURN jsonb_build_object('status', 'stale');
    END IF;
    IF (v_item->>'proposedEndDate')::date <= DATE '2025-12-31' OR
       (v_item->>'proposedEndDate')::date > DATE '2100-12-31' OR
       (v_item->>'proposedEndDate')::date < v_activity.planned_start OR
       (v_item->>'proposedEndDate')::date = v_activity.planned_end THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  END LOOP;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_proposals) AS entry(value)
    ORDER BY value->>'activityId' LOOP
    SELECT * INTO STRICT v_activity FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND id = (v_item->>'activityId')::uuid;
    v_date_operation_id := gen_random_uuid();
    v_result := public.change_activity_planning(p_workspace_id, p_product_id,
      v_activity.discipline_id, v_activity.stage_id, v_activity.id, p_actor_id,
      v_date_operation_id, 'working_days', v_activity.planned_start,
      (v_item->>'proposedEndDate')::date, v_activity.working_day_duration,
      p_calendar_version, p_reason, v_activity.version);
    IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
      RAISE EXCEPTION 'Calendar reschedule changed during execution.' USING ERRCODE = '40001';
    END IF;
    INSERT INTO public.calendar_reschedule_changes
      (date_operation_id, batch_operation_id, workspace_id, product_id, activity_id,
       actor_id, previous_start, previous_end, new_start, new_end,
       working_day_duration, previous_calendar_version, new_calendar_version,
       version_before, version_after, reason)
    VALUES (v_date_operation_id, p_batch_id, p_workspace_id, p_product_id,
      v_activity.id, p_actor_id, v_activity.planned_start, v_activity.planned_end,
      v_activity.planned_start, (v_item->>'proposedEndDate')::date,
      v_activity.working_day_duration, v_activity.planning_calendar_version,
      p_calendar_version, v_activity.version, v_activity.version + 1, p_reason);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('status', 'updated', 'count', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)
  TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Calendar reschedule privileges are not restricted.';
  END IF;
END;
$$;

COMMIT;
