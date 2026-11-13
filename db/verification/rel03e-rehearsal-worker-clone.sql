-- REL-03E: rollback-only clone verification for the approved rehearsal branch.
-- Execute only with the explicit Neon project/branch command in the review plan.
-- This script never changes roles, grants, or existing business rows.
\set ON_ERROR_STOP on

-- Session-only baseline survives the test transaction's ROLLBACK.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'definitions', (SELECT count(*) FROM public.stage_definitions),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'targets', (SELECT count(*) FROM public.business_targets),
  'batches', (SELECT count(*) FROM public.import_batches),
  'source_rows', (SELECT count(*) FROM public.import_source_rows),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'target_history', (SELECT count(*) FROM public.business_target_date_changes),
  'activity_history', (SELECT count(*) FROM public.activity_date_changes)
) AS baseline
\gset rel03e_
ROLLBACK;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_source uuid;
  v_clone uuid;
  v_clone_r00 uuid;
  v_batch uuid;
  v_discipline_a uuid;
  v_discipline_b uuid;
  v_definition uuid;
  v_stage_a uuid;
  v_stage_b uuid;
  v_activity_a uuid;
  v_activity_b uuid;
  v_target uuid;
  v_marker text := replace(gen_random_uuid()::text, '-', '');
  v_source_name text;
  v_clone_name text;
  v_failure_name text;
  v_result jsonb;
  v_target_status text;
  v_source_before jsonb;
  v_source_after jsonb;
  v_source_hierarchy jsonb;
  v_clone_hierarchy jsonb;
  v_source_targets jsonb;
  v_clone_targets jsonb;
  v_forced_failure_caught boolean := false;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'REL-03E requires neondb and the actual limited Worker role.';
  END IF;
  IF NOT has_function_privilege(current_user,
       'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     NOT has_table_privilege(current_user, 'public.products', 'INSERT') OR
     NOT has_table_privilege(current_user, 'public.import_batches', 'INSERT') OR
     NOT has_table_privilege(current_user, 'public.import_source_rows', 'INSERT') OR
     NOT has_table_privilege(current_user, 'public.initial_schedule_revisions', 'INSERT') THEN
    RAISE EXCEPTION 'REL-03E Worker privilege prerequisites differ.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger AS trigger
    JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public' AND relation.relname IN (
      'products', 'product_disciplines', 'stage_definitions', 'discipline_stages',
      'stage_activities', 'business_targets', 'import_batches',
      'import_source_rows', 'initial_schedule_revisions'
    ) AND NOT trigger.tgisinternal AND (trigger.tgtype & 4) <> 0
  ) THEN
    RAISE EXCEPTION 'REL-03E unreviewed INSERT trigger could have side effects.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products
             WHERE left(name, 17) = 'REL03E synthetic ') THEN
    RAISE EXCEPTION 'REL-03E synthetic marker already exists; stop for inspection.';
  END IF;

  -- Reuse an existing active writer solely as the FK/authorization identity.
  -- No identity value is returned or logged, and no membership is changed.
  SELECT m.workspace_id, m.auth_user_id INTO v_workspace, v_actor
  FROM public.workspace_memberships AS m
  WHERE m.active AND m.role IN ('admin', 'editor')
  ORDER BY m.workspace_id, m.auth_user_id LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'REL-03E requires an existing active editor/admin membership.';
  END IF;

  v_source_name := 'REL03E synthetic source ' || v_marker;
  v_clone_name := 'REL03E synthetic clone ' || v_marker;
  v_failure_name := 'REL03E synthetic rollback ' || v_marker;

  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
  VALUES (v_workspace, v_source_name, 'Rollback-only clone fixture', v_actor, v_actor)
  RETURNING id INTO v_source;

  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_source, 'Synthetic discipline A', 'R3EA', '#112233', 0, v_actor, v_actor)
  RETURNING id INTO v_discipline_a;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_source, 'Synthetic discipline B', 'R3EB', '#223344', 0, v_actor, v_actor)
  RETURNING id INTO v_discipline_b;

  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R3E' || left(v_marker, 12), '#334455')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_source, v_discipline_a, v_definition, 'Synthetic stage A',
          0, v_actor, v_actor)
  RETURNING id INTO v_stage_a;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_source, v_discipline_b, v_definition, 'Synthetic stage B',
          0, v_actor, v_actor)
  RETURNING id INTO v_stage_b;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, source_external_id, created_by, updated_by)
  VALUES (v_workspace, v_source, v_discipline_a, v_stage_a, 'Synthetic activity A',
          DATE '2026-01-05', DATE '2026-01-08', 0, 'T001', v_actor, v_actor)
  RETURNING id INTO v_activity_a;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start,
     planned_end, display_order, created_by, updated_by)
  VALUES (v_workspace, v_source, v_discipline_b, v_stage_b, 'Synthetic activity B',
          DATE '2026-02-02', DATE '2026-02-06', 2, v_actor, v_actor)
  RETURNING id INTO v_activity_b;

  INSERT INTO public.business_targets
    (workspace_id, product_id, name, target_date, operational_date,
     source_external_id, source_row, display_order, created_by)
  VALUES (v_workspace, v_source, 'Synthetic target', DATE '2026-03-10',
          DATE '2026-03-09', 'T002', 4, 0, v_actor)
  RETURNING id INTO v_target;

  INSERT INTO public.import_batches
    (workspace_id, product_id, idempotency_key, source_hash, request_hash,
     source_filename, created_by)
  VALUES (v_workspace, v_source, gen_random_uuid(),
          md5(v_marker) || md5(v_marker || 'source'),
          md5(v_marker || 'request') || md5(v_marker || 'payload'),
          'rel03e-synthetic.xlsx', v_actor)
  RETURNING id INTO v_batch;
  INSERT INTO public.import_source_rows
    (import_batch_id, source_sheet, source_row, source_external_id, activity_id)
  VALUES (v_batch, 'Cronograma Produto', 5, 'T001', v_activity_a);
  INSERT INTO public.import_source_rows
    (import_batch_id, source_sheet, source_row, target_id)
  VALUES (v_batch, 'Metas e Premissas', 4, v_target);
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (v_workspace, v_source, v_batch,
          jsonb_build_object('product', jsonb_build_object('id', v_source),
                             'dependencies', '[]'::jsonb), v_actor);

  -- Give the synthetic source real date/target history. The clone must copy
  -- current values while leaving that history with the source product.
  v_result := public.change_activity_dates(
    v_workspace, v_source, v_discipline_a, v_stage_a, v_activity_a, v_actor,
    gen_random_uuid(), DATE '2026-01-06', DATE '2026-01-09',
    'Synthetic audited date change', 1);
  IF v_result->>'status' <> 'updated' THEN
    RAISE EXCEPTION 'REL-03E synthetic activity audit setup failed.';
  END IF;
  IF (SELECT count(*) FROM public.activity_date_changes
      WHERE product_id = v_source) <> 1 THEN
    RAISE EXCEPTION 'REL-03E synthetic activity audit row is missing.';
  END IF;
  v_target_status := public.update_business_target(
    v_workspace, v_source, v_target, v_actor, gen_random_uuid(),
    'Synthetic target', NULL, '#AA4557', DATE '2026-03-11', 1,
    'Synthetic audited target change');
  IF v_target_status <> 'updated' OR
     (SELECT count(*) FROM public.business_target_date_changes
      WHERE product_id = v_source) <> 1 THEN
    RAISE EXCEPTION 'REL-03E synthetic target audit setup failed.';
  END IF;

  -- The source fingerprint covers complete rows, including dates, provenance,
  -- creator metadata, and the original R00. It is never printed.
  SELECT jsonb_build_object(
    'product', (SELECT to_jsonb(p) FROM public.products AS p WHERE p.id = v_source),
    'disciplines', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id)
                    FROM public.product_disciplines AS d WHERE d.product_id = v_source),
    'stages', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
               FROM public.discipline_stages AS s WHERE s.product_id = v_source),
    'activities', (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
                   FROM public.stage_activities AS a WHERE a.product_id = v_source),
    'targets', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id)
                FROM public.business_targets AS t WHERE t.product_id = v_source),
    'batch', (SELECT to_jsonb(b) FROM public.import_batches AS b WHERE b.id = v_batch),
    'source_rows', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.source_sheet, r.source_row)
                    FROM public.import_source_rows AS r WHERE r.import_batch_id = v_batch),
    'r00', (SELECT to_jsonb(r) FROM public.initial_schedule_revisions AS r
             WHERE r.product_id = v_source)) INTO v_source_before;

  -- Negative paths must return without inserting a product.
  v_result := public.clone_product(v_workspace, v_source, gen_random_uuid(),
                                   'REL03E synthetic denied ' || v_marker);
  IF v_result->>'status' <> 'denied' THEN
    RAISE EXCEPTION 'REL-03E unauthorized actor was not denied.';
  END IF;
  v_result := public.clone_product(v_workspace, v_source, v_actor, v_source_name);
  IF v_result->>'status' <> 'duplicate' THEN
    RAISE EXCEPTION 'REL-03E duplicate product name was not rejected.';
  END IF;

  -- A PL/pgSQL exception block is a subtransaction. This proves a successful
  -- Worker clone can be rolled back by its caller without residue.
  BEGIN
    v_result := public.clone_product(v_workspace, v_source, v_actor, v_failure_name);
    IF v_result->>'status' <> 'cloned' THEN
      RAISE EXCEPTION 'REL-03E rollback probe did not clone successfully.';
    END IF;
    RAISE EXCEPTION 'REL-03E forced caller rollback.' USING ERRCODE = 'PZ012';
  EXCEPTION WHEN SQLSTATE 'PZ012' THEN
    v_forced_failure_caught := true;
  END;
  IF NOT v_forced_failure_caught OR EXISTS (
    SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND name = v_failure_name
  ) THEN
    RAISE EXCEPTION 'REL-03E caller rollback left clone residue.';
  END IF;

  v_result := public.clone_product(v_workspace, v_source, v_actor, v_clone_name);
  IF v_result->>'status' <> 'cloned' OR v_result->>'revisionLabel' <> 'R00' OR
     (v_result->'product'->>'name') IS DISTINCT FROM v_clone_name OR
     (v_result->'product'->>'id') IS NULL OR (v_result->>'revisionId') IS NULL THEN
    RAISE EXCEPTION 'REL-03E authorized Worker clone returned an unexpected result.';
  END IF;
  v_clone := (v_result->'product'->>'id')::uuid;
  v_clone_r00 := (v_result->>'revisionId')::uuid;
  IF v_clone = v_source OR NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE id = v_clone AND workspace_id = v_workspace AND name = v_clone_name
      AND active AND created_by = v_actor AND updated_by = v_actor
  ) THEN
    RAISE EXCEPTION 'REL-03E clone product identity or scope differs.';
  END IF;
  IF (SELECT count(*) FROM public.product_disciplines WHERE product_id = v_clone) <> 2 OR
     (SELECT count(*) FROM public.discipline_stages WHERE product_id = v_clone) <> 2 OR
     (SELECT count(*) FROM public.stage_activities WHERE product_id = v_clone) <> 2 OR
     (SELECT count(*) FROM public.business_targets WHERE product_id = v_clone) <> 1 THEN
    RAISE EXCEPTION 'REL-03E clone hierarchy or target count differs.';
  END IF;

  -- Compare parent names, stage-definition IDs, dates, display-order values,
  -- and identity-independent content. New UUIDs may change the visible ID
  -- tie-break order when siblings share a display_order value.
  SELECT jsonb_agg(jsonb_build_object(
    'discipline', d.name, 'disciplineShortCode', d.short_code,
    'disciplineColor', d.color, 'disciplineDescription', d.description,
    'disciplineOrder', d.display_order,
    'stage', s.display_name, 'stageOrder', s.display_order,
    'definitionId', s.definition_id, 'definitionCode', definition.code,
    'definitionColor', definition.color, 'activity', a.name,
    'activityType', a.activity_type, 'start', a.planned_start,
    'end', a.planned_end, 'activityOrder', a.display_order,
    'notes', a.notes) ORDER BY d.name, s.display_name, a.name)
    INTO v_source_hierarchy
  FROM public.product_disciplines AS d
  JOIN public.discipline_stages AS s ON s.product_id = d.product_id AND s.discipline_id = d.id
  JOIN public.stage_definitions AS definition ON definition.id = s.definition_id
  JOIN public.stage_activities AS a ON a.product_id = s.product_id AND a.stage_id = s.id
  WHERE d.product_id = v_source;
  SELECT jsonb_agg(jsonb_build_object(
    'discipline', d.name, 'disciplineShortCode', d.short_code,
    'disciplineColor', d.color, 'disciplineDescription', d.description,
    'disciplineOrder', d.display_order,
    'stage', s.display_name, 'stageOrder', s.display_order,
    'definitionId', s.definition_id, 'definitionCode', definition.code,
    'definitionColor', definition.color, 'activity', a.name,
    'activityType', a.activity_type, 'start', a.planned_start,
    'end', a.planned_end, 'activityOrder', a.display_order,
    'notes', a.notes) ORDER BY d.name, s.display_name, a.name)
    INTO v_clone_hierarchy
  FROM public.product_disciplines AS d
  JOIN public.discipline_stages AS s ON s.product_id = d.product_id AND s.discipline_id = d.id
  JOIN public.stage_definitions AS definition ON definition.id = s.definition_id
  JOIN public.stage_activities AS a ON a.product_id = s.product_id AND a.stage_id = s.id
  WHERE d.product_id = v_clone;
  IF v_clone_hierarchy IS DISTINCT FROM v_source_hierarchy OR
     (SELECT count(DISTINCT definition_id) FROM public.discipline_stages
      WHERE product_id = v_clone) <> 1 OR
     EXISTS (SELECT 1 FROM public.product_disciplines WHERE product_id = v_clone
             AND id IN (v_discipline_a, v_discipline_b)) OR
     EXISTS (SELECT 1 FROM public.discipline_stages WHERE product_id = v_clone
             AND id IN (v_stage_a, v_stage_b)) OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_clone
             AND id IN (v_activity_a, v_activity_b)) THEN
    RAISE EXCEPTION 'REL-03E hierarchy, definitions, dates, order, or IDs differ.';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'name', name, 'targetDate', target_date, 'operationalDate', operational_date,
    'displayOrder', display_order, 'description', description, 'color', color)
    ORDER BY display_order, name) INTO v_source_targets
  FROM public.business_targets WHERE product_id = v_source AND deleted_at IS NULL;
  SELECT jsonb_agg(jsonb_build_object(
    'name', name, 'targetDate', target_date, 'operationalDate', operational_date,
    'displayOrder', display_order, 'description', description, 'color', color)
    ORDER BY display_order, name) INTO v_clone_targets
  FROM public.business_targets WHERE product_id = v_clone AND deleted_at IS NULL;
  IF v_clone_targets IS DISTINCT FROM v_source_targets OR
     EXISTS (SELECT 1 FROM public.business_targets
             WHERE product_id = v_clone AND id = v_target) THEN
    RAISE EXCEPTION 'REL-03E target values or IDs differ.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.initial_schedule_revisions
    WHERE id = v_clone_r00 AND product_id = v_clone AND workspace_id = v_workspace
      AND import_batch_id IS NULL AND label = 'R00' AND kind = 'baseline'
      AND snapshot->'product'->>'id' = v_clone::text
      AND jsonb_array_length(snapshot->'disciplines') = 2
      AND jsonb_array_length(snapshot->'targets') = 1
      AND jsonb_array_length(snapshot->'stageIds') = 2
      AND snapshot->'dependencies' = '[]'::jsonb
      AND snapshot->'sourceMeta' = '[]'::jsonb
  ) OR (SELECT count(*) FROM public.initial_schedule_revisions
        WHERE product_id = v_clone) <> 1 OR
     EXISTS (SELECT 1 FROM public.import_batches WHERE product_id = v_clone) OR
     EXISTS (SELECT 1 FROM public.import_source_rows AS r
             JOIN public.stage_activities AS a ON a.id = r.activity_id
             WHERE a.product_id = v_clone) OR
     EXISTS (SELECT 1 FROM public.import_source_rows AS r
             JOIN public.business_targets AS t ON t.id = r.target_id
             WHERE t.product_id = v_clone) OR
     EXISTS (SELECT 1 FROM public.stage_activities
             WHERE product_id = v_clone AND source_external_id IS NOT NULL) OR
     EXISTS (SELECT 1 FROM public.business_targets
             WHERE product_id = v_clone AND
               (source_external_id IS NOT NULL OR source_row IS NOT NULL)) OR
     (SELECT count(*) FROM public.business_target_date_changes
      WHERE product_id = v_source) <> 1 OR
      (SELECT count(*) FROM public.activity_date_changes
       WHERE product_id = v_source) <> 1 OR
     EXISTS (SELECT 1 FROM public.business_target_date_changes
              WHERE product_id = v_clone) OR
      EXISTS (SELECT 1 FROM public.activity_date_changes
              WHERE product_id = v_clone) THEN
    RAISE EXCEPTION 'REL-03E clone R00, import provenance, or target audit differs.';
  END IF;

  SELECT jsonb_build_object(
    'product', (SELECT to_jsonb(p) FROM public.products AS p WHERE p.id = v_source),
    'disciplines', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id)
                    FROM public.product_disciplines AS d WHERE d.product_id = v_source),
    'stages', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
               FROM public.discipline_stages AS s WHERE s.product_id = v_source),
    'activities', (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
                   FROM public.stage_activities AS a WHERE a.product_id = v_source),
    'targets', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id)
                FROM public.business_targets AS t WHERE t.product_id = v_source),
    'batch', (SELECT to_jsonb(b) FROM public.import_batches AS b WHERE b.id = v_batch),
    'source_rows', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.source_sheet, r.source_row)
                    FROM public.import_source_rows AS r WHERE r.import_batch_id = v_batch),
    'r00', (SELECT to_jsonb(r) FROM public.initial_schedule_revisions AS r
             WHERE r.product_id = v_source)) INTO v_source_after;
  IF v_source_after IS DISTINCT FROM v_source_before THEN
    RAISE EXCEPTION 'REL-03E source product or provenance changed.';
  END IF;
  RAISE NOTICE 'REL-03E Worker clone, authorization, content, R00, and caller rollback assertions passed.';
END;
$test$;

-- Unconditionally discard the successful synthetic clone and all fixtures.
ROLLBACK;

-- A new read-only transaction verifies that no tested table retained rows.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
WITH current_counts AS (
  SELECT jsonb_build_object(
    'products', (SELECT count(*) FROM public.products),
    'disciplines', (SELECT count(*) FROM public.product_disciplines),
    'definitions', (SELECT count(*) FROM public.stage_definitions),
    'stages', (SELECT count(*) FROM public.discipline_stages),
    'activities', (SELECT count(*) FROM public.stage_activities),
    'targets', (SELECT count(*) FROM public.business_targets),
    'batches', (SELECT count(*) FROM public.import_batches),
    'source_rows', (SELECT count(*) FROM public.import_source_rows),
    'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
    'target_history', (SELECT count(*) FROM public.business_target_date_changes),
    'activity_history', (SELECT count(*) FROM public.activity_date_changes)
  ) AS value
)
SELECT 1 / CASE WHEN value = :'rel03e_baseline'::jsonb AND NOT EXISTS (
  SELECT 1 FROM public.products WHERE left(name, 17) = 'REL03E synthetic '
) THEN 1 ELSE 0 END AS no_persistent_test_rows
FROM current_counts;
ROLLBACK;
