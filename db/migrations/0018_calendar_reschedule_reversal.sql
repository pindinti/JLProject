BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     to_regclass('public.calendar_reschedule_changes') IS NULL OR
     to_regprocedure('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)') IS NULL OR
     to_regclass('public.calendar_reschedule_reversals') IS NOT NULL OR
     to_regprocedure('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)') IS NOT NULL OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspaces', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planning_mode', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'working_day_duration', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planning_calendar_version', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'version', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'updated_by', 'UPDATE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'updated_at', 'UPDATE') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_dates_immutable' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.activity_date_changes'::regclass
       AND tgname = 'activity_date_changes_append_only' AND tgenabled IN ('O', 'A')) OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid =
       'public.calendar_reschedule_changes'::regclass) <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'Calendar reversal migration prerequisites are not satisfied.';
  END IF;
END;
$$;

GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

CREATE TABLE public.calendar_reschedule_reversals (
  reversal_date_operation_id uuid PRIMARY KEY
    REFERENCES public.activity_date_changes(operation_id) ON DELETE RESTRICT,
  original_date_operation_id uuid NOT NULL UNIQUE
    REFERENCES public.calendar_reschedule_changes(date_operation_id) ON DELETE RESTRICT,
  original_batch_operation_id uuid NOT NULL,
  reversal_batch_operation_id uuid NOT NULL,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  activity_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  reversed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  before_start date NOT NULL,
  before_end date NOT NULL,
  restored_start date NOT NULL,
  restored_end date NOT NULL,
  before_planning_mode text NOT NULL CHECK (before_planning_mode = 'working_days'),
  restored_planning_mode text NOT NULL CHECK (restored_planning_mode = 'working_days'),
  before_working_day_duration integer NOT NULL CHECK (before_working_day_duration BETWEEN 1 AND 27393),
  restored_working_day_duration integer NOT NULL CHECK (restored_working_day_duration BETWEEN 1 AND 27393),
  before_calendar_version bigint NOT NULL CHECK (before_calendar_version >= 0),
  restored_calendar_version bigint NOT NULL CHECK (restored_calendar_version >= 0),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 10 AND 2000 AND reason = btrim(reason)
    AND reason !~ '[[:cntrl:]]'),
  CONSTRAINT calendar_reversal_one_activity_per_batch UNIQUE (reversal_batch_operation_id, activity_id),
  CONSTRAINT calendar_reversal_actual_date_change CHECK
    (before_start <> restored_start OR before_end <> restored_end)
);
CREATE INDEX calendar_reschedule_reversals_original_batch_idx
  ON public.calendar_reschedule_reversals (workspace_id, product_id, original_batch_operation_id);
REVOKE ALL ON public.calendar_reschedule_reversals FROM PUBLIC;
GRANT SELECT ON public.calendar_reschedule_reversals TO neondb_owner;

CREATE TRIGGER calendar_reschedule_reversals_append_only
  BEFORE UPDATE OR DELETE ON public.calendar_reschedule_reversals
  FOR EACH ROW EXECUTE FUNCTION public.prevent_activity_date_change_mutation();

CREATE FUNCTION public.reverse_calendar_reschedule(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid,
  p_original_batch_id uuid, p_reversal_batch_id uuid, p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_change record;
  v_activity public.stage_activities%ROWTYPE;
  v_date_operation_id uuid;
  v_count integer := 0;
  v_affected integer;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_original_batch_id IS NULL OR p_reversal_batch_id IS NULL OR
     p_original_batch_id = p_reversal_batch_id OR p_reason IS NULL OR
     char_length(p_reason) NOT BETWEEN 10 AND 2000 OR p_reason <> btrim(p_reason) OR
     p_reason ~ '[[:cntrl:]]' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;
  PERFORM 1 FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND batch_operation_id = p_original_batch_id) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF EXISTS (SELECT 1 FROM public.calendar_reschedule_changes
    WHERE batch_operation_id = p_original_batch_id
      AND (workspace_id <> p_workspace_id OR product_id <> p_product_id)) THEN
    RAISE EXCEPTION 'Original calendar reschedule spans multiple products.' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND original_batch_operation_id = p_original_batch_id) THEN
    RETURN jsonb_build_object('status', 'already_reversed');
  END IF;

  -- Validate the entire original batch and lock every activity before changing any row.
  FOR v_change IN
    SELECT c.*, d.discipline_id, d.stage_id,
      (d.workspace_id = c.workspace_id AND d.product_id = c.product_id AND
       d.activity_id = c.activity_id AND d.actor_id = c.actor_id AND
       d.previous_start = c.previous_start AND d.previous_end = c.previous_end AND
       d.new_start = c.new_start AND d.new_end = c.new_end AND
       d.version_before = c.version_before AND d.version_after = c.version_after AND
       d.reason = c.reason) AS audit_matches
    FROM public.calendar_reschedule_changes AS c
    JOIN public.activity_date_changes AS d ON d.operation_id = c.date_operation_id
    WHERE c.workspace_id = p_workspace_id AND c.product_id = p_product_id
      AND c.batch_operation_id = p_original_batch_id
    ORDER BY c.activity_id
  LOOP
    IF v_change.audit_matches IS NOT TRUE THEN
      RAISE EXCEPTION 'Original calendar reschedule audit is inconsistent.' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO v_activity FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id = v_change.discipline_id AND stage_id = v_change.stage_id
        AND id = v_change.activity_id FOR UPDATE;
    IF NOT FOUND OR v_activity.version <> v_change.version_after OR
       v_activity.planned_start IS DISTINCT FROM v_change.new_start OR
       v_activity.planned_end IS DISTINCT FROM v_change.new_end OR
       v_activity.planning_mode IS DISTINCT FROM 'working_days' OR
       v_activity.working_day_duration IS DISTINCT FROM v_change.working_day_duration OR
       v_activity.planning_calendar_version IS DISTINCT FROM v_change.new_calendar_version THEN
      RETURN jsonb_build_object('status', 'stale', 'activityId', v_change.activity_id);
    END IF;
    v_count := v_count + 1;
  END LOOP;

  FOR v_change IN
    SELECT c.*, d.discipline_id, d.stage_id
    FROM public.calendar_reschedule_changes AS c
    JOIN public.activity_date_changes AS d ON d.operation_id = c.date_operation_id
    WHERE c.workspace_id = p_workspace_id AND c.product_id = p_product_id
      AND c.batch_operation_id = p_original_batch_id
    ORDER BY c.activity_id
  LOOP
    v_date_operation_id := gen_random_uuid();
    PERFORM set_config('jlproject.date_operation_id', v_date_operation_id::text, true);
    PERFORM set_config('jlproject.date_change_reason', p_reason, true);
    PERFORM set_config('jlproject.date_actor_id', p_actor_id::text, true);
    UPDATE public.stage_activities
      SET planned_start = v_change.previous_start, planned_end = v_change.previous_end,
        planning_mode = 'working_days',
        working_day_duration = v_change.working_day_duration,
        planning_calendar_version = v_change.previous_calendar_version,
        version = version + 1, updated_by = p_actor_id, updated_at = clock_timestamp()
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id = v_change.discipline_id AND stage_id = v_change.stage_id
        AND id = v_change.activity_id AND version = v_change.version_after;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
    IF v_affected <> 1 THEN
      RAISE EXCEPTION 'Calendar reversal changed during execution.' USING ERRCODE = '40001';
    END IF;
    INSERT INTO public.calendar_reschedule_reversals
      (reversal_date_operation_id, original_date_operation_id,
       original_batch_operation_id, reversal_batch_operation_id,
       workspace_id, product_id, activity_id, actor_id,
       before_start, before_end, restored_start, restored_end,
       before_planning_mode, restored_planning_mode,
       before_working_day_duration, restored_working_day_duration,
       before_calendar_version, restored_calendar_version,
       version_before, version_after, reason)
    VALUES (v_date_operation_id, v_change.date_operation_id,
      p_original_batch_id, p_reversal_batch_id,
      p_workspace_id, p_product_id, v_change.activity_id, p_actor_id,
      v_change.new_start, v_change.new_end, v_change.previous_start, v_change.previous_end,
      'working_days', 'working_days',
      v_change.working_day_duration, v_change.working_day_duration,
      v_change.new_calendar_version, v_change.previous_calendar_version,
      v_change.version_after, v_change.version_after + 1, p_reason);
  END LOOP;
  RETURN jsonb_build_object('status', 'reversed', 'count', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)
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
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'DELETE') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid =
       'public.calendar_reschedule_reversals'::regclass) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid =
       'public.calendar_reschedule_reversals'::regclass
       AND tgname = 'calendar_reschedule_reversals_append_only' AND tgenabled IN ('O', 'A')) OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Calendar reversal privileges are not restricted.';
  END IF;
END;
$$;

COMMIT;
