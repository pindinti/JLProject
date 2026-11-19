BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.products'::regclass
       AND attname = 'planning_classification' AND NOT attisdropped) OR
     to_regprocedure('public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)') IS NULL OR
     to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NULL OR
     to_regprocedure('public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid)') IS NOT NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) <> 'neondb_owner' OR
     NOT (SELECT prosecdef FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) OR
     (SELECT prosecdef FROM pg_proc WHERE oid =
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure) OR
     (SELECT proconfig @> ARRAY['search_path=pg_catalog, pg_temp'] FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) IS NOT TRUE OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     NOT (SELECT count(*) = 1 AND count(*) FILTER (
         WHERE grantor = to_regrole('cloud_admin') AND admin_option
           AND NOT inherit_option AND NOT set_option) = 1
       FROM pg_catalog.pg_auth_members
       WHERE roleid = 'jlproject_date_executor'::regrole
         AND member = 'neondb_owner'::regrole) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.stage_activities', 'planning_mode', 'INSERT') THEN
    RAISE EXCEPTION 'Clone compatibility prerequisites differ from reviewed Development schema.';
  END IF;
END;
$$;

-- Keep the temporary grant separate from the existing cloud_admin grant.
GRANT jlproject_date_executor TO neondb_owner
  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

DO $$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure);
  v_anchor constant text := 'AND id = p_source_product_id AND active = true';
  v_target_anchor constant text := 'AND id = p_target_product_id AND active = true';
BEGIN
  IF length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor) OR
     length(v_definition) - length(replace(v_definition, v_target_anchor, '')) <> length(v_target_anchor) THEN
    RAISE EXCEPTION 'Root clone helper differs from reviewed definition.';
  END IF;
  v_definition := replace(v_definition, v_anchor, 'AND id = p_source_product_id');
  v_definition := replace(v_definition, v_target_anchor,
    'AND id = p_target_product_id AND active = true' || E'\n' ||
    '         AND created_by = p_actor_id AND xmin::text::bigint = txid_current() % 4294967296');
  EXECUTE v_definition;
END;
$$;

CREATE FUNCTION public.clone_stage_activity(
  p_workspace_id uuid, p_source_product_id uuid, p_target_product_id uuid,
  p_actor_id uuid, p_activity_id uuid, p_target_discipline_id uuid, p_target_stage_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_activity public.stage_activities%ROWTYPE;
  v_new_activity_id uuid;
BEGIN
  IF p_workspace_id IS NULL OR p_source_product_id IS NULL OR p_target_product_id IS NULL OR
     p_actor_id IS NULL OR p_activity_id IS NULL OR p_target_discipline_id IS NULL OR
     p_target_stage_id IS NULL OR p_source_product_id = p_target_product_id THEN
    RAISE EXCEPTION 'Invalid stage activity clone scope.' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = p_workspace_id) OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace_id
       AND auth_user_id = p_actor_id AND active = true AND role IN ('admin', 'editor')) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = p_workspace_id
       AND id = p_source_product_id) OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = p_workspace_id
       AND id = p_target_product_id AND active = true AND created_by = p_actor_id
       AND xmin::text::bigint = txid_current() % 4294967296) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages AS stage
       JOIN public.product_disciplines AS discipline ON discipline.id = stage.discipline_id
         AND discipline.workspace_id = stage.workspace_id
         AND discipline.product_id = stage.product_id AND discipline.deleted_at IS NULL
       WHERE stage.workspace_id = p_workspace_id AND stage.product_id = p_target_product_id
         AND stage.discipline_id = p_target_discipline_id
         AND stage.id = p_target_stage_id AND stage.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Stage activity clone scope is not authorized.' USING ERRCODE = '42501';
  END IF;
  SELECT activity.* INTO v_activity FROM public.stage_activities AS activity
    JOIN public.discipline_stages AS stage ON stage.id = activity.stage_id
      AND stage.workspace_id = activity.workspace_id AND stage.product_id = activity.product_id
      AND stage.deleted_at IS NULL
    JOIN public.product_disciplines AS discipline ON discipline.id = stage.discipline_id
      AND discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
      AND discipline.deleted_at IS NULL
    WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_source_product_id
      AND activity.id = p_activity_id AND activity.discipline_id = stage.discipline_id
      AND activity.deleted_at IS NULL FOR UPDATE OF activity;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source stage activity was not found.' USING ERRCODE = 'P0002'; END IF;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
     planned_start, planned_end, display_order, notes, color_override,
     planning_mode, working_day_duration, planning_calendar_version, created_by, updated_by)
  VALUES (p_workspace_id, p_target_product_id, p_target_discipline_id, p_target_stage_id,
    v_activity.name, v_activity.activity_type, v_activity.planned_start, v_activity.planned_end,
    v_activity.display_order, v_activity.notes, v_activity.color_override,
    v_activity.planning_mode, v_activity.working_day_duration,
    v_activity.planning_calendar_version, p_actor_id, p_actor_id)
  RETURNING id INTO v_new_activity_id;
  RETURN v_new_activity_id;
END;
$$;
REVOKE ALL ON FUNCTION public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid) TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
DECLARE
  v_definition text := pg_get_functiondef('public.clone_product(uuid,uuid,uuid,text)'::regprocedure);
  v_insert_anchor constant text := $anchor$
        INSERT INTO public.stage_activities
          (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
           planned_start, planned_end, display_order, notes, color_override, created_by, updated_by)
        VALUES (p_workspace_id, v_product_id, v_discipline_id, v_stage_id, v_activity.name,
          v_activity.activity_type, v_activity.planned_start, v_activity.planned_end,
          v_activity.display_order, v_activity.notes, v_activity.color_override, p_actor_id, p_actor_id)
        RETURNING id INTO v_activity_id;
$anchor$;
  v_insert_replacement constant text := $replacement$
        v_activity_id := public.clone_stage_activity(p_workspace_id, p_source_product_id,
          v_product_id, p_actor_id, v_activity.id, v_discipline_id, v_stage_id);
$replacement$;
  v_json_anchor constant text := $anchor$
          'colorOverride', v_activity.color_override));
$anchor$;
  v_json_replacement constant text := $replacement$
          'colorOverride', v_activity.color_override,
          'planningMode', v_activity.planning_mode,
          'workingDayDuration', v_activity.working_day_duration,
          'planningCalendarVersion', v_activity.planning_calendar_version));
$replacement$;
BEGIN
  IF length(v_definition) - length(replace(v_definition, v_insert_anchor, '')) <> length(v_insert_anchor) OR
     length(v_definition) - length(replace(v_definition, v_json_anchor, '')) <> length(v_json_anchor) OR
     position('''planningClassification'', ''em_estudo''' IN v_definition) = 0 OR
     position('public.change_discipline_stage_dates' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Product clone function differs from reviewed 0034 definition.';
  END IF;
  v_definition := replace(v_definition, v_insert_anchor, v_insert_replacement);
  v_definition := replace(v_definition, v_json_anchor, v_json_replacement);
  EXECUTE v_definition;
END;
$$;

DO $$
BEGIN
  IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid)'::regprocedure) <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     EXISTS (SELECT 1 FROM aclexplode((SELECT proacl FROM pg_proc WHERE oid =
       'public.clone_stage_activity(uuid,uuid,uuid,uuid,uuid,uuid,uuid)'::regprocedure))
       WHERE grantee = 0 AND privilege_type = 'EXECUTE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     NOT (SELECT count(*) = 1 AND count(*) FILTER (
         WHERE grantor = to_regrole('cloud_admin') AND admin_option
           AND NOT inherit_option AND NOT set_option) = 1
       FROM pg_catalog.pg_auth_members
       WHERE roleid = 'jlproject_date_executor'::regrole
         AND member = 'neondb_owner'::regrole) OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT') OR
     position('AND id = p_source_product_id AND active = true' IN pg_get_functiondef(
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'Clone compatibility privilege or function postcondition failed.';
  END IF;
END;
$$;

COMMIT;
