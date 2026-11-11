BEGIN;

-- Apply once with the reviewed JLProject Development owner role after verifying
-- the Neon project and branch outside PostgreSQL.
DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker'
       AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor'
       AND NOT rolcanlogin) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
       AND attname = 'discipline_id' AND NOT attisdropped) IS DISTINCT FROM true OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
       AND attname = 'stage_id' AND NOT attisdropped) IS DISTINCT FROM true OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.activity_date_changes'::regclass
       AND attname = 'discipline_id' AND NOT attisdropped) IS DISTINCT FROM true OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.activity_date_changes'::regclass
       AND attname = 'stage_id' AND NOT attisdropped) IS DISTINCT FROM true OR
     to_regprocedure('public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)') IS NULL OR
     to_regprocedure('public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)') IS NULL OR
     to_regprocedure('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)') IS NULL OR
     to_regprocedure('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)') IS NULL OR
     to_regprocedure('public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)') IS NULL OR
     to_regprocedure('public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)') IS NULL OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL OR
     to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NULL OR
     to_regprocedure('public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)') IS NOT NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.guard_schedule_deletion()'::regprocedure) <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) <> 'neondb_owner' OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'INSERT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'workspace_id', 'REFERENCES') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'product_id', 'REFERENCES') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'id', 'REFERENCES') OR
     EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname IN ('stage_activities_parent_pair_check', 'stage_activities_product_scope_fk',
         'stage_activities_product_scope_id_unique')) OR
     to_regclass('public.stage_activities_root_order_idx') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname IN ('activity_date_changes_parent_pair_check', 'activity_date_changes_product_scope_fk')) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_activity_fk' AND contype = 'f') OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE (discipline_id IS NULL) <> (stage_id IS NULL)) OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Root activity migration prerequisites or limited-role grants differ from the reviewed development state.';
  END IF;
END;
$$;

-- A stage activity has both stage parents; a root activity has neither. Direct
-- product scope remains enforced even when the composite stage FK sees NULLs.
ALTER TABLE public.stage_activities
  ALTER COLUMN discipline_id DROP NOT NULL,
  ALTER COLUMN stage_id DROP NOT NULL,
  ADD CONSTRAINT stage_activities_parent_pair_check CHECK (
    (discipline_id IS NULL AND stage_id IS NULL) OR
    (discipline_id IS NOT NULL AND stage_id IS NOT NULL)
  ),
  ADD CONSTRAINT stage_activities_product_scope_id_unique UNIQUE (workspace_id, product_id, id),
  ADD CONSTRAINT stage_activities_product_scope_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT;

CREATE INDEX stage_activities_root_order_idx
  ON public.stage_activities (workspace_id, product_id, display_order, id)
  WHERE discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL;

-- Preserve the original composite stage FK: it validates stage ancestry for
-- stage activities and is bypassed for root activities' all-NULL parent pair.

CREATE OR REPLACE FUNCTION public.guard_schedule_deletion() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical schedule deletion is forbidden.' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NOT NULL OR OLD.deletion_operation_id IS NOT NULL THEN
      RAISE EXCEPTION 'Deleted schedule items are immutable.' USING ERRCODE = '23514';
    END IF;
    IF (NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR
        NEW.deletion_operation_id IS DISTINCT FROM OLD.deletion_operation_id) AND
       current_user <> 'jlproject_date_executor' THEN
      RAISE EXCEPTION 'Controlled schedule deletion is required.' USING ERRCODE = '42501';
    END IF;
  ELSIF NEW.deleted_at IS NOT NULL OR NEW.deletion_operation_id IS NOT NULL THEN
    RAISE EXCEPTION 'New schedule items must be active.' USING ERRCODE = '23514';
  END IF;
  IF TG_TABLE_NAME = 'discipline_stages' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.product_disciplines AS d WHERE d.id = NEW.discipline_id
        AND d.workspace_id = NEW.workspace_id AND d.product_id = NEW.product_id
        AND d.deleted_at IS NULL
    ) THEN RAISE EXCEPTION 'Parent discipline is inactive.' USING ERRCODE = '23514'; END IF;
  ELSIF TG_TABLE_NAME = 'stage_activities' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.products AS p
      WHERE p.workspace_id = NEW.workspace_id AND p.id = NEW.product_id AND p.active = true
        AND ((NEW.discipline_id IS NULL AND NEW.stage_id IS NULL) OR EXISTS (
          SELECT 1 FROM public.discipline_stages AS s
          JOIN public.product_disciplines AS d ON d.workspace_id = s.workspace_id
            AND d.product_id = s.product_id AND d.id = s.discipline_id
          WHERE s.id = NEW.stage_id AND s.workspace_id = NEW.workspace_id
            AND s.product_id = NEW.product_id AND s.discipline_id = NEW.discipline_id
            AND s.deleted_at IS NULL AND d.deleted_at IS NULL
        ))
    ) THEN RAISE EXCEPTION 'Parent product or stage is inactive.' USING ERRCODE = '23514'; END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_schedule_deletion() FROM PUBLIC;

-- Date triggers already persist the parent pair from OLD; nullable pairs plus
-- the product-scope FK make that existing append-only audit valid for roots.
-- The executor owns the append-only date audit table. REFERENCES is temporary
-- and scoped to the three direct-scope target columns for the new composite FK.
GRANT REFERENCES (workspace_id, product_id, id)
  ON public.stage_activities TO jlproject_date_executor;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

ALTER TABLE public.activity_date_changes
  ALTER COLUMN discipline_id DROP NOT NULL,
  ALTER COLUMN stage_id DROP NOT NULL,
  ADD CONSTRAINT activity_date_changes_parent_pair_check CHECK (
    (discipline_id IS NULL AND stage_id IS NULL) OR
    (discipline_id IS NOT NULL AND stage_id IS NOT NULL)
  ),
  ADD CONSTRAINT activity_date_changes_product_scope_fk
    FOREIGN KEY (workspace_id, product_id, activity_id)
    REFERENCES public.stage_activities(workspace_id, product_id, id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION public.change_activity_planning(
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
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_activity_id IS NULL OR p_actor_id IS NULL OR
     p_operation_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 OR
     ((p_discipline_id IS NULL) <> (p_stage_id IS NULL)) OR
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
  IF p_stage_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.discipline_stages AS s
    JOIN public.product_disciplines AS d ON d.workspace_id = s.workspace_id
      AND d.product_id = s.product_id AND d.id = s.discipline_id
    WHERE s.workspace_id = p_workspace_id AND s.product_id = p_product_id
      AND s.discipline_id = p_discipline_id AND s.id = p_stage_id
      AND s.deleted_at IS NULL AND d.deleted_at IS NULL
  ) THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  SELECT activity.* INTO v_activity FROM public.stage_activities AS activity
    WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_product_id
      AND activity.discipline_id IS NOT DISTINCT FROM p_discipline_id
      AND activity.stage_id IS NOT DISTINCT FROM p_stage_id
      AND activity.id = p_activity_id AND activity.deleted_at IS NULL
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
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND id = p_activity_id
      AND discipline_id IS NOT DISTINCT FROM p_discipline_id
      AND stage_id IS NOT DISTINCT FROM p_stage_id;
  RETURN jsonb_build_object('status', 'updated');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_activity_with_working_plan(
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
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     ((p_discipline_id IS NULL) <> (p_stage_id IS NULL)) OR p_name IS NULL OR
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
  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace_id
    AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF p_stage_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.discipline_stages AS s
    JOIN public.product_disciplines AS d ON d.workspace_id = s.workspace_id
      AND d.product_id = s.product_id AND d.id = s.discipline_id
    WHERE s.workspace_id = p_workspace_id AND s.product_id = p_product_id
      AND s.discipline_id = p_discipline_id AND s.id = p_stage_id
      AND s.deleted_at IS NULL AND d.deleted_at IS NULL
  ) THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
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

CREATE OR REPLACE FUNCTION public.apply_calendar_reschedule(
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
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_proposals) AS entry(value)
    ORDER BY value->>'activityId' LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' OR
       (SELECT count(*) FROM jsonb_object_keys(v_item)) <> 9 OR
       NOT (v_item ?& ARRAY['activityId', 'disciplineId', 'stageId', 'expectedVersion',
         'startDate', 'currentEndDate', 'proposedEndDate', 'workingDays', 'savedCalendarVersion']) OR
       jsonb_typeof(v_item->'disciplineId') NOT IN ('string', 'null') OR
       jsonb_typeof(v_item->'stageId') NOT IN ('string', 'null') OR
       ((jsonb_typeof(v_item->'disciplineId') = 'null') IS DISTINCT FROM
        (jsonb_typeof(v_item->'stageId') = 'null')) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    IF (v_item->>'activityId')::uuid = ANY(v_seen) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    v_seen := array_append(v_seen, (v_item->>'activityId')::uuid);
    SELECT * INTO v_activity FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND id = (v_item->>'activityId')::uuid
        AND discipline_id IS NOT DISTINCT FROM (v_item->>'disciplineId')::uuid
        AND stage_id IS NOT DISTINCT FROM (v_item->>'stageId')::uuid
        AND deleted_at IS NULL FOR UPDATE;
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

CREATE OR REPLACE FUNCTION public.reverse_calendar_reschedule(
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
  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace_id
    AND id = p_product_id AND active = true FOR UPDATE;
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
        AND discipline_id IS NOT DISTINCT FROM v_change.discipline_id
        AND stage_id IS NOT DISTINCT FROM v_change.stage_id
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
        planning_mode = 'working_days', working_day_duration = v_change.working_day_duration,
        planning_calendar_version = v_change.previous_calendar_version,
        version = version + 1, updated_by = p_actor_id, updated_at = clock_timestamp()
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id IS NOT DISTINCT FROM v_change.discipline_id
        AND stage_id IS NOT DISTINCT FROM v_change.stage_id
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
      'working_days', 'working_days', v_change.working_day_duration,
      v_change.working_day_duration, v_change.new_calendar_version,
      v_change.previous_calendar_version, v_change.version_after,
      v_change.version_after + 1, p_reason);
  END LOOP;
  RETURN jsonb_build_object('status', 'reversed', 'count', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.preview_schedule_deletion(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid, p_kind text, p_target_id uuid
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_items jsonb; v_role text;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_target_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('activity', 'stage', 'discipline') THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  SELECT m.role INTO v_role FROM public.workspace_memberships AS m
    WHERE m.workspace_id = p_workspace_id AND m.auth_user_id = p_actor_id AND m.active = true;
  IF v_role IS NULL OR v_role NOT IN ('admin', 'editor') THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products AS p WHERE p.id = p_product_id
      AND p.workspace_id = p_workspace_id AND p.active = true) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF p_kind = 'discipline' AND NOT EXISTS (
    SELECT 1 FROM public.product_disciplines AS d WHERE d.id = p_target_id
      AND d.workspace_id = p_workspace_id AND d.product_id = p_product_id AND d.deleted_at IS NULL
  ) THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF p_kind = 'stage' AND NOT EXISTS (
    SELECT 1 FROM public.discipline_stages AS s
      JOIN public.product_disciplines AS d ON d.id = s.discipline_id AND d.deleted_at IS NULL
    WHERE s.id = p_target_id AND s.workspace_id = p_workspace_id AND s.product_id = p_product_id
      AND s.deleted_at IS NULL
  ) THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF p_kind = 'activity' AND NOT EXISTS (
    SELECT 1 FROM public.stage_activities AS a
    WHERE a.id = p_target_id AND a.workspace_id = p_workspace_id
      AND a.product_id = p_product_id AND a.deleted_at IS NULL
      AND ((a.discipline_id IS NULL AND a.stage_id IS NULL) OR EXISTS (
        SELECT 1 FROM public.discipline_stages AS s
        JOIN public.product_disciplines AS d ON d.workspace_id = s.workspace_id
          AND d.product_id = s.product_id AND d.id = s.discipline_id
        WHERE s.workspace_id = a.workspace_id AND s.product_id = a.product_id
          AND s.id = a.stage_id AND s.discipline_id = a.discipline_id
          AND s.deleted_at IS NULL AND d.deleted_at IS NULL
      ))
  ) THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', kind, 'id', id, 'version', version)
    ORDER BY rank, id), '[]'::jsonb) INTO v_items FROM (
    SELECT 1 AS rank, 'discipline' AS kind, d.id, d.version
      FROM public.product_disciplines AS d WHERE p_kind = 'discipline' AND d.id = p_target_id
        AND d.workspace_id = p_workspace_id AND d.product_id = p_product_id AND d.deleted_at IS NULL
    UNION ALL
    SELECT 2, 'stage', s.id, s.version FROM public.discipline_stages AS s
      WHERE s.workspace_id = p_workspace_id AND s.product_id = p_product_id AND s.deleted_at IS NULL
        AND ((p_kind = 'stage' AND s.id = p_target_id) OR
             (p_kind = 'discipline' AND s.discipline_id = p_target_id))
    UNION ALL
    SELECT 3, 'activity', a.id, a.version FROM public.stage_activities AS a
      WHERE a.workspace_id = p_workspace_id AND a.product_id = p_product_id AND a.deleted_at IS NULL
        AND ((p_kind = 'activity' AND a.id = p_target_id) OR
             (p_kind = 'stage' AND a.stage_id = p_target_id) OR
             (p_kind = 'discipline' AND a.discipline_id = p_target_id))
  ) AS affected;
  RETURN jsonb_build_object('status', 'ok', 'fingerprint', md5(v_items::text),
    'counts', jsonb_build_object(
      'disciplines', (SELECT count(*) FROM jsonb_array_elements(v_items) AS i WHERE i->>'kind' = 'discipline'),
      'stages', (SELECT count(*) FROM jsonb_array_elements(v_items) AS i WHERE i->>'kind' = 'stage'),
      'activities', (SELECT count(*) FROM jsonb_array_elements(v_items) AS i WHERE i->>'kind' = 'activity')),
    'items', v_items);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_product_change_history(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid, p_limit integer,
  p_before_at timestamptz, p_before_id text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_events jsonb;
  v_has_more boolean;
  v_next_cursor jsonb;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR
     ((p_before_at IS NULL) <> (p_before_id IS NULL)) OR
     (p_before_id IS NOT NULL AND p_before_id !~
       '^[a-z][a-z0-9_-]*:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = p_workspace_id AND membership.auth_user_id = p_actor_id
      AND membership.active = true) THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_product_id) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  WITH deletion_items AS (
    SELECT event.operation_id, 1 AS kind_order, item.id,
      jsonb_build_object('kind', 'discipline', 'id', item.id::text, 'name', discipline.name,
        'versionBefore', item.version, 'hierarchy', jsonb_build_object('discipline', discipline.name)) AS value
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.product_disciplines AS discipline ON item.kind = 'discipline'
      AND discipline.id = item.id AND discipline.workspace_id = event.workspace_id
      AND discipline.product_id = event.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id
    UNION ALL
    SELECT event.operation_id, 2, item.id,
      jsonb_build_object('kind', 'stage', 'id', item.id::text, 'name', stage.display_name,
        'versionBefore', item.version,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.discipline_stages AS stage ON item.kind = 'stage' AND stage.id = item.id
      AND stage.workspace_id = event.workspace_id AND stage.product_id = event.product_id
    JOIN public.product_disciplines AS discipline ON discipline.id = stage.discipline_id
      AND discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id
    UNION ALL
    SELECT event.operation_id, 3, item.id,
      jsonb_build_object('kind', 'activity', 'id', item.id::text, 'name', activity.name,
        'versionBefore', item.version,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.stage_activities AS activity ON item.kind = 'activity' AND activity.id = item.id
      AND activity.workspace_id = event.workspace_id AND activity.product_id = event.product_id
    LEFT JOIN public.discipline_stages AS stage ON stage.id = activity.stage_id
      AND stage.workspace_id = activity.workspace_id AND stage.product_id = activity.product_id
    LEFT JOIN public.product_disciplines AS discipline ON discipline.id = activity.discipline_id
      AND discipline.workspace_id = activity.workspace_id AND discipline.product_id = activity.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id
  ), deletion_item_lists AS (
    SELECT operation_id, jsonb_agg(value ORDER BY kind_order, id) AS items
    FROM deletion_items GROUP BY operation_id
  ), event_feed AS (
    SELECT 'product:' || product.id::text AS event_id, product.created_at AS occurred_at,
      product.created_by AS actor_id, 'product_created'::text AS event_type,
      jsonb_build_object('kind', 'product', 'id', product.id::text, 'name', product.name) AS item,
      NULL::text AS justification, NULL::jsonb AS before_details, NULL::jsonb AS after_details,
      '[]'::jsonb AS affected_items
    FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_product_id
    UNION ALL
    SELECT 'import:' || batch.id::text, batch.created_at, batch.created_by, 'schedule_imported',
      jsonb_build_object('kind', 'product', 'id', product.id::text, 'name', product.name),
      NULL::text, NULL::jsonb,
      jsonb_build_object('sourceReferenceCount', (SELECT count(source.import_batch_id)
        FROM public.import_source_rows AS source WHERE source.import_batch_id = batch.id)),
      '[]'::jsonb
    FROM public.import_batches AS batch
    JOIN public.products AS product ON product.workspace_id = batch.workspace_id
      AND product.id = batch.product_id
    WHERE batch.workspace_id = p_workspace_id AND batch.product_id = p_product_id
    UNION ALL
    SELECT 'activity-date:' || change.operation_id::text, change.changed_at, change.actor_id,
      'activity_dates_changed',
      jsonb_build_object('kind', 'activity', 'id', activity.id::text, 'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name)),
      change.reason,
      jsonb_build_object('plannedStart', to_char(change.previous_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.previous_end, 'YYYY-MM-DD')),
      jsonb_build_object('plannedStart', to_char(change.new_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.new_end, 'YYYY-MM-DD')),
      '[]'::jsonb
    FROM public.activity_date_changes AS change
    JOIN public.stage_activities AS activity ON activity.workspace_id = change.workspace_id
      AND activity.product_id = change.product_id AND activity.id = change.activity_id
    LEFT JOIN public.discipline_stages AS stage ON stage.workspace_id = change.workspace_id
      AND stage.product_id = change.product_id AND stage.id = change.stage_id
    LEFT JOIN public.product_disciplines AS discipline ON discipline.workspace_id = change.workspace_id
      AND discipline.product_id = change.product_id AND discipline.id = change.discipline_id
    WHERE change.workspace_id = p_workspace_id AND change.product_id = p_product_id
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes AS reschedule
        WHERE reschedule.date_operation_id = change.operation_id)
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals AS reversal
        WHERE reversal.reversal_date_operation_id = change.operation_id)
    UNION ALL
    SELECT 'target-date:' || change.operation_id::text, change.changed_at, change.actor_id,
      'business_target_date_changed',
      jsonb_build_object('kind', 'business_target', 'id', target.id::text, 'name', target.name),
      change.reason, jsonb_build_object('targetDate', to_char(change.previous_date, 'YYYY-MM-DD')),
      jsonb_build_object('targetDate', to_char(change.new_date, 'YYYY-MM-DD')), '[]'::jsonb
    FROM public.business_target_date_changes AS change
    JOIN public.business_targets AS target ON target.workspace_id = change.workspace_id
      AND target.product_id = change.product_id AND target.id = change.target_id
    WHERE change.workspace_id = p_workspace_id AND change.product_id = p_product_id
    UNION ALL
    SELECT 'calendar-reschedule:' || reschedule.batch_operation_id::text,
      min(reschedule.changed_at), reschedule.actor_id, 'calendar_rescheduled',
      jsonb_build_object('kind', 'calendar_reschedule', 'id', reschedule.batch_operation_id::text,
        'name', NULL), reschedule.reason,
      jsonb_build_object('activities', jsonb_agg(jsonb_build_object(
        'activityId', reschedule.activity_id::text,
        'plannedStart', to_char(reschedule.previous_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(reschedule.previous_end, 'YYYY-MM-DD'),
        'workingDays', reschedule.working_day_duration,
        'calendarVersion', reschedule.previous_calendar_version)
        ORDER BY activity.name, reschedule.activity_id)),
      jsonb_build_object('activities', jsonb_agg(jsonb_build_object(
        'activityId', reschedule.activity_id::text,
        'plannedStart', to_char(reschedule.new_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(reschedule.new_end, 'YYYY-MM-DD'),
        'workingDays', reschedule.working_day_duration,
        'calendarVersion', reschedule.new_calendar_version)
        ORDER BY activity.name, reschedule.activity_id)),
      jsonb_agg(jsonb_build_object('kind', 'activity', 'id', reschedule.activity_id::text,
        'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
        ORDER BY activity.name, reschedule.activity_id)
    FROM public.calendar_reschedule_changes AS reschedule
    JOIN public.stage_activities AS activity ON activity.workspace_id = reschedule.workspace_id
      AND activity.product_id = reschedule.product_id AND activity.id = reschedule.activity_id
    LEFT JOIN public.discipline_stages AS stage ON stage.workspace_id = activity.workspace_id
      AND stage.product_id = activity.product_id AND stage.id = activity.stage_id
    LEFT JOIN public.product_disciplines AS discipline ON discipline.workspace_id = activity.workspace_id
      AND discipline.product_id = activity.product_id AND discipline.id = activity.discipline_id
    WHERE reschedule.workspace_id = p_workspace_id AND reschedule.product_id = p_product_id
    GROUP BY reschedule.batch_operation_id, reschedule.actor_id, reschedule.reason
    UNION ALL
    SELECT 'calendar-reversal:' || reversal.reversal_batch_operation_id::text,
      min(reversal.reversed_at), reversal.actor_id, 'calendar_reschedule_reversed',
      jsonb_build_object('kind', 'calendar_reschedule_reversal',
        'id', reversal.reversal_batch_operation_id::text, 'name', NULL), reversal.reason,
      jsonb_build_object('originalOperationId', reversal.original_batch_operation_id::text,
        'activities', jsonb_agg(jsonb_build_object('activityId', reversal.activity_id::text,
          'plannedStart', to_char(reversal.before_start, 'YYYY-MM-DD'),
          'plannedEnd', to_char(reversal.before_end, 'YYYY-MM-DD'),
          'calendarVersion', reversal.before_calendar_version)
          ORDER BY activity.name, reversal.activity_id)),
      jsonb_build_object('originalOperationId', reversal.original_batch_operation_id::text,
        'activities', jsonb_agg(jsonb_build_object('activityId', reversal.activity_id::text,
          'plannedStart', to_char(reversal.restored_start, 'YYYY-MM-DD'),
          'plannedEnd', to_char(reversal.restored_end, 'YYYY-MM-DD'),
          'calendarVersion', reversal.restored_calendar_version)
          ORDER BY activity.name, reversal.activity_id)),
      jsonb_agg(jsonb_build_object('kind', 'activity', 'id', reversal.activity_id::text,
        'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
        ORDER BY activity.name, reversal.activity_id)
    FROM public.calendar_reschedule_reversals AS reversal
    JOIN public.stage_activities AS activity ON activity.workspace_id = reversal.workspace_id
      AND activity.product_id = reversal.product_id AND activity.id = reversal.activity_id
    LEFT JOIN public.discipline_stages AS stage ON stage.workspace_id = activity.workspace_id
      AND stage.product_id = activity.product_id AND stage.id = activity.stage_id
    LEFT JOIN public.product_disciplines AS discipline ON discipline.workspace_id = activity.workspace_id
      AND discipline.product_id = activity.product_id AND discipline.id = activity.discipline_id
    WHERE reversal.workspace_id = p_workspace_id AND reversal.product_id = p_product_id
    GROUP BY reversal.reversal_batch_operation_id, reversal.original_batch_operation_id,
      reversal.actor_id, reversal.reason
    UNION ALL
    SELECT 'deletion:' || deletion.operation_id::text, deletion.changed_at, deletion.actor_id,
      'schedule_hierarchy_deleted',
      CASE deletion.target_kind
        WHEN 'discipline' THEN (SELECT jsonb_build_object('kind', 'discipline', 'id', d.id::text,
          'name', d.name, 'hierarchy', jsonb_build_object('discipline', d.name))
          FROM public.product_disciplines AS d WHERE d.workspace_id = deletion.workspace_id
            AND d.product_id = deletion.product_id AND d.id = deletion.target_id)
        WHEN 'stage' THEN (SELECT jsonb_build_object('kind', 'stage', 'id', s.id::text,
          'name', s.display_name, 'hierarchy', jsonb_build_object('discipline', d.name, 'stage', s.display_name))
          FROM public.discipline_stages AS s JOIN public.product_disciplines AS d
            ON d.workspace_id = s.workspace_id AND d.product_id = s.product_id AND d.id = s.discipline_id
          WHERE s.workspace_id = deletion.workspace_id AND s.product_id = deletion.product_id
            AND s.id = deletion.target_id)
        ELSE (SELECT jsonb_build_object('kind', 'activity', 'id', a.id::text,
          'name', a.name, 'hierarchy', jsonb_build_object('discipline', d.name, 'stage', s.display_name))
          FROM public.stage_activities AS a
          LEFT JOIN public.discipline_stages AS s ON s.workspace_id = a.workspace_id
            AND s.product_id = a.product_id AND s.id = a.stage_id
          LEFT JOIN public.product_disciplines AS d ON d.workspace_id = a.workspace_id
            AND d.product_id = a.product_id AND d.id = a.discipline_id
          WHERE a.workspace_id = deletion.workspace_id AND a.product_id = deletion.product_id
            AND a.id = deletion.target_id)
      END,
      deletion.reason, NULL::jsonb,
      jsonb_build_object('targetKind', deletion.target_kind, 'targetId', deletion.target_id::text,
        'affectedCount', jsonb_array_length(deletion.affected_items)),
      COALESCE(deletion_items.items, '[]'::jsonb)
    FROM public.schedule_deletion_events AS deletion
    LEFT JOIN deletion_item_lists AS deletion_items ON deletion_items.operation_id = deletion.operation_id
    WHERE deletion.workspace_id = p_workspace_id AND deletion.product_id = p_product_id
  ), eligible AS MATERIALIZED (
    SELECT event.* FROM event_feed AS event
    WHERE p_before_at IS NULL OR
      (event.occurred_at, event.event_id COLLATE "C") < (p_before_at, p_before_id COLLATE "C")
    ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC LIMIT p_limit + 1
  ), page AS MATERIALIZED (
    SELECT * FROM eligible ORDER BY occurred_at DESC, event_id COLLATE "C" DESC LIMIT p_limit
  ), page_data AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', event.event_id, 'occurredAt', to_char(event.occurred_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'actorId', event.actor_id::text,
      'actorName', NULL, 'eventType', event.event_type, 'item', event.item,
      'justification', event.justification, 'before', event.before_details,
      'after', event.after_details, 'affectedItems', event.affected_items)
      ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC), '[]'::jsonb) AS events
    FROM page AS event
  ), pagination AS (
    SELECT EXISTS (SELECT 1 FROM eligible OFFSET p_limit) AS has_more
  ), cursor_data AS (
    SELECT jsonb_build_object('occurredAt', to_char(last_event.occurred_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'eventId', last_event.event_id) AS next_cursor
    FROM (SELECT occurred_at, event_id FROM page
      ORDER BY occurred_at ASC, event_id COLLATE "C" ASC LIMIT 1) AS last_event
  )
  SELECT page_data.events, pagination.has_more,
    CASE WHEN pagination.has_more THEN cursor_data.next_cursor ELSE NULL END
  INTO v_events, v_has_more, v_next_cursor
  FROM page_data CROSS JOIN pagination LEFT JOIN cursor_data ON true;
  RETURN jsonb_build_object('status', 'ok', 'events', v_events, 'nextCursor', v_next_cursor);
END;
$$;

CREATE FUNCTION public.clone_root_activity(
  p_workspace_id uuid, p_source_product_id uuid, p_target_product_id uuid,
  p_actor_id uuid, p_activity_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_activity public.stage_activities%ROWTYPE;
  v_new_activity_id uuid;
BEGIN
  IF p_workspace_id IS NULL OR p_source_product_id IS NULL OR p_target_product_id IS NULL OR
     p_actor_id IS NULL OR p_activity_id IS NULL OR p_source_product_id = p_target_product_id THEN
    RAISE EXCEPTION 'Invalid root activity clone scope.' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = p_workspace_id) OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships
       WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
         AND active = true AND role IN ('admin', 'editor')) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = p_workspace_id
       AND id = p_source_product_id AND active = true) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = p_workspace_id
       AND id = p_target_product_id AND active = true) THEN
    RAISE EXCEPTION 'Root activity clone scope is not authorized.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_activity FROM public.stage_activities
    WHERE workspace_id = p_workspace_id AND product_id = p_source_product_id
      AND id = p_activity_id AND discipline_id IS NULL AND stage_id IS NULL
      AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active source root activity was not found.' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
     planned_start, planned_end, display_order, notes, color_override, created_by, updated_by,
     planning_mode, working_day_duration, planning_calendar_version)
  VALUES (p_workspace_id, p_target_product_id, NULL, NULL, v_activity.name,
    v_activity.activity_type, v_activity.planned_start, v_activity.planned_end,
    v_activity.display_order, v_activity.notes, v_activity.color_override, p_actor_id, p_actor_id,
    v_activity.planning_mode, v_activity.working_day_duration,
    v_activity.planning_calendar_version)
  RETURNING id INTO v_new_activity_id;
  RETURN v_new_activity_id;
END;
$$;
REVOKE ALL ON FUNCTION public.clone_root_activity(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_root_activity(uuid,uuid,uuid,uuid,uuid) TO jlproject_worker;

RESET ROLE;
REVOKE REFERENCES (workspace_id, product_id, id)
  ON public.stage_activities FROM jlproject_date_executor;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

-- Keep stage cloning byte-for-byte equivalent in data selection; add a separate
-- root collection and copy root planning metadata through the guarded helper.
CREATE OR REPLACE FUNCTION public.clone_product(
  p_workspace_id uuid, p_source_product_id uuid, p_actor_id uuid, p_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_source_product public.products%ROWTYPE;
  v_product_id uuid;
  v_revision_id uuid;
  v_discipline record;
  v_stage record;
  v_activity record;
  v_root_activity record;
  v_target record;
  v_discipline_id uuid;
  v_stage_id uuid;
  v_activity_id uuid;
  v_target_id uuid;
  v_disciplines jsonb := '[]'::jsonb;
  v_stages jsonb;
  v_activities jsonb;
  v_root_activities jsonb := '[]'::jsonb;
  v_targets jsonb := '[]'::jsonb;
  v_discipline_ids jsonb := '{}'::jsonb;
  v_snapshot jsonb;
BEGIN
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name <> btrim(p_name) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;
  SELECT product.* INTO v_source_product FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_source_product_id
      AND product.active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
    VALUES (p_workspace_id, p_name, v_source_product.description, p_actor_id, p_actor_id)
    ON CONFLICT DO NOTHING RETURNING id INTO v_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'duplicate'); END IF;

  FOR v_discipline IN SELECT discipline.* FROM public.product_disciplines AS discipline
    WHERE discipline.workspace_id = p_workspace_id AND discipline.product_id = p_source_product_id
      AND discipline.deleted_at IS NULL
    ORDER BY discipline.display_order, discipline.id FOR UPDATE
  LOOP
    INSERT INTO public.product_disciplines
      (workspace_id, product_id, name, short_code, color, display_order, description, created_by, updated_by)
    VALUES (p_workspace_id, v_product_id, v_discipline.name, v_discipline.short_code,
      v_discipline.color, v_discipline.display_order, v_discipline.description, p_actor_id, p_actor_id)
    RETURNING id INTO v_discipline_id;
    v_stages := '[]'::jsonb;
    FOR v_stage IN
      SELECT stage.*, definition.code AS definition_code, definition.color AS definition_color
      FROM public.discipline_stages AS stage
      JOIN public.stage_definitions AS definition
        ON definition.workspace_id = stage.workspace_id AND definition.id = stage.definition_id
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = p_source_product_id
        AND stage.discipline_id = v_discipline.id AND stage.deleted_at IS NULL
      ORDER BY stage.display_order, stage.id FOR UPDATE OF stage, definition
    LOOP
      INSERT INTO public.discipline_stages
        (workspace_id, product_id, discipline_id, definition_id, display_name, display_order,
         created_by, updated_by)
      VALUES (p_workspace_id, v_product_id, v_discipline_id, v_stage.definition_id,
        v_stage.display_name, v_stage.display_order, p_actor_id, p_actor_id)
      RETURNING id INTO v_stage_id;
      v_activities := '[]'::jsonb;
      FOR v_activity IN SELECT activity.* FROM public.stage_activities AS activity
        WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_source_product_id
          AND activity.discipline_id = v_discipline.id AND activity.stage_id = v_stage.id
          AND activity.deleted_at IS NULL
        ORDER BY activity.display_order, activity.id FOR UPDATE
      LOOP
        INSERT INTO public.stage_activities
          (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
           planned_start, planned_end, display_order, notes, color_override, created_by, updated_by)
        VALUES (p_workspace_id, v_product_id, v_discipline_id, v_stage_id, v_activity.name,
          v_activity.activity_type, v_activity.planned_start, v_activity.planned_end,
          v_activity.display_order, v_activity.notes, v_activity.color_override, p_actor_id, p_actor_id)
        RETURNING id INTO v_activity_id;
        v_activities := v_activities || jsonb_build_array(jsonb_build_object(
          'id', v_activity_id, 'name', v_activity.name, 'activityType', v_activity.activity_type,
          'plannedStart', v_activity.planned_start, 'plannedEnd', v_activity.planned_end,
          'displayOrder', v_activity.display_order, 'notes', v_activity.notes,
          'colorOverride', v_activity.color_override));
      END LOOP;
      v_stages := v_stages || jsonb_build_array(jsonb_build_object(
        'id', v_stage_id, 'code', v_stage.definition_code, 'color', v_stage.definition_color,
        'displayName', v_stage.display_name, 'displayOrder', v_stage.display_order,
        'activities', v_activities));
    END LOOP;
    v_disciplines := v_disciplines || jsonb_build_array(jsonb_build_object(
      'id', v_discipline_id, 'name', v_discipline.name, 'shortCode', v_discipline.short_code,
      'color', v_discipline.color, 'displayOrder', v_discipline.display_order,
      'description', v_discipline.description, 'stages', v_stages));
    v_discipline_ids := v_discipline_ids || jsonb_build_object(v_discipline.name, v_discipline_id::text);
  END LOOP;

  FOR v_root_activity IN SELECT activity.* FROM public.stage_activities AS activity
    WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_source_product_id
      AND activity.discipline_id IS NULL AND activity.stage_id IS NULL AND activity.deleted_at IS NULL
    ORDER BY activity.display_order, activity.id FOR UPDATE
  LOOP
    v_activity_id := public.clone_root_activity(p_workspace_id, p_source_product_id,
      v_product_id, p_actor_id, v_root_activity.id);
    v_root_activities := v_root_activities || jsonb_build_array(jsonb_build_object(
      'id', v_activity_id, 'name', v_root_activity.name,
      'activityType', v_root_activity.activity_type,
      'plannedStart', v_root_activity.planned_start, 'plannedEnd', v_root_activity.planned_end,
      'displayOrder', v_root_activity.display_order, 'notes', v_root_activity.notes,
      'colorOverride', v_root_activity.color_override,
      'effectiveColor', COALESCE(v_root_activity.color_override, '#8D9A89'),
      'planningMode', v_root_activity.planning_mode,
      'workingDayDuration', v_root_activity.working_day_duration,
      'planningCalendarVersion', v_root_activity.planning_calendar_version));
  END LOOP;

  FOR v_target IN SELECT target.* FROM public.business_targets AS target
    WHERE target.workspace_id = p_workspace_id AND target.product_id = p_source_product_id
      AND target.deleted_at IS NULL ORDER BY target.display_order, target.id
  LOOP
    INSERT INTO public.business_targets
      (workspace_id, product_id, name, target_date, operational_date, display_order,
       created_by, description, color)
    VALUES (p_workspace_id, v_product_id, v_target.name, v_target.target_date,
      v_target.operational_date, v_target.display_order, p_actor_id, v_target.description, v_target.color)
    RETURNING id INTO v_target_id;
    v_targets := v_targets || jsonb_build_array(jsonb_build_object(
      'id', v_target_id, 'name', v_target.name, 'targetDate', v_target.target_date,
      'operationalDate', v_target.operational_date, 'displayOrder', v_target.display_order,
      'description', v_target.description, 'color', v_target.color));
  END LOOP;

  v_snapshot := jsonb_build_object(
    'product', jsonb_build_object('id', v_product_id, 'name', p_name),
    'rootActivities', v_root_activities, 'disciplines', v_disciplines,
    'sourceMeta', '[]'::jsonb, 'targets', v_targets,
    'actualStageColors', (SELECT COALESCE(jsonb_object_agg(lower(definition.code), definition.color), '{}'::jsonb)
      FROM public.discipline_stages AS stage
      JOIN public.stage_definitions AS definition
        ON definition.workspace_id = stage.workspace_id AND definition.id = stage.definition_id
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = v_product_id),
    'disciplineIds', v_discipline_ids,
    'stageIds', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', stage.id, 'disciplineId', stage.discipline_id,
        'code', definition.code, 'displayName', stage.display_name)
        ORDER BY discipline.display_order, stage.display_order, stage.id), '[]'::jsonb)
      FROM public.discipline_stages AS stage
      JOIN public.product_disciplines AS discipline
        ON discipline.workspace_id = stage.workspace_id AND discipline.id = stage.discipline_id
      JOIN public.stage_definitions AS definition
        ON definition.workspace_id = stage.workspace_id AND definition.id = stage.definition_id
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = v_product_id),
    'activityIds', '{}'::jsonb, 'dependencies', '[]'::jsonb);
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (p_workspace_id, v_product_id, NULL, v_snapshot, p_actor_id)
  RETURNING id INTO v_revision_id;
  RETURN jsonb_build_object('status', 'cloned',
    'product', jsonb_build_object('id', v_product_id, 'workspaceId', p_workspace_id,
      'name', p_name, 'description', v_source_product.description, 'active', true,
      'version', 1, 'createdAt', now(), 'updatedAt', now()),
    'revisionId', v_revision_id, 'revisionLabel', 'R00');
END;
$$;

DO $$
BEGIN
  IF (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
       AND attname = 'discipline_id' AND NOT attisdropped) OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.stage_activities'::regclass
       AND attname = 'stage_id' AND NOT attisdropped) OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.activity_date_changes'::regclass
       AND attname = 'discipline_id' AND NOT attisdropped) OR
     (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'public.activity_date_changes'::regclass
       AND attname = 'stage_id' AND NOT attisdropped) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_parent_pair_check' AND contype = 'c') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_parent_fk' AND contype = 'f') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_product_scope_fk' AND contype = 'f') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_product_scope_id_unique' AND contype = 'u') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_parent_pair_check' AND contype = 'c') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_product_scope_fk' AND contype = 'f') OR
     to_regclass('public.stage_activities_root_order_idx') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_dates_immutable' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.activity_date_changes'::regclass
       AND tgname = 'activity_date_changes_append_only' AND tgenabled IN ('O', 'A')) OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT prosecdef FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) IS DISTINCT FROM true OR
     NOT ((SELECT proconfig FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure)
       @> ARRAY['search_path=pg_catalog, pg_temp']) OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.guard_schedule_deletion()'::regprocedure) <> 'neondb_owner' OR
     NOT has_function_privilege('jlproject_worker',
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_function_privilege('public', 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'workspace_id', 'REFERENCES') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'product_id', 'REFERENCES') OR
     has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'id', 'REFERENCES') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Root activity migration postconditions or limited-role grants are incorrect.';
  END IF;
END;
$$;

COMMIT;




