-- REL-03Q: independent read-only audit proof after the Worker COMMIT.
-- Run as neondb_owner on the verified disposable child branch only.
-- Pass the four original fingerprints and source-row count from the child baseline.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT 1 / CASE WHEN current_database() = 'neondb' AND
  current_user = 'neondb_owner' AND
  has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') AND
  NOT has_function_privilege(current_user,
    'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)',
    'EXECUTE') THEN 1 ELSE 0 END AS owner_boundary_verified;

DO $$
DECLARE
  v_product constant uuid := '7c000000-0000-4000-8000-000000000001';
  v_da constant uuid := '7c000000-0000-4000-8000-000000000002';
  v_db constant uuid := '7c000000-0000-4000-8000-000000000003';
  v_a1 constant uuid := '7c000000-0000-4000-8000-000000000007';
  v_a2 constant uuid := '7c000000-0000-4000-8000-000000000008';
  v_b1 constant uuid := '7c000000-0000-4000-8000-000000000009';
  v_activity1 uuid;
  v_activity2 uuid;
  v_activity3 uuid;
  v_root uuid;
  v_workspace uuid;
  v_actor uuid;
  v_created_at timestamptz;
  v_mismatches bigint;
BEGIN
  SELECT workspace_id, created_by, created_at
    INTO v_workspace, v_actor, v_created_at
    FROM public.products WHERE id = v_product
      AND name = 'REL03Q synthetic audit proof';
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships
    WHERE workspace_id = v_workspace AND auth_user_id = v_actor
      AND active AND role = 'admin') THEN
    RAISE EXCEPTION 'Synthetic product or authorized actor differs.';
  END IF;
  IF (SELECT count(*) FROM public.stage_activities WHERE product_id = v_product
      AND name IN ('Synthetic activity 1', 'Synthetic activity 2',
        'Synthetic activity 3', 'Synthetic root activity')) IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Synthetic activity fixture names differ.';
  END IF;
  SELECT id INTO v_activity1 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 1';
  SELECT id INTO v_activity2 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 2';
  SELECT id INTO v_activity3 FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic activity 3';
  SELECT id INTO v_root FROM public.stage_activities
    WHERE product_id = v_product AND name = 'Synthetic root activity';
  IF v_activity1 IS NULL OR v_activity2 IS NULL OR v_activity3 IS NULL OR v_root IS NULL OR
     (SELECT count(DISTINCT id) FROM public.stage_activities
       WHERE id IN (v_activity1, v_activity2, v_activity3, v_root)) IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Synthetic activity identity resolution failed.';
  END IF;
  WITH expected(op, kind, item, original_d, original_s, new_d, new_s,
      original_order, new_order, before_version, after_version,
      source_before, source_after, destination_before, destination_after, descendants) AS (
    VALUES
      ('7c000000-0000-4000-8000-000000000101'::uuid, 'activity', v_activity2,
        v_da, v_a1, v_da, v_a2, 1, 1, 1::bigint, 2::bigint,
        jsonb_build_array(v_activity1::text, v_activity2::text),
        jsonb_build_array(v_activity1::text),
        jsonb_build_array(v_activity3::text),
        jsonb_build_array(v_activity3::text, v_activity2::text), '[]'::jsonb),
      ('7c000000-0000-4000-8000-000000000102'::uuid, 'activity', v_activity2,
        v_da, v_a2, NULL::uuid, NULL::uuid, 1, 1, 2::bigint, 3::bigint,
        jsonb_build_array(v_activity3::text, v_activity2::text),
        jsonb_build_array(v_activity3::text),
        jsonb_build_array(v_root::text),
        jsonb_build_array(v_root::text, v_activity2::text), '[]'::jsonb),
      ('7c000000-0000-4000-8000-000000000103'::uuid, 'activity', v_activity2,
        NULL::uuid, NULL::uuid, v_da, v_a2, 1, 1, 3::bigint, 4::bigint,
        jsonb_build_array(v_root::text, v_activity2::text),
        jsonb_build_array(v_root::text),
        jsonb_build_array(v_activity3::text),
        jsonb_build_array(v_activity3::text, v_activity2::text), '[]'::jsonb),
      ('7c000000-0000-4000-8000-000000000104'::uuid, 'stage', v_a2,
        v_da, NULL::uuid, v_db, NULL::uuid, 1, 1, 1::bigint, 2::bigint,
        jsonb_build_array(v_a1::text, v_a2::text),
        jsonb_build_array(v_a1::text),
        jsonb_build_array(v_b1::text),
        jsonb_build_array(v_b1::text, v_a2::text),
        (SELECT jsonb_agg(id::text ORDER BY id) FROM public.stage_activities
          WHERE id IN (v_activity2, v_activity3)))
  )
  SELECT count(*) INTO v_mismatches FROM expected AS x
  FULL JOIN public.hierarchy_movement_events AS e ON e.operation_id = x.op
  WHERE x.op IS NULL OR e.operation_id IS NULL OR
    ROW(e.workspace_id, e.product_id, e.actor_id, e.item_kind, e.item_id,
      e.original_discipline_id, e.original_stage_id,
      e.new_discipline_id, e.new_stage_id,
      e.original_display_order, e.new_display_order,
      e.version_before, e.version_after,
      e.source_order_before, e.source_order_after,
      e.destination_order_before, e.destination_order_after,
      e.descendant_activity_ids) IS DISTINCT FROM
    ROW(v_workspace, v_product, v_actor, x.kind, x.item,
      x.original_d, x.original_s, x.new_d, x.new_s,
      x.original_order, x.new_order, x.before_version, x.after_version,
      x.source_before, x.source_after,
      x.destination_before, x.destination_after, x.descendants) OR
    e.changed_at IS NULL OR e.changed_at < v_created_at OR
    e.changed_at > clock_timestamp();
  IF v_mismatches IS DISTINCT FROM 0 OR
     (SELECT count(*) FROM public.hierarchy_movement_events) IS DISTINCT FROM 4 OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.hierarchy_movement_events'::regclass
         AND tgname = 'hierarchy_movement_events_immutable'
         AND tgenabled = 'O' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Committed movement ledger content or immutability trigger differs.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE id = v_a2 AND workspace_id = v_workspace AND product_id = v_product
        AND discipline_id = v_db AND display_order = 1 AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_activity2 AND workspace_id = v_workspace AND product_id = v_product
        AND discipline_id = v_db AND stage_id = v_a2
        AND display_order = 1 AND version = 5
        AND planned_start = DATE '2031-01-08' AND planned_end = DATE '2031-01-09') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_activity3 AND workspace_id = v_workspace AND product_id = v_product
        AND discipline_id = v_db AND stage_id = v_a2
        AND display_order = 0 AND version = 2
        AND planned_start = DATE '2031-01-10' AND planned_end = DATE '2031-01-11') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_activity1 AND workspace_id = v_workspace AND product_id = v_product
        AND discipline_id = v_da AND stage_id = v_a1 AND version = 1
        AND planned_start = DATE '2031-01-06' AND planned_end = DATE '2031-01-07') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities
      WHERE id = v_root AND workspace_id = v_workspace AND product_id = v_product
        AND discipline_id IS NULL AND stage_id IS NULL AND version = 1
        AND planned_start = DATE '2031-01-12' AND planned_end = DATE '2031-01-13') THEN
    RAISE EXCEPTION 'Committed synthetic hierarchy or dates differ.';
  END IF;
  RAISE NOTICE 'REL-03Q four exact persisted movement events passed.';
END;
$$;

SELECT 1 / CASE WHEN
  (SELECT count(*) FROM public.products) = 6 AND
  (SELECT count(*) FROM public.product_disciplines) = 21 AND
  (SELECT count(*) FROM public.discipline_stages) = 43 AND
  (SELECT count(*) FROM public.stage_activities) = 77 AND
  (SELECT count(*) FROM public.activity_date_changes) = 3 AND
  (SELECT count(*) FROM public.initial_schedule_revisions) = 1 AND
  (SELECT count(*) FROM public.import_source_rows) = :expected_source_rows AND
  (SELECT md5(COALESCE(string_agg(jsonb_build_object('id', a.id,
    'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a
    WHERE a.product_id <> '7c000000-0000-4000-8000-000000000001'::uuid)
      = :'expected_dates' AND
  (SELECT md5(COALESCE(string_agg(row_data, '|' ORDER BY kind, id), '')) FROM (
    SELECT 'd' AS kind, d.id::text AS id, to_jsonb(d)::text AS row_data
      FROM public.product_disciplines AS d
      WHERE d.product_id <> '7c000000-0000-4000-8000-000000000001'::uuid
    UNION ALL SELECT 's', s.id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
      WHERE s.product_id <> '7c000000-0000-4000-8000-000000000001'::uuid
    UNION ALL SELECT 'a', a.id::text, to_jsonb(a)::text FROM public.stage_activities AS a
      WHERE a.product_id <> '7c000000-0000-4000-8000-000000000001'::uuid
  ) AS rows) = :'expected_hierarchy' AND
  (SELECT md5(COALESCE(string_agg(r.id::text || '|' || r.snapshot::text,
    E'\n' ORDER BY r.id), '')) FROM public.initial_schedule_revisions AS r)
      = :'expected_r00' AND
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text,
    '|' ORDER BY t.id::text), '')) FROM public.business_targets AS t)
      = :'expected_targets'
  THEN 1 ELSE 0 END AS original_data_preserved;
SELECT has_table_privilege(current_user, 'public.hierarchy_movement_events', 'UPDATE')
  AS owner_can_attempt_ledger_update;
ROLLBACK;
