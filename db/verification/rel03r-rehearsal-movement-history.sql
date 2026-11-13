-- REL-03R: rollback-only consolidated movement history proof on the rehearsal branch.
-- Run as jlproject_worker after the operator verifies the exact branch ID.
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     (SELECT count(*) FROM public.products) IS DISTINCT FROM 5 OR
     (SELECT count(*) FROM public.product_disciplines) IS DISTINCT FROM 19 OR
     (SELECT count(*) FROM public.discipline_stages) IS DISTINCT FROM 40 OR
     (SELECT count(*) FROM public.stage_activities) IS DISTINCT FROM 73 OR
     (SELECT count(*) FROM public.activity_date_changes) IS DISTINCT FROM 3 OR
     (SELECT count(*) FROM public.initial_schedule_revisions) IS DISTINCT FROM 1 OR
     (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
       'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
       '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a)
         IS DISTINCT FROM '41276cac3ad96dcf6377af00f5b7e733' THEN
    RAISE EXCEPTION 'REL-03R rehearsal baseline differs; stop before synthetic writes.';
  END IF;
END;
$$;
SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
  E'\n' ORDER BY r.id), '')) AS rel03r_r00_fingerprint
  FROM public.initial_schedule_revisions AS r \gset
ROLLBACK;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '3min';
SET LOCAL idle_in_transaction_session_timeout = '5min';
DO $$
DECLARE
  v_product constant uuid := '7c000000-0000-4000-8000-000000000001';
  v_da constant uuid := '7c000000-0000-4000-8000-000000000002';
  v_db constant uuid := '7c000000-0000-4000-8000-000000000003';
  v_def_a1 constant uuid := '7c000000-0000-4000-8000-000000000004';
  v_def_a2 constant uuid := '7c000000-0000-4000-8000-000000000005';
  v_def_b1 constant uuid := '7c000000-0000-4000-8000-000000000006';
  v_a1 constant uuid := '7c000000-0000-4000-8000-000000000007';
  v_a2 constant uuid := '7c000000-0000-4000-8000-000000000008';
  v_b1 constant uuid := '7c000000-0000-4000-8000-000000000009';
  v_activity1 uuid;
  v_activity2 uuid;
  v_activity3 uuid;
  v_root uuid;
  v_workspace uuid;
  v_actor uuid;
  v_result jsonb;
  v_original_dates text;
  v_original_hierarchy text;
  v_original_r00 text;
  v_synthetic_dates text;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)',
       'EXECUTE') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'INSERT') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'UPDATE') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'DELETE') THEN
    RAISE EXCEPTION 'Worker identity or protected-ledger boundary differs.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products
      WHERE id = v_product OR name LIKE 'REL03Q synthetic %') OR
     EXISTS (SELECT 1 FROM public.product_disciplines
       WHERE short_code IN ('Q-A', 'Q-B')) OR
     EXISTS (SELECT 1 FROM public.stage_definitions
       WHERE code IN ('Q-A1', 'Q-A2', 'Q-B1')) THEN
    RAISE EXCEPTION 'REL-03Q fixture marker already exists.';
  END IF;
  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
    FROM public.workspace_memberships AS m
    WHERE m.active AND m.role = 'admin'
    ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'Active administrator is required.'; END IF;

  SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
    'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) INTO v_original_dates
    FROM public.stage_activities AS a;
  SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), ''))
    INTO v_original_hierarchy FROM (
      SELECT 'd' AS kind, d.id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d
      UNION ALL SELECT 's', s.id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
      UNION ALL SELECT 'a', a.id::text, to_jsonb(a)::text FROM public.stage_activities AS a
    ) AS rows;
  SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
    E'\n' ORDER BY r.id), '')) INTO v_original_r00
    FROM public.initial_schedule_revisions AS r;
  IF v_original_dates IS DISTINCT FROM '41276cac3ad96dcf6377af00f5b7e733' THEN
    RAISE EXCEPTION 'Original activity date baseline differs.';
  END IF;

  INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
    VALUES (v_product, v_workspace, 'REL03Q synthetic audit proof', v_actor, v_actor);
  INSERT INTO public.product_disciplines
    (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES
    (v_da, v_workspace, v_product, 'Synthetic discipline A', 'Q-A', '#112233', 0, v_actor, v_actor),
    (v_db, v_workspace, v_product, 'Synthetic discipline B', 'Q-B', '#223344', 1, v_actor, v_actor);
  INSERT INTO public.stage_definitions (id, workspace_id, code, color) VALUES
    (v_def_a1, v_workspace, 'Q-A1', '#334455'),
    (v_def_a2, v_workspace, 'Q-A2', '#445566'),
    (v_def_b1, v_workspace, 'Q-B1', '#556677');
  INSERT INTO public.discipline_stages
    (id, workspace_id, product_id, discipline_id, definition_id,
     display_name, display_order, created_by, updated_by)
  VALUES
    (v_a1, v_workspace, v_product, v_da, v_def_a1, 'Synthetic stage A1', 0, v_actor, v_actor),
    (v_a2, v_workspace, v_product, v_da, v_def_a2, 'Synthetic stage A2', 1, v_actor, v_actor),
    (v_b1, v_workspace, v_product, v_db, v_def_b1, 'Synthetic stage B1', 0, v_actor, v_actor);
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_da, v_a1, 'Synthetic activity 1',
    DATE '2031-01-06', DATE '2031-01-07', 0, v_actor, v_actor)
  RETURNING id INTO v_activity1;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_da, v_a1, 'Synthetic activity 2',
    DATE '2031-01-08', DATE '2031-01-09', 1, v_actor, v_actor)
  RETURNING id INTO v_activity2;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_da, v_a2, 'Synthetic activity 3',
    DATE '2031-01-10', DATE '2031-01-11', 0, v_actor, v_actor)
  RETURNING id INTO v_activity3;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name,
     planned_start, planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, NULL, NULL, 'Synthetic root activity',
    DATE '2031-01-12', DATE '2031-01-13', 0, v_actor, v_actor)
  RETURNING id INTO v_root;
  SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
    'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) INTO v_synthetic_dates
    FROM public.stage_activities AS a WHERE a.product_id = v_product;

  -- Stage A1 to A2: [1,2] -> [1], [3] -> [3,2].
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7c000000-0000-4000-8000-000000000101', 'activity', v_activity2, 1,
    v_da, v_a2, 1,
    jsonb_build_array(v_activity1::text, v_activity2::text),
    jsonb_build_array(v_activity3::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (v_result->>'version')::bigint IS DISTINCT FROM 2 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE id = v_activity2 AND discipline_id = v_da AND stage_id = v_a2
         AND display_order = 1 AND version = 2) THEN
    RAISE EXCEPTION 'Stage-to-stage activity movement failed.';
  END IF;

  -- Stage A2 to product root: [3,2] -> [3], [root] -> [root,2].
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7c000000-0000-4000-8000-000000000102', 'activity', v_activity2, 2,
    NULL, NULL, 1,
    jsonb_build_array(v_activity3::text, v_activity2::text),
    jsonb_build_array(v_root::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (v_result->>'version')::bigint IS DISTINCT FROM 3 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE id = v_activity2 AND discipline_id IS NULL AND stage_id IS NULL
         AND display_order = 1 AND version = 3) THEN
    RAISE EXCEPTION 'Stage-to-root activity movement failed.';
  END IF;

  -- Product root to stage A2: [root,2] -> [root], [3] -> [3,2].
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7c000000-0000-4000-8000-000000000103', 'activity', v_activity2, 3,
    v_da, v_a2, 1,
    jsonb_build_array(v_root::text, v_activity2::text),
    jsonb_build_array(v_activity3::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (v_result->>'version')::bigint IS DISTINCT FROM 4 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE id = v_activity2 AND discipline_id = v_da AND stage_id = v_a2
         AND display_order = 1 AND version = 4) THEN
    RAISE EXCEPTION 'Root-to-stage activity movement failed.';
  END IF;

  -- Stage A2 to discipline B; descendants 2 and 3 must follow.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7c000000-0000-4000-8000-000000000104', 'stage', v_a2, 1,
    v_db, NULL, 1,
    jsonb_build_array(v_a1::text, v_a2::text),
    jsonb_build_array(v_b1::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (v_result->>'version')::bigint IS DISTINCT FROM 2 OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE id = v_a2 AND discipline_id = v_db AND display_order = 1 AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE id = v_activity2 AND discipline_id = v_db AND stage_id = v_a2
         AND display_order = 1 AND version = 5) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE id = v_activity3 AND discipline_id = v_db AND stage_id = v_a2
         AND display_order = 0 AND version = 2) THEN
    RAISE EXCEPTION 'Stage movement or descendant ancestry failed.';
  END IF;
  SET CONSTRAINTS public.stage_activities_parent_fk IMMEDIATE;

  -- Discipline B before A, exercising the discipline event contract.
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor,
    '7c000000-0000-4000-8000-000000000105', 'discipline', v_db, 1,
    NULL, NULL, 0,
    jsonb_build_array(v_da::text, v_db::text),
    jsonb_build_array(v_da::text, v_db::text));
  IF v_result->>'status' IS DISTINCT FROM 'moved' OR
     (v_result->>'version')::bigint IS DISTINCT FROM 2 OR
     NOT EXISTS (SELECT 1 FROM public.product_disciplines
       WHERE id = v_db AND display_order = 0 AND version = 2) THEN
    RAISE EXCEPTION 'Discipline movement failed.';
  END IF;

  IF (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
      'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
      '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a
      WHERE a.product_id = v_product) IS DISTINCT FROM v_synthetic_dates OR
     (SELECT count(*) FROM public.activity_date_changes
       WHERE product_id = v_product) IS DISTINCT FROM 0 OR
     (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
      'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
      '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a
      WHERE a.product_id <> v_product) IS DISTINCT FROM v_original_dates OR
     (SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
      E'\n' ORDER BY r.id), '')) FROM public.initial_schedule_revisions AS r)
       IS DISTINCT FROM v_original_r00 OR
     (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
       SELECT 'd' AS kind, d.id::text AS id, to_jsonb(d)::text AS row_data
         FROM public.product_disciplines AS d WHERE d.product_id <> v_product
       UNION ALL SELECT 's', s.id::text, to_jsonb(s)::text
         FROM public.discipline_stages AS s WHERE s.product_id <> v_product
       UNION ALL SELECT 'a', a.id::text, to_jsonb(a)::text
         FROM public.stage_activities AS a WHERE a.product_id <> v_product
     ) AS rows) IS DISTINCT FROM v_original_hierarchy THEN
    RAISE EXCEPTION 'Dates, original hierarchy, R00, or date-audit count changed.';
  END IF;
  RAISE NOTICE 'REL-03R five synthetic movements and preservation checks passed.';
END;
$$;

-- A separate top-level statement is essential: the STABLE reader must see the
-- movement writes as already completed statements in this transaction.
DO $$
DECLARE
  v_product constant uuid := '7c000000-0000-4000-8000-000000000001';
  v_da constant uuid := '7c000000-0000-4000-8000-000000000002';
  v_db constant uuid := '7c000000-0000-4000-8000-000000000003';
  v_a1 constant uuid := '7c000000-0000-4000-8000-000000000007';
  v_a2 constant uuid := '7c000000-0000-4000-8000-000000000008';
  v_b1 constant uuid := '7c000000-0000-4000-8000-000000000009';
  v_workspace uuid;
  v_actor uuid;
  v_activity1 uuid;
  v_activity2 uuid;
  v_activity3 uuid;
  v_root uuid;
  v_page jsonb;
  v_events jsonb := '[]'::jsonb;
  v_cursor jsonb;
  v_cursor_at timestamptz;
  v_cursor_id text;
  v_event jsonb;
  v_expected jsonb;
  v_previous_at timestamptz;
  v_previous_id text;
  v_at timestamptz;
  v_id text;
  v_pages integer := 0;
  v_index integer;
  v_op uuid;
  v_wrong_workspace uuid;
  v_other_product uuid;
BEGIN
  SELECT workspace_id, created_by INTO STRICT v_workspace, v_actor
    FROM public.products WHERE id = v_product;
  SELECT id INTO STRICT v_activity1 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 1';
  SELECT id INTO STRICT v_activity2 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 2';
  SELECT id INTO STRICT v_activity3 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 3';
  SELECT id INTO STRICT v_root FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic root activity';

  IF NOT has_function_privilege(current_user,
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') OR
     has_any_column_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       IS DISTINCT FROM 'jlproject_date_executor' OR
     COALESCE((SELECT NOT prosecdef OR provolatile <> 's' OR
       proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']::text[]
       FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure), true) THEN
    RAISE EXCEPTION 'History function or protected ledger privilege boundary differs.';
  END IF;
  BEGIN
    PERFORM 1 FROM public.hierarchy_movement_events LIMIT 1;
    RAISE EXCEPTION 'Direct Worker ledger SELECT unexpectedly succeeded.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  LOOP
    v_page := public.list_product_change_history(v_workspace, v_product, v_actor,
      2, v_cursor_at, v_cursor_id);
    IF v_page->>'status' IS DISTINCT FROM 'ok' OR
       jsonb_typeof(v_page->'events') IS DISTINCT FROM 'array' OR
       jsonb_array_length(v_page->'events') NOT BETWEEN 1 AND 2 THEN
      RAISE EXCEPTION 'History page contract differs.';
    END IF;
    v_events := v_events || (v_page->'events');
    v_cursor := v_page->'nextCursor';
    v_pages := v_pages + 1;
    IF v_pages > 3 THEN RAISE EXCEPTION 'History pagination did not terminate.'; END IF;
    EXIT WHEN v_cursor = 'null'::jsonb;
    IF jsonb_typeof(v_cursor) IS DISTINCT FROM 'object' OR
       v_cursor->>'occurredAt' IS DISTINCT FROM
         v_page->'events'->(jsonb_array_length(v_page->'events') - 1)->>'occurredAt' OR
       v_cursor->>'eventId' IS DISTINCT FROM
         v_page->'events'->(jsonb_array_length(v_page->'events') - 1)->>'id' THEN
      RAISE EXCEPTION 'History cursor does not identify the page boundary.';
    END IF;
    v_cursor_at := (v_cursor->>'occurredAt')::timestamptz;
    v_cursor_id := v_cursor->>'eventId';
  END LOOP;

  IF v_pages IS DISTINCT FROM 3 OR jsonb_array_length(v_events) IS DISTINCT FROM 6 OR
     (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(v_events)) IS DISTINCT FROM 6 OR
     (SELECT count(*) FROM jsonb_array_elements(v_events)
       WHERE value->>'eventType' = 'hierarchy_moved') IS DISTINCT FROM 5 OR
     (SELECT count(*) FROM jsonb_array_elements(v_events)
       WHERE value->>'eventType' = 'product_created') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Consolidated history has missing, duplicate or unexpected event types.';
  END IF;
  FOR v_index IN 0..5 LOOP
    v_event := v_events->v_index;
    v_at := (v_event->>'occurredAt')::timestamptz;
    v_id := v_event->>'id';
    IF v_at IS NULL OR v_id IS NULL OR
       (v_previous_at IS NOT NULL AND
         (v_previous_at, v_previous_id COLLATE "C") <= (v_at, v_id COLLATE "C")) THEN
      RAISE EXCEPTION 'History order or tie-breaking differs.';
    END IF;
    v_previous_at := v_at;
    v_previous_id := v_id;
  END LOOP;

  FOR v_index IN 1..5 LOOP
    v_op := ('7c000000-0000-4000-8000-' || lpad((100 + v_index)::text, 12, '0'))::uuid;
    SELECT value INTO STRICT v_event FROM jsonb_array_elements(v_events) AS item(value)
      WHERE value->>'id' = 'hierarchy-movement:' || v_op::text;
    IF v_event->>'eventType' IS DISTINCT FROM 'hierarchy_moved' OR
       v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
       v_event->'actorName' IS DISTINCT FROM 'null'::jsonb OR
       v_event->'justification' IS DISTINCT FROM 'null'::jsonb OR
       v_event->>'occurredAt' IS NULL OR
       v_event->>'occurredAt' !~
         '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$' THEN
      RAISE EXCEPTION 'Movement common payload differs for operation %.', v_op;
    END IF;
    IF v_index = 1 THEN
      v_expected := jsonb_build_object('kind','activity','id',v_activity2::text,
        'name','Synthetic activity 2','hierarchy',jsonb_build_object(
          'discipline','Synthetic discipline A','stage','Synthetic stage A2'));
      IF v_event->'item' IS DISTINCT FROM v_expected OR
         v_event->'before' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','stage','discipline','Synthetic discipline A','stage','Synthetic stage A1'),
           'position',2) OR
         v_event->'after' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','stage','discipline','Synthetic discipline A','stage','Synthetic stage A2'),
           'position',2) OR v_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'Stage-to-stage history payload differs.';
      END IF;
    ELSIF v_index = 2 THEN
      IF v_event->'item' IS DISTINCT FROM jsonb_build_object('kind','activity',
           'id',v_activity2::text,'name','Synthetic activity 2','hierarchy',
           jsonb_build_object('scope','product_root')) OR
         v_event->'before' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','stage','discipline','Synthetic discipline A','stage','Synthetic stage A2'),
           'position',2) OR
         v_event->'after' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','product_root','discipline',NULL,'stage',NULL),'position',2) OR
         v_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'Stage-to-root history payload differs.';
      END IF;
    ELSIF v_index = 3 THEN
      IF v_event->'item' IS DISTINCT FROM v_expected OR
         v_event->'before' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','product_root','discipline',NULL,'stage',NULL),'position',2) OR
         v_event->'after' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','stage','discipline','Synthetic discipline A','stage','Synthetic stage A2'),
           'position',2) OR v_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'Root-to-stage history payload differs.';
      END IF;
    ELSIF v_index = 4 THEN
      IF v_event->'item' IS DISTINCT FROM jsonb_build_object('kind','stage','id',v_a2::text,
           'name','Synthetic stage A2','hierarchy',jsonb_build_object(
             'discipline','Synthetic discipline B','stage','Synthetic stage A2')) OR
         v_event->'before' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','discipline','discipline','Synthetic discipline A','stage',NULL),'position',2) OR
         v_event->'after' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','discipline','discipline','Synthetic discipline B','stage',NULL),'position',2) OR
         v_event->'affectedItems' IS DISTINCT FROM jsonb_build_array(
           jsonb_build_object('kind','activity','id',v_activity2::text,
             'name','Synthetic activity 2','hierarchy',jsonb_build_object(
               'discipline','Synthetic discipline B','stage','Synthetic stage A2')),
           jsonb_build_object('kind','activity','id',v_activity3::text,
             'name','Synthetic activity 3','hierarchy',jsonb_build_object(
               'discipline','Synthetic discipline B','stage','Synthetic stage A2'))) THEN
        RAISE EXCEPTION 'Stage movement or descendant payload differs.';
      END IF;
    ELSE
      IF v_event->'item' IS DISTINCT FROM jsonb_build_object('kind','discipline',
           'id',v_db::text,'name','Synthetic discipline B','hierarchy',
           jsonb_build_object('discipline','Synthetic discipline B')) OR
         v_event->'before' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','product','discipline',NULL,'stage',NULL),'position',2) OR
         v_event->'after' IS DISTINCT FROM jsonb_build_object('parent',jsonb_build_object(
           'scope','product','discipline',NULL,'stage',NULL),'position',1) OR
         v_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'Discipline movement payload differs.';
      END IF;
    END IF;
  END LOOP;
  SELECT value INTO STRICT v_event FROM jsonb_array_elements(v_events) AS item(value)
    WHERE value->>'eventType' = 'product_created';
  IF v_event->>'id' IS DISTINCT FROM 'product:' || v_product::text OR
     v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_event->'item' IS DISTINCT FROM jsonb_build_object('kind','product',
       'id',v_product::text,'name','REL03Q synthetic audit proof') THEN
    RAISE EXCEPTION 'Existing product-created event type did not consolidate.';
  END IF;

  IF public.list_product_change_history(v_workspace, v_product,
       '00000000-0000-4000-8000-000000000099', 2, NULL, NULL)->>'status'
       IS DISTINCT FROM 'forbidden' OR
     public.list_product_change_history(v_workspace,
       '7c000000-0000-4000-8000-000000000099', v_actor, 2, NULL, NULL)->>'status'
       IS DISTINCT FROM 'not_found' OR
     public.list_product_change_history(v_workspace, v_product, v_actor,
       2, NULL, 'hierarchy-movement:7c000000-0000-4000-8000-000000000101')->>'status'
       IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'History authorization, product isolation or cursor validation differs.';
  END IF;
  SELECT w.id INTO v_wrong_workspace FROM public.workspaces AS w
    WHERE w.id <> v_workspace AND NOT EXISTS (
      SELECT 1 FROM public.workspace_memberships AS m
      WHERE m.workspace_id = w.id AND m.auth_user_id = v_actor AND m.active)
    ORDER BY w.id LIMIT 1;
  v_wrong_workspace := COALESCE(v_wrong_workspace,
    '7c000000-0000-4000-8000-000000000099'::uuid);
  IF public.list_product_change_history(v_wrong_workspace, v_product, v_actor,
       2, NULL, NULL)->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Cross-workspace history request was not rejected.';
  END IF;
  SELECT id INTO v_other_product FROM public.products
    WHERE workspace_id = v_workspace AND id <> v_product ORDER BY id LIMIT 1;
  IF v_other_product IS NOT NULL THEN
    v_page := public.list_product_change_history(v_workspace, v_other_product,
      v_actor, 10, NULL, NULL);
    IF v_page->>'status' IS DISTINCT FROM 'ok' OR
       EXISTS (SELECT 1 FROM jsonb_array_elements(v_page->'events') AS e(value)
         WHERE e.value->>'id' LIKE 'hierarchy-movement:7c000000-0000-4000-8000-%') THEN
      RAISE EXCEPTION 'Movement event leaked into another product history.';
    END IF;
  END IF;
  RAISE NOTICE 'REL-03R six consolidated events, payloads, pagination, isolation and grants passed.';
END;
$$;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';
DO $$
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     EXISTS (SELECT 1 FROM public.products
       WHERE id = '7c000000-0000-4000-8000-000000000001'::uuid) OR
     (SELECT count(*) FROM public.products) IS DISTINCT FROM 5 OR
     (SELECT count(*) FROM public.product_disciplines) IS DISTINCT FROM 19 OR
     (SELECT count(*) FROM public.discipline_stages) IS DISTINCT FROM 40 OR
     (SELECT count(*) FROM public.stage_activities) IS DISTINCT FROM 73 OR
     (SELECT count(*) FROM public.activity_date_changes) IS DISTINCT FROM 3 OR
     (SELECT count(*) FROM public.initial_schedule_revisions) IS DISTINCT FROM 1 OR
     (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
       'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
       '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a)
         IS DISTINCT FROM '41276cac3ad96dcf6377af00f5b7e733' THEN
    RAISE EXCEPTION 'REL-03R rollback residue or original baseline mismatch.';
  END IF;
END;
$$;
SELECT 1 / CASE WHEN md5(COALESCE(string_agg(
  r.id::text || '|' || r.snapshot::text,
  E'\n' ORDER BY r.id), '')) = :'rel03r_r00_fingerprint'
  THEN 1 ELSE 0 END AS rel03r_r00_preserved
  FROM public.initial_schedule_revisions AS r;
ROLLBACK;
