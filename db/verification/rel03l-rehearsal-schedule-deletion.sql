-- REL-03L: rollback-only logical deletion test for migrations 0020 and 0021.
-- Connect only to rehearsal branch br-snowy-wave-b6vn905p as jlproject_worker.
\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS baseline
\gset rel03l_
ROLLBACK;

SELECT 1 / CASE WHEN
  (:'rel03l_baseline'::jsonb->>'products')::bigint = 5 AND
  (:'rel03l_baseline'::jsonb->>'disciplines')::bigint = 19 AND
  (:'rel03l_baseline'::jsonb->>'stages')::bigint = 40 AND
  (:'rel03l_baseline'::jsonb->>'activities')::bigint = 73 AND
  (:'rel03l_baseline'::jsonb->>'date_audits')::bigint = 3 AND
  (:'rel03l_baseline'::jsonb->>'r00')::bigint = 1 AND
  (:'rel03l_baseline'::jsonb->>'dates') = '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS reported_baseline_matches;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $test$
DECLARE
  v_ws uuid;
  v_actor uuid;
  v_unauthorized uuid := gen_random_uuid();
  v_product uuid;
  v_def uuid;
  v_d1 uuid;
  v_d2 uuid;
  v_d3 uuid;
  v_s1 uuid;
  v_s2 uuid;
  v_s3 uuid;
  v_a1 uuid;
  v_a2 uuid;
  v_a3 uuid;
  v_a4 uuid;
  v_a5 uuid;
  v_op1 uuid := gen_random_uuid();
  v_op2 uuid := gen_random_uuid();
  v_op3 uuid := gen_random_uuid();
  v_preview jsonb;
  v_result jsonb;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_unused bigint;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'INSERT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'UPDATE') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'DELETE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'DELETE') OR
     has_any_column_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_any_column_privilege(current_user, 'public.schedule_deletion_events', 'INSERT') OR
     has_any_column_privilege(current_user, 'public.schedule_deletion_events', 'UPDATE') THEN
    RAISE EXCEPTION 'REL-03L requires the limited Worker deletion boundary.';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
      WHERE tgname IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard', 'stage_activities_deletion_guard',
        'schedule_deletion_events_immutable') AND tgenabled IN ('O','A')) <> 4 OR
     (SELECT count(*) FROM pg_constraint
      WHERE conname IN ('product_disciplines_deletion_operation_id_fkey',
        'discipline_stages_deletion_operation_id_fkey',
        'stage_activities_deletion_operation_id_fkey') AND contype = 'f') <> 3 THEN
    RAISE EXCEPTION 'Deletion guards or ledger foreign keys differ.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
      AND c.relname IN ('products','product_disciplines','stage_definitions',
        'discipline_stages','stage_activities','schedule_deletion_events')
      AND ((t.tgtype & 4) <> 0 OR (t.tgtype & 16) <> 0 OR (t.tgtype & 8) <> 0)
      AND t.tgname NOT IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard','stage_activities_deletion_guard',
        'stage_activities_dates_immutable','schedule_deletion_events_immutable')) THEN
    RAISE EXCEPTION 'Unreviewed write trigger could have external effects.';
  END IF;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.schedule_deletion_events' INTO v_unused;
    RAISE EXCEPTION 'Worker unexpectedly read the deletion ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'INSERT INTO public.schedule_deletion_events DEFAULT VALUES';
    RAISE EXCEPTION 'Worker unexpectedly inserted into the deletion ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'UPDATE public.schedule_deletion_events SET reason = reason WHERE false';
    RAISE EXCEPTION 'Worker unexpectedly updated the deletion ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'DELETE FROM public.schedule_deletion_events WHERE false';
    RAISE EXCEPTION 'Worker unexpectedly deleted from the deletion ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  RAISE NOTICE 'REL03L privilege boundary PASS';

  SELECT m.workspace_id, m.auth_user_id INTO v_ws, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role IN ('admin','editor')
  ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_ws IS NULL OR EXISTS (SELECT 1 FROM public.workspace_memberships
      WHERE workspace_id = v_ws AND auth_user_id = v_unauthorized) THEN
    RAISE EXCEPTION 'No suitable active writer or unauthorized marker.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products
      WHERE name LIKE 'REL03L synthetic %') THEN
    RAISE EXCEPTION 'Existing REL-03L marker; inspect before testing.';
  END IF;
  INSERT INTO public.products (workspace_id,name,created_by,updated_by)
  VALUES (v_ws,'REL03L synthetic ' || v_marker,v_actor,v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.stage_definitions (workspace_id,code,color)
  VALUES (v_ws,'R3L' || left(v_marker,12),'#556677') RETURNING id INTO v_def;
  INSERT INTO public.product_disciplines
    (workspace_id,product_id,name,short_code,color,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,'REL03L discipline one','R3L1','#556677',0,v_actor,v_actor)
  RETURNING id INTO v_d1;
  INSERT INTO public.product_disciplines
    (workspace_id,product_id,name,short_code,color,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,'REL03L discipline two','R3L2','#556677',1,v_actor,v_actor)
  RETURNING id INTO v_d2;
  INSERT INTO public.product_disciplines
    (workspace_id,product_id,name,short_code,color,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,'REL03L discipline three','R3L3','#556677',2,v_actor,v_actor)
  RETURNING id INTO v_d3;
  INSERT INTO public.discipline_stages
    (workspace_id,product_id,discipline_id,definition_id,display_name,
     display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d1,v_def,'REL03L stage one',0,v_actor,v_actor)
  RETURNING id INTO v_s1;
  INSERT INTO public.discipline_stages
    (workspace_id,product_id,discipline_id,definition_id,display_name,
     display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d2,v_def,'REL03L stage two',0,v_actor,v_actor)
  RETURNING id INTO v_s2;
  INSERT INTO public.discipline_stages
    (workspace_id,product_id,discipline_id,definition_id,display_name,
     display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d3,v_def,'REL03L stage three',0,v_actor,v_actor)
  RETURNING id INTO v_s3;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d1,v_s1,'REL03L activity one',DATE '2030-01-07',
    DATE '2030-01-08',0,v_actor,v_actor) RETURNING id INTO v_a1;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d2,v_s2,'REL03L activity two',DATE '2030-01-09',
    DATE '2030-01-10',0,v_actor,v_actor) RETURNING id INTO v_a2;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d2,v_s2,'REL03L activity three',DATE '2030-01-11',
    DATE '2030-01-12',1,v_actor,v_actor) RETURNING id INTO v_a3;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d3,v_s3,'REL03L activity four',DATE '2030-01-13',
    DATE '2030-01-14',0,v_actor,v_actor) RETURNING id INTO v_a4;
  INSERT INTO public.stage_activities
    (workspace_id,product_id,discipline_id,stage_id,name,planned_start,
     planned_end,display_order,created_by,updated_by)
  VALUES (v_ws,v_product,v_d3,v_s3,'REL03L activity five',DATE '2030-01-15',
    DATE '2030-01-16',1,v_actor,v_actor) RETURNING id INTO v_a5;
  IF (SELECT count(*) FROM public.stage_activities WHERE product_id = v_product) <> 5 THEN
    RAISE EXCEPTION 'Synthetic activity fixture is incomplete.';
  END IF;

  v_preview := public.preview_schedule_deletion(v_ws,v_product,v_actor,'activity',v_a1);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR
     (v_preview->'counts'->>'disciplines')::int IS DISTINCT FROM 0 OR
     (v_preview->'counts'->>'stages')::int IS DISTINCT FROM 0 OR
     (v_preview->'counts'->>'activities')::int IS DISTINCT FROM 1 OR
     jsonb_array_length(v_preview->'items') IS DISTINCT FROM 1 OR
     (v_preview->'items'->0->>'id')::uuid IS DISTINCT FROM v_a1 OR
     v_preview->'items'->0->>'kind' IS DISTINCT FROM 'activity' OR
     (v_preview->'items'->0->>'version')::bigint IS DISTINCT FROM 1 OR
     v_preview->>'fingerprint' IS DISTINCT FROM md5((v_preview->'items')::text) THEN
    RAISE EXCEPTION 'Activity preview scope or fingerprint differs.';
  END IF;
  v_result := public.preview_schedule_deletion(v_ws,v_product,v_unauthorized,'activity',v_a1);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Unauthorized actor preview was accepted.';
  END IF;
  v_result := public.preview_schedule_deletion(v_ws,v_product,v_actor,'invalid',v_a1);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Invalid kind preview was accepted.';
  END IF;
  v_result := public.preview_schedule_deletion(v_ws,v_product,v_actor,'activity',gen_random_uuid());
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unknown target preview was accepted.';
  END IF;
  RAISE NOTICE 'REL03L preview and authorization PASS';

  v_result := public.delete_schedule_subtree(v_ws,v_product,v_unauthorized,
    gen_random_uuid(),'activity',v_a1,v_preview->>'fingerprint','REL03L denied actor');
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Unauthorized deletion was accepted.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,
    gen_random_uuid(),'activity',v_a1,repeat('0',32),'REL03L stale preview');
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'Stale fingerprint was accepted.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,
    gen_random_uuid(),'activity',v_a1,v_preview->>'fingerprint','short');
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Invalid reason was accepted.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,
    gen_random_uuid(),'activity',gen_random_uuid(),v_preview->>'fingerprint',
    'REL03L unknown target');
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Unknown deletion target was accepted.';
  END IF;
  IF (SELECT deleted_at FROM public.stage_activities WHERE id = v_a1) IS NOT NULL THEN
    RAISE EXCEPTION 'A rejected deletion changed the activity.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,v_op1,
    'activity',v_a1,v_preview->>'fingerprint','REL03L activity deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR
     (v_result->>'operationId')::uuid IS DISTINCT FROM v_op1 OR
     v_result->'counts' IS DISTINCT FROM v_preview->'counts' OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_a1
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op1 AND version = 2) OR
     (SELECT count(*) FROM public.stage_activities
       WHERE product_id = v_product AND deleted_at IS NULL) <> 4 THEN
    RAISE EXCEPTION 'Activity logical deletion failed.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,gen_random_uuid(),
    'activity',v_a1,v_preview->>'fingerprint','REL03L duplicate target');
  IF v_result->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Repeat activity deletion was accepted.';
  END IF;
  BEGIN
    UPDATE public.stage_activities SET name = 'changed after deletion' WHERE id = v_a1;
    RAISE EXCEPTION 'Deleted activity was editable.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  BEGIN
    DELETE FROM public.stage_activities WHERE id = v_a1;
    RAISE EXCEPTION 'Worker physically deleted an activity.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE public.stage_activities SET deleted_at = now() WHERE id = v_a2;
    RAISE EXCEPTION 'Worker changed deletion metadata directly.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  RAISE NOTICE 'REL03L activity deletion and immutability PASS';

  v_preview := public.preview_schedule_deletion(v_ws,v_product,v_actor,'stage',v_s2);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR
     (v_preview->'counts'->>'disciplines')::int IS DISTINCT FROM 0 OR
     (v_preview->'counts'->>'stages')::int IS DISTINCT FROM 1 OR
     (v_preview->'counts'->>'activities')::int IS DISTINCT FROM 2 OR
     jsonb_array_length(v_preview->'items') IS DISTINCT FROM 3 OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'items') AS i
       WHERE i->>'kind' = 'stage' AND (i->>'id')::uuid = v_s2) OR
     (SELECT count(*) FROM jsonb_array_elements(v_preview->'items') AS i
       WHERE i->>'kind' = 'activity' AND (i->>'id')::uuid IN (v_a2,v_a3)) <> 2 OR
     v_preview->>'fingerprint' IS DISTINCT FROM md5((v_preview->'items')::text) THEN
    RAISE EXCEPTION 'Stage preview did not include exactly its descendants.';
  END IF;
  -- Reusing the first operation ID must fail at the ledger primary key before
  -- any stage/child update; the exception subtransaction rolls back its work.
  BEGIN
    PERFORM public.delete_schedule_subtree(v_ws,v_product,v_actor,v_op1,
      'stage',v_s2,v_preview->>'fingerprint','REL03L duplicate operation');
    RAISE EXCEPTION 'Duplicate operation ID was accepted.';
  EXCEPTION WHEN SQLSTATE '23505' THEN NULL;
  END;
  IF EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE id = v_s2 AND (deleted_at IS NOT NULL OR deletion_operation_id IS NOT NULL)) OR
     (SELECT count(*) FROM public.stage_activities
       WHERE id IN (v_a2,v_a3) AND deleted_at IS NULL AND deletion_operation_id IS NULL) <> 2 THEN
    RAISE EXCEPTION 'Failed stage operation left partial deletion.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,v_op2,
    'stage',v_s2,v_preview->>'fingerprint','REL03L stage deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR
     v_result->'counts' IS DISTINCT FROM v_preview->'counts' OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE id = v_s2
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op2 AND version = 2) OR
     (SELECT count(*) FROM public.stage_activities WHERE id IN (v_a2,v_a3)
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op2 AND version = 2) <> 2 OR
     EXISTS (SELECT 1 FROM public.product_disciplines
       WHERE id = v_d2 AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Stage subtree deletion failed.';
  END IF;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id,product_id,discipline_id,stage_id,name,display_order,created_by,updated_by)
    VALUES (v_ws,v_product,v_d2,v_s2,'Invalid child of deleted stage',9,v_actor,v_actor);
    RAISE EXCEPTION 'New activity referenced an inactive stage.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  RAISE NOTICE 'REL03L stage deletion and failure atomicity PASS';

  v_preview := public.preview_schedule_deletion(v_ws,v_product,v_actor,'discipline',v_d3);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR
     (v_preview->'counts'->>'disciplines')::int IS DISTINCT FROM 1 OR
     (v_preview->'counts'->>'stages')::int IS DISTINCT FROM 1 OR
     (v_preview->'counts'->>'activities')::int IS DISTINCT FROM 2 OR
     jsonb_array_length(v_preview->'items') IS DISTINCT FROM 4 OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'items') AS i
       WHERE i->>'kind' = 'discipline' AND (i->>'id')::uuid = v_d3) OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'items') AS i
       WHERE i->>'kind' = 'stage' AND (i->>'id')::uuid = v_s3) OR
     (SELECT count(*) FROM jsonb_array_elements(v_preview->'items') AS i
       WHERE i->>'kind' = 'activity' AND (i->>'id')::uuid IN (v_a4,v_a5)) <> 2 OR
     v_preview->>'fingerprint' IS DISTINCT FROM md5((v_preview->'items')::text) THEN
    RAISE EXCEPTION 'Discipline preview did not include exactly its descendants.';
  END IF;
  v_result := public.delete_schedule_subtree(v_ws,v_product,v_actor,v_op3,
    'discipline',v_d3,v_preview->>'fingerprint','REL03L discipline deletion');
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR
     v_result->'counts' IS DISTINCT FROM v_preview->'counts' OR
     NOT EXISTS (SELECT 1 FROM public.product_disciplines WHERE id = v_d3
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op3 AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE id = v_s3
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op3 AND version = 2) OR
     (SELECT count(*) FROM public.stage_activities WHERE id IN (v_a4,v_a5)
       AND deleted_at IS NOT NULL AND deletion_operation_id = v_op3 AND version = 2) <> 2 OR
     (SELECT count(*) FROM public.stage_activities
       WHERE product_id = v_product AND deleted_at IS NULL) <> 0 THEN
    RAISE EXCEPTION 'Discipline subtree deletion failed.';
  END IF;
  BEGIN
    INSERT INTO public.discipline_stages
      (workspace_id,product_id,discipline_id,definition_id,display_name,
       display_order,created_by,updated_by)
    VALUES (v_ws,v_product,v_d3,v_def,'Invalid child of deleted discipline',9,v_actor,v_actor);
    RAISE EXCEPTION 'New stage referenced an inactive discipline.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  IF (SELECT count(*) FROM public.products WHERE id = v_product AND active) <> 1 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE product_id = v_product) <> 0 OR
     (SELECT count(*) FROM public.activity_date_changes WHERE product_id = v_product) <> 0 OR
     (SELECT count(*) FROM public.stage_activities
       WHERE product_id = v_product AND deleted_at IS NOT NULL) <> 5 OR
     (SELECT count(*) FROM public.discipline_stages
       WHERE product_id = v_product AND deleted_at IS NOT NULL) <> 2 OR
     (SELECT count(*) FROM public.product_disciplines
       WHERE product_id = v_product AND deleted_at IS NOT NULL) <> 1 THEN
    RAISE EXCEPTION 'Synthetic product preservation or deletion totals differ.';
  END IF;
  RAISE NOTICE 'REL03L discipline deletion and preservation PASS';
END;
$test$;

WITH original_state AS (
  SELECT
    (SELECT count(*) FROM public.products
      WHERE name NOT LIKE 'REL03L synthetic %') AS products,
    (SELECT count(*) FROM public.product_disciplines
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03L synthetic %')) AS disciplines,
    (SELECT count(*) FROM public.discipline_stages
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03L synthetic %')) AS stages,
    (SELECT count(*) FROM public.stage_activities
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03L synthetic %')) AS activities,
    (SELECT md5(COALESCE(string_agg(
      jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
        'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
      FROM public.stage_activities AS a
      WHERE a.product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03L synthetic %')) AS dates,
    (SELECT count(*) FROM public.activity_date_changes) AS date_audits,
    (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r) AS r00_fingerprint
)
SELECT 1 / CASE WHEN products = (:'rel03l_baseline'::jsonb->>'products')::bigint
  AND disciplines = (:'rel03l_baseline'::jsonb->>'disciplines')::bigint
  AND stages = (:'rel03l_baseline'::jsonb->>'stages')::bigint
  AND activities = (:'rel03l_baseline'::jsonb->>'activities')::bigint
  AND dates = (:'rel03l_baseline'::jsonb->>'dates')
  AND date_audits = (:'rel03l_baseline'::jsonb->>'date_audits')::bigint
  AND r00_fingerprint = (:'rel03l_baseline'::jsonb->>'r00_fingerprint')
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
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS after_rollback
\gset rel03l_
SELECT 1 / CASE WHEN count(*) = 0 THEN 1 ELSE 0 END
  AS synthetic_products_absent_after_rollback
FROM public.products WHERE name LIKE 'REL03L synthetic %';
ROLLBACK;

SELECT 1 / CASE WHEN :'rel03l_after_rollback'::jsonb = :'rel03l_baseline'::jsonb
  THEN 1 ELSE 0 END AS full_baseline_preserved;
