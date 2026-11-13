-- REL-03Q: committed synthetic movement proof, disposable child branch only.
-- Run as jlproject_worker after child baseline and branch-ID verification.
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
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
  RAISE NOTICE 'REL-03Q four synthetic movements and preservation checks passed.';
END;
$$;
COMMIT;
