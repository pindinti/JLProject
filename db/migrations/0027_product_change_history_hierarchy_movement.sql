BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.hierarchy_movement_events') IS NULL OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.hierarchy_movement_events'::regclass) <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'DELETE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') OR
     position('public.hierarchy_movement_events' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'Product history movement integration prerequisites or privilege boundaries differ from the reviewed Development state.';
  END IF;
END;
$$;

-- Temporarily restore the reviewed executor DDL path within this transaction.
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;

DO $$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure);
  v_anchor constant text := '  ), eligible AS MATERIALIZED (';
  v_movement_event constant text := $movement$
    UNION ALL

    SELECT 'hierarchy-movement:' || movement.operation_id::text, movement.changed_at,
      movement.actor_id, 'hierarchy_moved',
      CASE movement.item_kind
        WHEN 'discipline' THEN jsonb_build_object('kind', 'discipline', 'id', movement.item_id::text,
          'name', item_discipline.name,
          'hierarchy', jsonb_build_object('discipline', item_discipline.name))
        WHEN 'stage' THEN jsonb_build_object('kind', 'stage', 'id', movement.item_id::text,
          'name', item_stage.display_name,
          'hierarchy', jsonb_build_object('discipline', new_discipline.name,
            'stage', item_stage.display_name))
        WHEN 'activity' THEN jsonb_build_object('kind', 'activity', 'id', movement.item_id::text,
          'name', item_activity.name,
          'hierarchy', CASE WHEN movement.new_stage_id IS NULL
            THEN jsonb_build_object('scope', 'product_root')
            ELSE jsonb_build_object('discipline', new_discipline.name, 'stage', new_stage.display_name) END)
      END,
      NULL::text,
      jsonb_build_object('parent', jsonb_build_object(
        'scope', CASE WHEN movement.item_kind = 'discipline' THEN 'product'
          WHEN movement.item_kind = 'stage' THEN 'discipline'
          WHEN movement.original_stage_id IS NULL THEN 'product_root' ELSE 'stage' END,
        'discipline', original_discipline.name,
        'stage', CASE WHEN movement.item_kind = 'stage' THEN NULL ELSE original_stage.display_name END),
        'position', movement.original_display_order + 1),
      jsonb_build_object('parent', jsonb_build_object(
        'scope', CASE WHEN movement.item_kind = 'discipline' THEN 'product'
          WHEN movement.item_kind = 'stage' THEN 'discipline'
          WHEN movement.new_stage_id IS NULL THEN 'product_root' ELSE 'stage' END,
        'discipline', new_discipline.name,
        'stage', CASE WHEN movement.item_kind = 'stage' THEN NULL ELSE new_stage.display_name END),
        'position', movement.new_display_order + 1),
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('kind', 'activity', 'id', activity.id::text,
          'name', activity.name, 'hierarchy', CASE WHEN activity.stage_id IS NULL
            THEN jsonb_build_object('scope', 'product_root')
            ELSE jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name) END)
          ORDER BY activity.name, activity.id)
        FROM jsonb_array_elements_text(movement.descendant_activity_ids) AS descendant(activity_id)
        JOIN public.stage_activities AS activity ON activity.workspace_id = movement.workspace_id
          AND activity.product_id = movement.product_id AND activity.id = descendant.activity_id::uuid
        LEFT JOIN public.discipline_stages AS stage ON stage.workspace_id = activity.workspace_id
          AND stage.product_id = activity.product_id AND stage.id = activity.stage_id
        LEFT JOIN public.product_disciplines AS discipline ON discipline.workspace_id = activity.workspace_id
          AND discipline.product_id = activity.product_id AND discipline.id = activity.discipline_id
      ), '[]'::jsonb)
    FROM public.hierarchy_movement_events AS movement
    LEFT JOIN public.product_disciplines AS item_discipline ON movement.item_kind = 'discipline'
      AND item_discipline.workspace_id = movement.workspace_id AND item_discipline.product_id = movement.product_id
      AND item_discipline.id = movement.item_id
    LEFT JOIN public.discipline_stages AS item_stage ON movement.item_kind = 'stage'
      AND item_stage.workspace_id = movement.workspace_id AND item_stage.product_id = movement.product_id
      AND item_stage.id = movement.item_id
    LEFT JOIN public.stage_activities AS item_activity ON movement.item_kind = 'activity'
      AND item_activity.workspace_id = movement.workspace_id AND item_activity.product_id = movement.product_id
      AND item_activity.id = movement.item_id
    LEFT JOIN public.product_disciplines AS original_discipline
      ON original_discipline.workspace_id = movement.workspace_id
      AND original_discipline.product_id = movement.product_id
      AND original_discipline.id = movement.original_discipline_id
    LEFT JOIN public.discipline_stages AS original_stage
      ON original_stage.workspace_id = movement.workspace_id AND original_stage.product_id = movement.product_id
      AND original_stage.id = movement.original_stage_id
    LEFT JOIN public.product_disciplines AS new_discipline
      ON new_discipline.workspace_id = movement.workspace_id AND new_discipline.product_id = movement.product_id
      AND new_discipline.id = movement.new_discipline_id
    LEFT JOIN public.discipline_stages AS new_stage
      ON new_stage.workspace_id = movement.workspace_id AND new_stage.product_id = movement.product_id
      AND new_stage.id = movement.new_stage_id
    WHERE movement.workspace_id = p_workspace_id AND movement.product_id = p_product_id
$movement$;
  v_replaced text;
BEGIN
  IF position('public.hierarchy_movement_events' IN v_definition) > 0 OR
     position(v_anchor IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor) THEN
    RAISE EXCEPTION 'Product history function source differs from the reviewed migration 0022 definition.';
  END IF;

  v_replaced := replace(v_definition, v_anchor, v_movement_event || v_anchor);
  EXECUTE v_replaced;
END;
$$;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF position('public.hierarchy_movement_events' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'DELETE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') THEN
    RAISE EXCEPTION 'Product history movement integration postconditions or least-privilege boundaries are incorrect.';
  END IF;
END;
$$;

COMMIT;
