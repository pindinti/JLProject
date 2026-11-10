BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.schedule_deletion_events') IS NOT NULL OR
     to_regprocedure('public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)') IS NOT NULL OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') THEN
    RAISE EXCEPTION 'Unexpected migration target or privilege state.';
  END IF;
END;
$$;

CREATE TABLE public.schedule_deletion_events (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  target_kind text NOT NULL CHECK (target_kind IN ('activity', 'stage', 'discipline')),
  target_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 10 AND 2000 AND reason = btrim(reason)),
  affected_items jsonb NOT NULL CHECK (jsonb_typeof(affected_items) = 'array' AND jsonb_array_length(affected_items) > 0),
  CONSTRAINT schedule_deletion_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT schedule_deletion_actor_fk FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT
);
CREATE INDEX schedule_deletion_events_scope_idx
  ON public.schedule_deletion_events (workspace_id, product_id, changed_at DESC);
REVOKE ALL ON public.schedule_deletion_events FROM PUBLIC, jlproject_worker;

ALTER TABLE public.product_disciplines
  ADD COLUMN deleted_at timestamptz,
  ADD COLUMN deletion_operation_id uuid REFERENCES public.schedule_deletion_events(operation_id) ON DELETE RESTRICT,
  ADD CONSTRAINT product_disciplines_deletion_pair CHECK ((deleted_at IS NULL) = (deletion_operation_id IS NULL));
ALTER TABLE public.discipline_stages
  ADD COLUMN deleted_at timestamptz,
  ADD COLUMN deletion_operation_id uuid REFERENCES public.schedule_deletion_events(operation_id) ON DELETE RESTRICT,
  ADD CONSTRAINT discipline_stages_deletion_pair CHECK ((deleted_at IS NULL) = (deletion_operation_id IS NULL));
ALTER TABLE public.stage_activities
  ADD COLUMN deleted_at timestamptz,
  ADD COLUMN deletion_operation_id uuid REFERENCES public.schedule_deletion_events(operation_id) ON DELETE RESTRICT,
  ADD CONSTRAINT stage_activities_deletion_pair CHECK ((deleted_at IS NULL) = (deletion_operation_id IS NULL));

CREATE FUNCTION public.guard_schedule_deletion() RETURNS trigger
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
  IF TG_TABLE_NAME = 'discipline_stages' AND NOT EXISTS (
    SELECT 1 FROM public.product_disciplines AS d WHERE d.id = NEW.discipline_id
      AND d.workspace_id = NEW.workspace_id AND d.product_id = NEW.product_id
      AND d.deleted_at IS NULL
  ) THEN RAISE EXCEPTION 'Parent discipline is inactive.' USING ERRCODE = '23514'; END IF;
  IF TG_TABLE_NAME = 'stage_activities' AND NOT EXISTS (
    SELECT 1 FROM public.discipline_stages AS s WHERE s.id = NEW.stage_id
      AND s.workspace_id = NEW.workspace_id AND s.product_id = NEW.product_id
      AND s.discipline_id = NEW.discipline_id AND s.deleted_at IS NULL
  ) THEN RAISE EXCEPTION 'Parent stage is inactive.' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_schedule_deletion() FROM PUBLIC;
CREATE TRIGGER product_disciplines_deletion_guard BEFORE INSERT OR UPDATE OR DELETE
  ON public.product_disciplines FOR EACH ROW EXECUTE FUNCTION public.guard_schedule_deletion();
CREATE TRIGGER discipline_stages_deletion_guard BEFORE INSERT OR UPDATE OR DELETE
  ON public.discipline_stages FOR EACH ROW EXECUTE FUNCTION public.guard_schedule_deletion();
CREATE TRIGGER stage_activities_deletion_guard BEFORE INSERT OR UPDATE OR DELETE
  ON public.stage_activities FOR EACH ROW EXECUTE FUNCTION public.guard_schedule_deletion();

CREATE FUNCTION public.guard_schedule_deletion_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'Schedule deletion audit is immutable.' USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION public.guard_schedule_deletion_audit() FROM PUBLIC;
CREATE TRIGGER schedule_deletion_events_immutable BEFORE UPDATE OR DELETE
  ON public.schedule_deletion_events FOR EACH ROW EXECUTE FUNCTION public.guard_schedule_deletion_audit();

GRANT SELECT (id, workspace_id, product_id, deleted_at, version)
  ON public.product_disciplines TO jlproject_date_executor;
GRANT SELECT (id, workspace_id, product_id, discipline_id, deleted_at, version)
  ON public.discipline_stages TO jlproject_date_executor;
GRANT UPDATE (deleted_at, deletion_operation_id, version, updated_by, updated_at)
  ON public.product_disciplines TO jlproject_date_executor;
GRANT UPDATE (deleted_at, deletion_operation_id, version, updated_by, updated_at)
  ON public.discipline_stages TO jlproject_date_executor;
GRANT UPDATE (deleted_at, deletion_operation_id, version, updated_by, updated_at)
  ON public.stage_activities TO jlproject_date_executor;
GRANT SELECT ON public.schedule_deletion_events TO neondb_owner;
GRANT USAGE, CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
ALTER TABLE public.schedule_deletion_events OWNER TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

CREATE FUNCTION public.preview_schedule_deletion(
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
      JOIN public.discipline_stages AS s ON s.id = a.stage_id AND s.deleted_at IS NULL
      JOIN public.product_disciplines AS d ON d.id = a.discipline_id AND d.deleted_at IS NULL
    WHERE a.id = p_target_id AND a.workspace_id = p_workspace_id AND a.product_id = p_product_id
      AND a.deleted_at IS NULL
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
REVOKE ALL ON FUNCTION public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid) TO jlproject_worker;

CREATE FUNCTION public.delete_schedule_subtree(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid, p_operation_id uuid,
  p_kind text, p_target_id uuid, p_fingerprint text, p_reason text
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_preview jsonb; v_id uuid; v_count integer; v_expected integer;
BEGIN
  IF p_operation_id IS NULL OR p_reason IS NULL OR p_fingerprint IS NULL OR
     char_length(btrim(p_reason)) NOT BETWEEN 10 AND 2000 OR p_reason <> btrim(p_reason) OR
     p_fingerprint !~ '^[0-9a-f]{32}$' THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
  PERFORM 1 FROM public.workspace_memberships AS m
    WHERE m.workspace_id = p_workspace_id AND m.auth_user_id = p_actor_id
      AND m.active = true AND m.role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;
  PERFORM 1 FROM public.products AS p WHERE p.id = p_product_id
    AND p.workspace_id = p_workspace_id AND p.active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  -- Parent-to-child locks serialize subtree changes and prevent new FK children.
  FOR v_id IN SELECT d.id FROM public.product_disciplines AS d
    WHERE d.workspace_id = p_workspace_id AND d.product_id = p_product_id
      AND (d.id = p_target_id AND p_kind = 'discipline' OR
           d.id = (SELECT s.discipline_id FROM public.discipline_stages AS s WHERE s.id = p_target_id)
             AND p_kind = 'stage' OR
           d.id = (SELECT a.discipline_id FROM public.stage_activities AS a WHERE a.id = p_target_id)
             AND p_kind = 'activity')
    ORDER BY d.id FOR UPDATE LOOP NULL; END LOOP;
  FOR v_id IN SELECT s.id FROM public.discipline_stages AS s
    WHERE s.workspace_id = p_workspace_id AND s.product_id = p_product_id
      AND ((p_kind = 'discipline' AND s.discipline_id = p_target_id) OR
           (p_kind = 'stage' AND s.id = p_target_id) OR
           (p_kind = 'activity' AND s.id = (SELECT a.stage_id FROM public.stage_activities AS a
             WHERE a.id = p_target_id)))
    ORDER BY s.id FOR UPDATE LOOP NULL; END LOOP;
  FOR v_id IN SELECT a.id FROM public.stage_activities AS a
    WHERE a.workspace_id = p_workspace_id AND a.product_id = p_product_id
      AND ((p_kind = 'discipline' AND a.discipline_id = p_target_id) OR
           (p_kind = 'stage' AND a.stage_id = p_target_id) OR
           (p_kind = 'activity' AND a.id = p_target_id))
    ORDER BY a.id FOR UPDATE LOOP NULL; END LOOP;
  v_preview := public.preview_schedule_deletion(p_workspace_id,p_product_id,p_actor_id,p_kind,p_target_id);
  IF v_preview->>'status' <> 'ok' THEN RETURN jsonb_build_object('status', v_preview->>'status'); END IF;
  IF v_preview->>'fingerprint' <> p_fingerprint THEN RETURN jsonb_build_object('status', 'stale'); END IF;
  INSERT INTO public.schedule_deletion_events
    (operation_id, workspace_id, product_id, target_kind, target_id, actor_id, reason, affected_items)
    VALUES (p_operation_id, p_workspace_id, p_product_id, p_kind, p_target_id, p_actor_id,
      p_reason, v_preview->'items');
  UPDATE public.stage_activities AS a SET deleted_at = now(), deletion_operation_id = p_operation_id,
    version = a.version + 1, updated_by = p_actor_id, updated_at = now()
    WHERE a.workspace_id = p_workspace_id AND a.product_id = p_product_id AND a.deleted_at IS NULL
      AND a.id IN (SELECT (i->>'id')::uuid FROM jsonb_array_elements(v_preview->'items') AS i
        WHERE i->>'kind' = 'activity');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_expected := (v_preview->'counts'->>'activities')::integer;
  IF v_count <> v_expected THEN RAISE EXCEPTION 'Subtree changed during deletion.' USING ERRCODE = '40001'; END IF;
  UPDATE public.discipline_stages AS s SET deleted_at = now(), deletion_operation_id = p_operation_id,
    version = s.version + 1, updated_by = p_actor_id, updated_at = now()
    WHERE s.workspace_id = p_workspace_id AND s.product_id = p_product_id AND s.deleted_at IS NULL
      AND s.id IN (SELECT (i->>'id')::uuid FROM jsonb_array_elements(v_preview->'items') AS i
        WHERE i->>'kind' = 'stage');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_expected := (v_preview->'counts'->>'stages')::integer;
  IF v_count <> v_expected THEN RAISE EXCEPTION 'Subtree changed during deletion.' USING ERRCODE = '40001'; END IF;
  UPDATE public.product_disciplines AS d SET deleted_at = now(), deletion_operation_id = p_operation_id,
    version = d.version + 1, updated_by = p_actor_id, updated_at = now()
    WHERE d.workspace_id = p_workspace_id AND d.product_id = p_product_id AND d.deleted_at IS NULL
      AND d.id IN (SELECT (i->>'id')::uuid FROM jsonb_array_elements(v_preview->'items') AS i
        WHERE i->>'kind' = 'discipline');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_expected := (v_preview->'counts'->>'disciplines')::integer;
  IF v_count <> v_expected THEN RAISE EXCEPTION 'Subtree changed during deletion.' USING ERRCODE = '40001'; END IF;
  RETURN jsonb_build_object('status', 'deleted', 'operationId', p_operation_id,
    'counts', v_preview->'counts');
END;
$$;
REVOKE ALL ON FUNCTION public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text) TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

-- Clone only surviving hierarchy rows; retain the existing independent R00 behavior.
CREATE OR REPLACE FUNCTION public.clone_product(
  p_workspace_id uuid,
  p_source_product_id uuid,
  p_actor_id uuid,
  p_name text
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
  v_target record;
  v_discipline_id uuid;
  v_stage_id uuid;
  v_activity_id uuid;
  v_target_id uuid;
  v_disciplines jsonb := '[]'::jsonb;
  v_stages jsonb;
  v_activities jsonb;
  v_targets jsonb := '[]'::jsonb;
  v_discipline_ids jsonb := '{}'::jsonb;
  v_snapshot jsonb;
BEGIN
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name <> btrim(p_name) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  -- Serialize clone attempts and keep membership checks stable for the operation.
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;

  SELECT product.* INTO v_source_product
    FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_source_product_id
      AND product.active = true
    FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
    VALUES (p_workspace_id, p_name, v_source_product.description, p_actor_id, p_actor_id)
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'duplicate'); END IF;

  FOR v_discipline IN
    SELECT discipline.* FROM public.product_disciplines AS discipline
    WHERE discipline.workspace_id = p_workspace_id AND discipline.product_id = p_source_product_id
      AND discipline.deleted_at IS NULL
    ORDER BY discipline.display_order, discipline.id FOR UPDATE
  LOOP
    INSERT INTO public.product_disciplines
      (workspace_id, product_id, name, short_code, color, display_order, description, created_by, updated_by)
    VALUES
      (p_workspace_id, v_product_id, v_discipline.name, v_discipline.short_code,
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
      VALUES
        (p_workspace_id, v_product_id, v_discipline_id, v_stage.definition_id,
         v_stage.display_name, v_stage.display_order, p_actor_id, p_actor_id)
      RETURNING id INTO v_stage_id;
      v_activities := '[]'::jsonb;

      FOR v_activity IN
        SELECT activity.* FROM public.stage_activities AS activity
        WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_source_product_id
          AND activity.discipline_id = v_discipline.id AND activity.stage_id = v_stage.id
          AND activity.deleted_at IS NULL
        ORDER BY activity.display_order, activity.id FOR UPDATE
      LOOP
        INSERT INTO public.stage_activities
          (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
           planned_start, planned_end, display_order, notes, created_by, updated_by)
        VALUES
          (p_workspace_id, v_product_id, v_discipline_id, v_stage_id, v_activity.name,
           v_activity.activity_type, v_activity.planned_start, v_activity.planned_end,
           v_activity.display_order, v_activity.notes, p_actor_id, p_actor_id)
        RETURNING id INTO v_activity_id;
        v_activities := v_activities || jsonb_build_array(jsonb_build_object(
          'id', v_activity_id, 'name', v_activity.name, 'activityType', v_activity.activity_type,
          'plannedStart', v_activity.planned_start, 'plannedEnd', v_activity.planned_end,
          'displayOrder', v_activity.display_order, 'notes', v_activity.notes));
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

  FOR v_target IN
    SELECT target.* FROM public.business_targets AS target
    WHERE target.workspace_id = p_workspace_id AND target.product_id = p_source_product_id
      AND target.deleted_at IS NULL
    ORDER BY target.display_order, target.id
  LOOP
    INSERT INTO public.business_targets
      (workspace_id, product_id, name, target_date, operational_date, display_order,
       created_by, description, color)
    VALUES
      (p_workspace_id, v_product_id, v_target.name, v_target.target_date,
       v_target.operational_date, v_target.display_order, p_actor_id,
       v_target.description, v_target.color)
    RETURNING id INTO v_target_id;
    v_targets := v_targets || jsonb_build_array(jsonb_build_object(
      'id', v_target_id, 'name', v_target.name, 'targetDate', v_target.target_date,
      'operationalDate', v_target.operational_date, 'displayOrder', v_target.display_order,
      'description', v_target.description, 'color', v_target.color));
  END LOOP;

  v_snapshot := jsonb_build_object(
    'product', jsonb_build_object('id', v_product_id, 'name', p_name),
    'disciplines', v_disciplines,
    'sourceMeta', '[]'::jsonb,
    'targets', v_targets,
    'actualStageColors', (
      SELECT COALESCE(jsonb_object_agg(lower(definition.code), definition.color), '{}'::jsonb)
      FROM public.discipline_stages AS stage
      JOIN public.stage_definitions AS definition
        ON definition.workspace_id = stage.workspace_id AND definition.id = stage.definition_id
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = v_product_id
    ),
    'disciplineIds', v_discipline_ids,
    'stageIds', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', stage.id, 'disciplineId', stage.discipline_id,
        'code', definition.code, 'displayName', stage.display_name)
        ORDER BY discipline.display_order, stage.display_order, stage.id), '[]'::jsonb)
      FROM public.discipline_stages AS stage
      JOIN public.product_disciplines AS discipline
        ON discipline.workspace_id = stage.workspace_id AND discipline.id = stage.discipline_id
      JOIN public.stage_definitions AS definition
        ON definition.workspace_id = stage.workspace_id AND definition.id = stage.definition_id
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = v_product_id
    ),
    'activityIds', '{}'::jsonb,
    'dependencies', '[]'::jsonb
  );

  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (p_workspace_id, v_product_id, NULL, v_snapshot, p_actor_id)
  RETURNING id INTO v_revision_id;

  RETURN jsonb_build_object(
    'status', 'cloned',
    'product', jsonb_build_object(
      'id', v_product_id, 'workspaceId', p_workspace_id, 'name', p_name,
      'description', v_source_product.description, 'active', true, 'version', 1,
      'createdAt', now(), 'updatedAt', now()),
    'revisionId', v_revision_id,
    'revisionLabel', 'R00');
END;
$$;

DO $$
BEGIN
  IF has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'deleted_at', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'deleted_at', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.product_disciplines', 'deleted_at', 'UPDATE') THEN
    RAISE EXCEPTION 'Schedule deletion privileges are not restricted.';
  END IF;
END;
$$;

COMMIT;
