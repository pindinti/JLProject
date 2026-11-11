-- Rollback-only verification for migration 0027 on verified Development.
-- It checks existing rows only and creates no schedule or audit data.
BEGIN;

DO $$
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     position('public.hierarchy_movement_events' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.hierarchy_movement_events'::regclass) <> 'jlproject_date_executor' OR
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
       NOT membership.inherit_option AND NOT membership.set_option AND grantor.rolname = 'cloud_admin')
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       JOIN pg_roles AS grantor ON grantor.oid = membership.grantor
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') THEN
    RAISE EXCEPTION 'Migration 0027 owner, scope, or Worker privilege postconditions failed.';
  END IF;
END;
$$;

-- Temporarily obtain the existing function owner within this transaction.
GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;

DO $$
DECLARE
  v_scope record;
  v_movement record;
  v_workspace_actor uuid;
  v_events jsonb;
  v_page jsonb;
  v_cursor jsonb;
  v_event jsonb;
  v_expected_item jsonb;
  v_expected_before jsonb;
  v_expected_after jsonb;
  v_parent_discipline text;
  v_parent_stage text;
  v_cursor_at timestamptz;
  v_cursor_id text;
  v_page_count integer;
  v_expected_count bigint;
  v_returned_count bigint;
  v_distinct_count bigint;
  v_descendant_count integer;
  v_seen_descendant_count integer;
  v_total_events bigint := 0;
  v_total_scopes bigint := 0;
  v_isolation jsonb;
BEGIN
  IF current_user <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'History verification did not run as the controlled function owner.';
  END IF;

  FOR v_scope IN
    SELECT DISTINCT workspace_id, product_id FROM public.hierarchy_movement_events
    ORDER BY workspace_id, product_id
  LOOP
    SELECT membership.auth_user_id INTO v_workspace_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = v_scope.workspace_id AND membership.active = true
    ORDER BY CASE membership.role WHEN 'admin' THEN 0 WHEN 'editor' THEN 1 ELSE 2 END,
      membership.auth_user_id
    LIMIT 1;
    IF v_workspace_actor IS NULL THEN
      RAISE EXCEPTION 'No active workspace member is available for product history verification.';
    END IF;

    v_events := '[]'::jsonb;
    v_cursor_at := NULL;
    v_cursor_id := NULL;
    v_page_count := 0;
    LOOP
      v_page := public.list_product_change_history(v_scope.workspace_id, v_scope.product_id,
        v_workspace_actor, 2, v_cursor_at, v_cursor_id);
      IF v_page->>'status' <> 'ok' OR jsonb_typeof(v_page->'events') <> 'array' THEN
        RAISE EXCEPTION 'Product history denied or returned an invalid page for an active member.';
      END IF;
      v_events := v_events || (v_page->'events');
      v_cursor := v_page->'nextCursor';
      EXIT WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb;
      v_cursor_at := (v_cursor->>'occurredAt')::timestamptz;
      v_cursor_id := v_cursor->>'eventId';
      v_page_count := v_page_count + 1;
      IF v_page_count > 1000 THEN
        RAISE EXCEPTION 'Product history pagination did not terminate.';
      END IF;
    END LOOP;

    SELECT count(*), count(DISTINCT page_event.value->>'id')
      INTO v_returned_count, v_distinct_count
    FROM jsonb_array_elements(v_events) AS page_event(value)
    WHERE page_event.value->>'eventType' = 'hierarchy_moved';
    SELECT count(*) INTO v_expected_count FROM public.hierarchy_movement_events AS movement
    WHERE movement.workspace_id = v_scope.workspace_id AND movement.product_id = v_scope.product_id;
    IF v_returned_count <> v_expected_count OR v_distinct_count <> v_expected_count THEN
      RAISE EXCEPTION 'Product history movement rows are missing or duplicated.';
    END IF;

    FOR v_movement IN
      SELECT * FROM public.hierarchy_movement_events AS movement
      WHERE movement.workspace_id = v_scope.workspace_id AND movement.product_id = v_scope.product_id
      ORDER BY movement.changed_at, movement.operation_id
    LOOP
      SELECT page_event.value INTO v_event
      FROM jsonb_array_elements(v_events) AS page_event(value)
      WHERE page_event.value->>'id' = 'hierarchy-movement:' || v_movement.operation_id::text
        AND page_event.value->>'eventType' = 'hierarchy_moved';
      IF v_event IS NULL OR (v_event->>'actorId')::uuid <> v_movement.actor_id OR
         (v_event->>'occurredAt')::timestamptz <> v_movement.changed_at THEN
        RAISE EXCEPTION 'Movement history actor, timestamp, or unique event ID differs from its audit row.';
      END IF;

      v_expected_item := CASE v_movement.item_kind
        WHEN 'discipline' THEN (
          SELECT jsonb_build_object('kind', 'discipline', 'id', item.id::text,
            'name', item.name, 'hierarchy', jsonb_build_object('discipline', item.name))
          FROM public.product_disciplines AS item
          WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
            AND item.id = v_movement.item_id)
        WHEN 'stage' THEN (
          SELECT jsonb_build_object('kind', 'stage', 'id', item.id::text,
            'name', item.display_name, 'hierarchy', jsonb_build_object(
              'discipline', parent.name, 'stage', item.display_name))
          FROM public.discipline_stages AS item
          JOIN public.product_disciplines AS parent ON parent.workspace_id = item.workspace_id
            AND parent.product_id = item.product_id AND parent.id = v_movement.new_discipline_id
          WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
            AND item.id = v_movement.item_id)
        WHEN 'activity' THEN (
          SELECT jsonb_build_object('kind', 'activity', 'id', item.id::text, 'name', item.name,
            'hierarchy', CASE WHEN v_movement.new_stage_id IS NULL
              THEN jsonb_build_object('scope', 'product_root')
              ELSE jsonb_build_object('discipline', parent.name, 'stage', stage.display_name) END)
          FROM public.stage_activities AS item
          LEFT JOIN public.discipline_stages AS stage ON stage.workspace_id = item.workspace_id
            AND stage.product_id = item.product_id AND stage.id = v_movement.new_stage_id
          LEFT JOIN public.product_disciplines AS parent ON parent.workspace_id = item.workspace_id
            AND parent.product_id = item.product_id AND parent.id = v_movement.new_discipline_id
          WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
            AND item.id = v_movement.item_id)
      END;
      IF v_event->'item' IS DISTINCT FROM v_expected_item THEN
        RAISE EXCEPTION 'Movement history item type, name, or destination hierarchy differs from its audit row.';
      END IF;

      SELECT item.name INTO v_parent_discipline FROM public.product_disciplines AS item
      WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
        AND item.id = v_movement.original_discipline_id;
      SELECT item.display_name INTO v_parent_stage FROM public.discipline_stages AS item
      WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
        AND item.id = v_movement.original_stage_id;
      v_expected_before := jsonb_build_object('parent', jsonb_build_object(
        'scope', CASE WHEN v_movement.item_kind = 'discipline' THEN 'product'
          WHEN v_movement.item_kind = 'stage' THEN 'discipline'
          WHEN v_movement.original_stage_id IS NULL THEN 'product_root' ELSE 'stage' END,
        'discipline', v_parent_discipline,
        'stage', CASE WHEN v_movement.item_kind = 'stage' THEN NULL ELSE v_parent_stage END),
        'position', v_movement.original_display_order + 1);

      SELECT item.name INTO v_parent_discipline FROM public.product_disciplines AS item
      WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
        AND item.id = v_movement.new_discipline_id;
      SELECT item.display_name INTO v_parent_stage FROM public.discipline_stages AS item
      WHERE item.workspace_id = v_movement.workspace_id AND item.product_id = v_movement.product_id
        AND item.id = v_movement.new_stage_id;
      v_expected_after := jsonb_build_object('parent', jsonb_build_object(
        'scope', CASE WHEN v_movement.item_kind = 'discipline' THEN 'product'
          WHEN v_movement.item_kind = 'stage' THEN 'discipline'
          WHEN v_movement.new_stage_id IS NULL THEN 'product_root' ELSE 'stage' END,
        'discipline', v_parent_discipline,
        'stage', CASE WHEN v_movement.item_kind = 'stage' THEN NULL ELSE v_parent_stage END),
        'position', v_movement.new_display_order + 1);
      IF v_event->'before' IS DISTINCT FROM v_expected_before OR
         v_event->'after' IS DISTINCT FROM v_expected_after THEN
        RAISE EXCEPTION 'Movement history parent hierarchy or sibling position differs from its audit row.';
      END IF;

      IF v_movement.item_kind = 'stage' THEN
        v_descendant_count := jsonb_array_length(v_movement.descendant_activity_ids);
        SELECT count(*) INTO v_seen_descendant_count
        FROM jsonb_array_elements(v_event->'affectedItems') AS affected(item)
        WHERE affected.item->>'kind' = 'activity';
        IF v_seen_descendant_count <> v_descendant_count OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(v_movement.descendant_activity_ids) AS descendant(id)
          WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_event->'affectedItems') AS affected(item)
            WHERE affected.item->>'id' = descendant.id)) THEN
          RAISE EXCEPTION 'Stage movement history omitted an affected descendant activity.';
        END IF;
      ELSIF jsonb_array_length(v_event->'affectedItems') <> 0 THEN
        RAISE EXCEPTION 'A non-stage movement was split into additional affected-item events.';
      END IF;
      v_total_events := v_total_events + 1;
    END LOOP;
    v_total_scopes := v_total_scopes + 1;

    v_isolation := public.list_product_change_history(gen_random_uuid(), v_scope.product_id,
      v_workspace_actor, 10, NULL, NULL);
    IF v_isolation->>'status' <> 'forbidden' THEN
      RAISE EXCEPTION 'Product history was visible from an unrelated workspace.';
    END IF;
  END LOOP;

  RAISE NOTICE 'Verified % existing movement events across % product scopes with keyset pagination and workspace isolation.',
    v_total_events, v_total_scopes;
END;
$$;

RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option AND grantor.rolname = 'cloud_admin')
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       JOIN pg_roles AS grantor ON grantor.oid = membership.grantor
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') THEN
    RAISE EXCEPTION 'The history verification did not restore original privileges and membership.';
  END IF;
END;
$$;

ROLLBACK;
