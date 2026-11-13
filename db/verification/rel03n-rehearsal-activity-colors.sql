-- REL-03N: rollback-only activity colors and clone integration test.
-- Run as jlproject_worker on rehearsal branch br-snowy-wave-b6vn905p only.
\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'definitions', (SELECT count(*) FROM public.stage_definitions),
  'targets', (SELECT count(*) FROM public.business_targets),
  'import_batches', (SELECT count(*) FROM public.import_batches),
  'import_source_rows', (SELECT count(*) FROM public.import_source_rows),
  'colored', (SELECT count(*) FROM public.stage_activities WHERE color_override IS NOT NULL),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'target_audits', (SELECT count(*) FROM public.business_target_date_changes),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS baseline
\gset rel03n_
ROLLBACK;

SELECT 1 / CASE WHEN
  (:'rel03n_baseline'::jsonb->>'products')::bigint = 5 AND
  (:'rel03n_baseline'::jsonb->>'disciplines')::bigint = 19 AND
  (:'rel03n_baseline'::jsonb->>'stages')::bigint = 40 AND
  (:'rel03n_baseline'::jsonb->>'activities')::bigint = 73 AND
  (:'rel03n_baseline'::jsonb->>'colored')::bigint = 0 AND
  (:'rel03n_baseline'::jsonb->>'r00')::bigint = 1 AND
  (:'rel03n_baseline'::jsonb->>'dates') = '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS reported_baseline_matches;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $test$
DECLARE
  v_ws uuid;
  v_other_ws uuid;
  v_actor uuid;
  v_source uuid;
  v_clone uuid;
  v_source_r00 uuid;
  v_clone_r00 uuid;
  v_discipline uuid;
  v_stage uuid;
  v_definition uuid;
  v_a1 uuid;
  v_a2 uuid;
  v_a3 uuid;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_source_name text;
  v_clone_name text;
  v_result jsonb;
  v_source_before jsonb;
  v_source_after jsonb;
  v_source_rows jsonb;
  v_clone_rows jsonb;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_column_privilege(current_user, 'public.stage_activities',
       'color_override', 'INSERT') OR
     NOT has_column_privilege(current_user, 'public.stage_activities',
       'color_override', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'INSERT') OR
     has_table_privilege(current_user, 'public.stage_activities', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'DELETE') OR
     has_column_privilege(current_user, 'public.stage_activities',
       'planned_start', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities',
       'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'REL-03N Worker grants or clone execution boundary differ.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc
      WHERE oid = 'public.clone_product(uuid,uuid,uuid,text)'::regprocedure
        AND pg_get_userbyid(proowner) = 'neondb_owner' AND NOT prosecdef) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.stage_activities'::regclass AND convalidated
        AND pg_get_constraintdef(oid) LIKE '%color_override%') THEN
    RAISE EXCEPTION 'REL-03N clone owner or color constraint differs.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
      AND c.relname IN ('products','product_disciplines','stage_definitions',
        'discipline_stages','stage_activities','initial_schedule_revisions')
      AND ((t.tgtype & 4) <> 0 OR (t.tgtype & 16) <> 0 OR (t.tgtype & 8) <> 0)
      AND t.tgname NOT IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard','stage_activities_deletion_guard',
        'stage_activities_dates_immutable','initial_schedule_revisions_immutable')) THEN
    RAISE EXCEPTION 'Unreviewed write trigger could have external effects.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products
      WHERE name LIKE 'REL03N synthetic %') THEN
    RAISE EXCEPTION 'Existing REL-03N marker; inspect before testing.';
  END IF;
  SELECT m.workspace_id, m.auth_user_id INTO v_ws, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role IN ('admin','editor')
  ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_ws IS NULL THEN
    RAISE EXCEPTION 'REL-03N needs an existing active writer identity.';
  END IF;

  v_source_name := 'REL03N synthetic source ' || v_marker;
  v_clone_name := 'REL03N synthetic clone ' || v_marker;
  INSERT INTO public.products
    (workspace_id,name,description,created_by,updated_by)
  VALUES (v_ws,v_source_name,'Rollback-only color fixture',v_actor,v_actor)
  RETURNING id INTO v_source;
  INSERT INTO public.product_disciplines
    (workspace_id,product_id,name,short_code,color,display_order,created_by,updated_by)
  VALUES (v_ws,v_source,'REL03N discipline','R3N','#112233',2,v_actor,v_actor)
  RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id,code,color)
  VALUES (v_ws,'R3N' || left(v_marker,12),'#445566')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id,product_id,discipline_id,definition_id,display_name,
     display_order,created_by,updated_by)
  VALUES (v_ws,v_source,v_discipline,v_definition,'REL03N stage',3,v_actor,v_actor)
  RETURNING id INTO v_stage;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_source,v_discipline,v_stage,'REL03N activity one',
    DATE '2030-03-01',DATE '2030-03-02',0,v_actor,v_actor)
  RETURNING id INTO v_a1;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,color_override,created_by,updated_by)
  VALUES (v_ws,v_source,v_discipline,v_stage,'REL03N activity two',
    DATE '2030-03-03',DATE '2030-03-04',2,'#00ff88',v_actor,v_actor)
  RETURNING id INTO v_a2;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,color_override,created_by,updated_by)
  VALUES (v_ws,v_source,v_discipline,v_stage,'REL03N activity three',
    DATE '2030-03-05',DATE '2030-03-06',4,'#ABCDEF',v_actor,v_actor)
  RETURNING id INTO v_a3;
  INSERT INTO public.initial_schedule_revisions
    (workspace_id,product_id,import_batch_id,snapshot,created_by)
  VALUES (v_ws,v_source,NULL,
    jsonb_build_object('dependencies','[]'::jsonb,'synthetic',true),v_actor)
  RETURNING id INTO v_source_r00;

  UPDATE public.stage_activities SET color_override = '#A1B2C3' WHERE id = v_a1;
  UPDATE public.stage_activities SET color_override = NULL WHERE id = v_a3;
  BEGIN
    UPDATE public.stage_activities SET color_override = '#XYZ123' WHERE id = v_a1;
    RAISE EXCEPTION 'Invalid color UPDATE was accepted.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id,product_id,discipline_id,stage_id,name,display_order,
       color_override,created_by,updated_by)
    VALUES (v_ws,v_source,v_discipline,v_stage,'Invalid color insert',9,
      '#12345',v_actor,v_actor);
    RAISE EXCEPTION 'Invalid color INSERT was accepted.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  UPDATE public.stage_definitions SET color = '#778899' WHERE id = v_definition;
  IF (SELECT count(*) FROM public.stage_activities WHERE product_id = v_source) <> 3 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_a1
       AND color_override = '#A1B2C3') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_a2
       AND color_override = '#00ff88') OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS a
       JOIN public.discipline_stages AS s ON s.id = a.stage_id
       JOIN public.stage_definitions AS d ON d.id = s.definition_id
       WHERE a.id = v_a3 AND a.color_override IS NULL AND d.color = '#778899') THEN
    RAISE EXCEPTION 'Valid, invalid, or inherited color behavior differs.';
  END IF;
  RAISE NOTICE 'REL03N color constraint and inheritance PASS';

  SELECT jsonb_build_object(
    'product',(SELECT to_jsonb(p) FROM public.products AS p WHERE id = v_source),
    'activities',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id)
      FROM public.stage_activities AS a WHERE product_id = v_source),
    'r00',(SELECT to_jsonb(r) FROM public.initial_schedule_revisions AS r
      WHERE id = v_source_r00)) INTO v_source_before;

  v_result := public.clone_product(v_ws,v_source,gen_random_uuid(),
    'REL03N synthetic denied ' || v_marker);
  IF v_result->>'status' IS DISTINCT FROM 'denied' THEN
    RAISE EXCEPTION 'Unauthorized actor cloned the product.';
  END IF;
  v_result := public.clone_product(gen_random_uuid(),v_source,v_actor,
    'REL03N synthetic foreign ' || v_marker);
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unknown workspace clone scope was accepted.';
  END IF;
  SELECT id INTO v_other_ws FROM public.workspaces WHERE id <> v_ws
  ORDER BY id LIMIT 1;
  IF v_other_ws IS NOT NULL THEN
    v_result := public.clone_product(v_other_ws,v_source,v_actor,
      'REL03N synthetic foreign ' || v_marker);
    IF v_result->>'status' IS DISTINCT FROM 'denied' AND
       v_result->>'status' IS DISTINCT FROM 'not_found' THEN
      RAISE EXCEPTION 'Existing foreign-workspace scope was accepted.';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.products
      WHERE name = 'REL03N synthetic foreign ' || v_marker) THEN
    RAISE EXCEPTION 'Denied foreign-workspace clone left a product.';
  END IF;
  v_result := public.clone_product(v_ws,v_source,v_actor,v_source_name);
  IF v_result->>'status' IS DISTINCT FROM 'duplicate' THEN
    RAISE EXCEPTION 'Duplicate clone name was accepted.';
  END IF;
  v_result := public.clone_product(v_ws,v_source,v_actor,v_clone_name);
  IF v_result->>'status' IS DISTINCT FROM 'cloned' OR
     v_result->>'revisionLabel' IS DISTINCT FROM 'R00' OR
     v_result->'product'->>'name' IS DISTINCT FROM v_clone_name OR
     v_result->'product'->>'workspaceId' IS DISTINCT FROM v_ws::text OR
     v_result->'product'->>'id' IS NULL OR
     v_result->>'revisionId' IS NULL THEN
    RAISE EXCEPTION 'Authorized clone returned an unexpected contract.';
  END IF;
  v_clone := (v_result->'product'->>'id')::uuid;
  v_clone_r00 := (v_result->>'revisionId')::uuid;
  IF v_clone IS NOT DISTINCT FROM v_source OR
     v_clone_r00 IS NOT DISTINCT FROM v_source_r00 OR
     (SELECT count(*) FROM public.products WHERE id = v_clone
       AND workspace_id = v_ws AND active) <> 1 OR
     (SELECT count(*) FROM public.product_disciplines WHERE product_id = v_clone) <> 1 OR
     (SELECT count(*) FROM public.discipline_stages WHERE product_id = v_clone) <> 1 OR
     (SELECT count(*) FROM public.stage_activities WHERE product_id = v_clone) <> 3 THEN
    RAISE EXCEPTION 'Clone identity or hierarchy counts differ.';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'discipline',d.name,'disciplineOrder',d.display_order,
    'stage',s.display_name,'stageOrder',s.display_order,
    'definitionId',s.definition_id,'definitionColor',definition.color,
    'activity',a.name,'start',a.planned_start,'end',a.planned_end,
    'activityOrder',a.display_order,'colorOverride',a.color_override)
    ORDER BY a.display_order,a.name) INTO v_source_rows
  FROM public.product_disciplines AS d
  JOIN public.discipline_stages AS s ON s.product_id = d.product_id
    AND s.discipline_id = d.id
  JOIN public.stage_definitions AS definition ON definition.id = s.definition_id
  JOIN public.stage_activities AS a ON a.product_id = s.product_id AND a.stage_id = s.id
  WHERE d.product_id = v_source;
  SELECT jsonb_agg(jsonb_build_object(
    'discipline',d.name,'disciplineOrder',d.display_order,
    'stage',s.display_name,'stageOrder',s.display_order,
    'definitionId',s.definition_id,'definitionColor',definition.color,
    'activity',a.name,'start',a.planned_start,'end',a.planned_end,
    'activityOrder',a.display_order,'colorOverride',a.color_override)
    ORDER BY a.display_order,a.name) INTO v_clone_rows
  FROM public.product_disciplines AS d
  JOIN public.discipline_stages AS s ON s.product_id = d.product_id
    AND s.discipline_id = d.id
  JOIN public.stage_definitions AS definition ON definition.id = s.definition_id
  JOIN public.stage_activities AS a ON a.product_id = s.product_id AND a.stage_id = s.id
  WHERE d.product_id = v_clone;
  IF v_clone_rows IS DISTINCT FROM v_source_rows OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_clone
       AND id IN (v_a1,v_a2,v_a3)) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE product_id = v_clone AND definition_id = v_definition) THEN
    RAISE EXCEPTION 'Clone relationships, dates, order, or colors differ.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
      WHERE id = v_clone_r00 AND product_id = v_clone AND workspace_id = v_ws
        AND import_batch_id IS NULL AND label = 'R00' AND kind = 'baseline'
        AND snapshot->'product'->>'id' = v_clone::text
        AND snapshot->'actualStageColors'->>lower('R3N' || left(v_marker,12)) = '#778899'
        AND jsonb_array_length(snapshot->'disciplines'->0->'stages'->0->'activities') = 3
        AND snapshot->'disciplines'->0->'stages'->0->'activities'->0->>'colorOverride' = '#A1B2C3'
        AND snapshot->'disciplines'->0->'stages'->0->'activities'->1->>'colorOverride' = '#00ff88'
        AND snapshot->'disciplines'->0->'stages'->0->'activities'->2->'colorOverride' = 'null'::jsonb)
     OR (SELECT count(*) FROM public.initial_schedule_revisions
       WHERE product_id = v_source) <> 1 OR
     (SELECT count(*) FROM public.initial_schedule_revisions
       WHERE product_id = v_clone) <> 1 OR
     EXISTS (SELECT 1 FROM public.activity_date_changes
       WHERE product_id IN (v_source,v_clone)) OR
     EXISTS (SELECT 1 FROM public.business_target_date_changes
       WHERE product_id IN (v_source,v_clone)) THEN
    RAISE EXCEPTION 'Clone R00 colors or audit preservation differ.';
  END IF;
  SELECT jsonb_build_object(
    'product',(SELECT to_jsonb(p) FROM public.products AS p WHERE id = v_source),
    'activities',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id)
      FROM public.stage_activities AS a WHERE product_id = v_source),
    'r00',(SELECT to_jsonb(r) FROM public.initial_schedule_revisions AS r
      WHERE id = v_source_r00)) INTO v_source_after;
  IF v_source_after IS DISTINCT FROM v_source_before THEN
    RAISE EXCEPTION 'Source product, activities, or R00 changed during clone.';
  END IF;
  RAISE NOTICE 'REL03N clone colors, hierarchy, permissions and R00 PASS';
END;
$test$;

WITH original_state AS (
  SELECT
    (SELECT count(*) FROM public.products
      WHERE name NOT LIKE 'REL03N synthetic %') AS products,
    (SELECT count(*) FROM public.product_disciplines
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03N synthetic %')) AS disciplines,
    (SELECT count(*) FROM public.discipline_stages
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03N synthetic %')) AS stages,
    (SELECT count(*) FROM public.stage_activities
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03N synthetic %')) AS activities,
    (SELECT count(*) FROM public.stage_activities
      WHERE color_override IS NOT NULL AND product_id NOT IN
        (SELECT id FROM public.products WHERE name LIKE 'REL03N synthetic %')) AS colored,
    (SELECT md5(COALESCE(string_agg(
      jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
        'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
      FROM public.stage_activities AS a
      WHERE a.product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03N synthetic %')) AS dates,
    (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r
      WHERE r.product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03N synthetic %')) AS r00_fingerprint
)
SELECT 1 / CASE WHEN products = (:'rel03n_baseline'::jsonb->>'products')::bigint
  AND disciplines = (:'rel03n_baseline'::jsonb->>'disciplines')::bigint
  AND stages = (:'rel03n_baseline'::jsonb->>'stages')::bigint
  AND activities = (:'rel03n_baseline'::jsonb->>'activities')::bigint
  AND colored = (:'rel03n_baseline'::jsonb->>'colored')::bigint
  AND dates = (:'rel03n_baseline'::jsonb->>'dates')
  AND r00_fingerprint = (:'rel03n_baseline'::jsonb->>'r00_fingerprint')
  THEN 1 ELSE 0 END AS original_records_unchanged
FROM original_state;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'definitions', (SELECT count(*) FROM public.stage_definitions),
  'targets', (SELECT count(*) FROM public.business_targets),
  'import_batches', (SELECT count(*) FROM public.import_batches),
  'import_source_rows', (SELECT count(*) FROM public.import_source_rows),
  'colored', (SELECT count(*) FROM public.stage_activities WHERE color_override IS NOT NULL),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'target_audits', (SELECT count(*) FROM public.business_target_date_changes),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS after_rollback
\gset rel03n_
SELECT 1 / CASE WHEN count(*) = 0 THEN 1 ELSE 0 END AS synthetic_products_absent
FROM public.products WHERE name LIKE 'REL03N synthetic %';
ROLLBACK;

SELECT 1 / CASE WHEN :'rel03n_after_rollback'::jsonb = :'rel03n_baseline'::jsonb
  THEN 1 ELSE 0 END AS full_baseline_preserved;
