BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin = true
      AND rolsuper = false AND rolcreaterole = false AND rolcreatedb = false
  ) THEN
    RAISE EXCEPTION 'Apply this migration using the reviewed JLProject database roles.';
  END IF;
END;
$$;
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
        AND stage.discipline_id = v_discipline.id
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

REVOKE ALL ON FUNCTION public.clone_product(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_product(uuid, uuid, uuid, text) TO jlproject_worker;

DO $$
BEGIN
  IF NOT has_function_privilege('jlproject_worker', 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_function_privilege('public', 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Clone function or immutable R00 privileges are not correctly configured.';
  END IF;
END;
$$;

COMMIT;