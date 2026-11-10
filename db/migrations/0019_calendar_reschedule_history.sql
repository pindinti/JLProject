BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     to_regclass('public.calendar_reschedule_changes') IS NULL OR
     to_regclass('public.calendar_reschedule_reversals') IS NULL OR
     to_regprocedure('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)') IS NULL OR
     to_regprocedure('public.list_calendar_reschedule_history(uuid,uuid,uuid)') IS NOT NULL OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspaces', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.activity_date_changes', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_changes', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid =
       'public.calendar_reschedule_changes'::regclass) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid =
       'public.calendar_reschedule_reversals'::regclass) <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'Calendar reschedule history migration prerequisites are not satisfied.';
  END IF;
END;
$$;

GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

CREATE FUNCTION public.list_calendar_reschedule_history(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_operations jsonb;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = p_workspace_id) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id AND active = true) THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id AND active = true) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  WITH activity_rows AS (
    SELECT c.batch_operation_id, c.workspace_id, c.product_id, c.actor_id, c.reason,
      c.changed_at, c.activity_id, a.name AS activity_name,
      c.previous_start, c.previous_end, c.new_start, c.new_end,
      a.planned_start AS current_start, a.planned_end AS current_end,
      a.version AS current_version,
      COALESCE((d.workspace_id = c.workspace_id AND d.product_id = c.product_id AND
       d.activity_id = c.activity_id AND d.actor_id = c.actor_id AND
       d.previous_start = c.previous_start AND d.previous_end = c.previous_end AND
       d.new_start = c.new_start AND d.new_end = c.new_end AND
       d.version_before = c.version_before AND d.version_after = c.version_after AND
       d.reason = c.reason), false) AS audit_consistent,
      COALESCE((a.version = c.version_after AND a.planned_start IS NOT DISTINCT FROM c.new_start AND
       a.planned_end IS NOT DISTINCT FROM c.new_end AND a.planning_mode = 'working_days' AND
       a.working_day_duration = c.working_day_duration AND
       a.planning_calendar_version = c.new_calendar_version), false) AS state_unchanged,
      (SELECT count(*)::integer FROM public.calendar_reschedule_reversals AS rr
        WHERE rr.workspace_id = c.workspace_id AND rr.product_id = c.product_id
          AND rr.original_batch_operation_id = c.batch_operation_id) AS reversed_count,
      (SELECT max(rr.reversed_at) FROM public.calendar_reschedule_reversals AS rr
        WHERE rr.workspace_id = c.workspace_id AND rr.product_id = c.product_id
          AND rr.original_batch_operation_id = c.batch_operation_id) AS reversed_at,
      (SELECT (array_agg(rr.actor_id))[1] FROM public.calendar_reschedule_reversals AS rr
        WHERE rr.workspace_id = c.workspace_id AND rr.product_id = c.product_id
          AND rr.original_batch_operation_id = c.batch_operation_id) AS reversal_actor_id,
      (SELECT (array_agg(rr.reason))[1] FROM public.calendar_reschedule_reversals AS rr
        WHERE rr.workspace_id = c.workspace_id AND rr.product_id = c.product_id
          AND rr.original_batch_operation_id = c.batch_operation_id) AS reversal_reason
    FROM public.calendar_reschedule_changes AS c
    JOIN public.activity_date_changes AS d ON d.operation_id = c.date_operation_id
    LEFT JOIN public.stage_activities AS a ON a.workspace_id = c.workspace_id
      AND a.product_id = c.product_id AND a.id = c.activity_id
    WHERE c.workspace_id = p_workspace_id AND c.product_id = p_product_id
  ), batches AS (
    SELECT batch_operation_id, actor_id, reason, min(changed_at) AS changed_at,
      count(*)::integer AS activity_count, max(reversed_count) AS reversed_count,
      bool_and(audit_consistent AND state_unchanged) AS state_eligible,
      jsonb_agg(jsonb_build_object(
        'activityId', activity_id,
        'name', activity_name,
        'previousStart', to_char(previous_start, 'YYYY-MM-DD'),
        'previousEnd', to_char(previous_end, 'YYYY-MM-DD'),
        'newStart', to_char(new_start, 'YYYY-MM-DD'),
        'newEnd', to_char(new_end, 'YYYY-MM-DD'),
        'currentStart', to_char(current_start, 'YYYY-MM-DD'),
        'currentEnd', to_char(current_end, 'YYYY-MM-DD'),
        'currentVersion', current_version
      ) ORDER BY activity_name, activity_id) AS activities,
      max(reversed_at) AS reversed_at,
      (array_agg(reversal_actor_id) FILTER (WHERE reversal_actor_id IS NOT NULL))[1] AS reversal_actor_id,
      (array_agg(reversal_reason) FILTER (WHERE reversal_reason IS NOT NULL))[1] AS reversal_reason
    FROM activity_rows
    GROUP BY batch_operation_id, actor_id, reason
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'operationId', batch_operation_id,
    'changedAt', to_char(changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'actorId', actor_id,
    'reason', reason,
    'status', CASE
      WHEN reversed_count = activity_count THEN 'already_reversed'
      WHEN reversed_count > 0 THEN 'conflict'
      WHEN state_eligible THEN 'eligible'
      ELSE 'conflict'
    END,
    'reversal', CASE WHEN reversed_count = 0 THEN NULL ELSE jsonb_build_object(
      'changedAt', to_char(reversed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'actorId', reversal_actor_id,
      'reason', reversal_reason
    ) END,
    'activities', activities
  ) ORDER BY changed_at DESC, batch_operation_id DESC), '[]'::jsonb)
  INTO v_operations
  FROM batches;

  RETURN jsonb_build_object('status', 'ok', 'operations', v_operations);
END;
$$;

REVOKE ALL ON FUNCTION public.list_calendar_reschedule_history(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_calendar_reschedule_history(uuid,uuid,uuid) TO jlproject_worker;

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
       'public.list_calendar_reschedule_history(uuid,uuid,uuid)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_calendar_reschedule_history(uuid,uuid,uuid)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'DELETE') OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_calendar_reschedule_history(uuid,uuid,uuid)'::regprocedure)
       <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'Calendar reschedule history privileges are not restricted.';
  END IF;
END;
$$;

COMMIT;
