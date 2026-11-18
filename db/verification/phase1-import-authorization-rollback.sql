-- Rollback-only import authorization checks for migration 0031.
-- Run only on verified Development as jlproject_worker after migration 0031 is separately approved and applied.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $authorized_import$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_operation uuid := gen_random_uuid();
  v_idempotency_key uuid := gen_random_uuid();
  v_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_activity uuid;
  v_foreign_workspace uuid;
  v_result jsonb;
  v_payload jsonb;
  v_operation_row record;
  v_schedule_version bigint;
  v_history_watermark bigint;
  v_existing_r00_products uuid[];
  v_existing_r00_before text;
  v_existing_r00_after text;
  v_product_name text := 'P1-0031 authorized import ' || gen_random_uuid()::text;
  v_unauthorized_name text := 'P1-0031 unauthorized import ' || gen_random_uuid()::text;
  v_source_hash text := repeat('a', 64);
  v_request_hash text := repeat('b', 64);
  v_denied boolean := false;
  v_r00_update_denied boolean := false;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     NOT has_function_privilege(current_user,
       'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE') OR
     NOT has_column_privilege(current_user, 'public.stage_activities', 'source_external_id', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'source_external_id', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'INSERT') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Worker import or least-privilege state differs from the approved migration 0031 contract.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id
    LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Import integration requires an active Development administrator.';
  END IF;

  SELECT COALESCE(array_agg(revision.product_id ORDER BY revision.product_id), ARRAY[]::uuid[])
    INTO v_existing_r00_products
    FROM public.initial_schedule_revisions AS revision WHERE revision.label = 'R00';
  SELECT md5(COALESCE(string_agg(revision.id::text || '|' || revision.snapshot::text,
    E'\n' ORDER BY revision.id), '')) INTO v_existing_r00_before
    FROM public.initial_schedule_revisions AS revision
    WHERE revision.label = 'R00' AND revision.product_id = ANY(v_existing_r00_products);

  v_payload := jsonb_build_object(
    'productName', v_product_name,
    'sourceFilename', 'synthetic-0031.xlsx',
    'disciplines', jsonb_build_array(jsonb_build_object(
      'name', 'P1-0031 synthetic discipline', 'shortCode', 'P31', 'color', '#335577',
      'displayOrder', 0, 'stages', jsonb_build_array(jsonb_build_object(
        'code', 'P31S', 'color', '#446688', 'displayName', 'P1-0031 synthetic stage',
        'displayOrder', 0, 'activities', jsonb_build_array(jsonb_build_object(
          'name', 'P1-0031 imported activity', 'activityType', 'Test',
          'plannedStart', '2031-02-03', 'plannedEnd', '2031-02-05',
          'displayOrder', 5, 'notes', NULL, 'sourceId', 'T001', 'sourceRow', 5)))))),
    'targets', '[]'::jsonb, 'sourceMeta', '[]'::jsonb);

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_imported', true);
  v_result := public.import_initial_schedule(v_workspace, v_actor, v_idempotency_key,
    v_source_hash, v_request_hash, v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Authorized Worker import failed: %', v_result;
  END IF;
  v_product := (v_result->>'productId')::uuid;

  SELECT discipline.id INTO v_discipline
    FROM public.product_disciplines AS discipline
    WHERE discipline.workspace_id = v_workspace AND discipline.product_id = v_product;
  SELECT stage.id INTO v_stage
    FROM public.discipline_stages AS stage
    WHERE stage.workspace_id = v_workspace AND stage.product_id = v_product;
  SELECT activity.id INTO v_activity
    FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace AND activity.product_id = v_product;
  IF v_discipline IS NULL OR v_stage IS NULL OR v_activity IS NULL OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS activity
       WHERE activity.workspace_id = v_workspace AND activity.product_id = v_product
         AND activity.id = v_activity AND activity.source_external_id = 'T001'
         AND activity.planned_start = DATE '2031-02-03'
         AND activity.planned_end = DATE '2031-02-05') OR
     NOT EXISTS (SELECT 1 FROM public.import_source_rows AS source_row
       JOIN public.import_batches AS batch ON batch.id = source_row.import_batch_id
       WHERE batch.workspace_id = v_workspace AND batch.product_id = v_product
         AND source_row.source_sheet = 'Cronograma Produto' AND source_row.source_row = 5
         AND source_row.source_external_id = 'T001' AND source_row.activity_id = v_activity) OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions AS revision
       WHERE revision.workspace_id = v_workspace AND revision.product_id = v_product
         AND revision.label = 'R00' AND revision.snapshot->'dependencies' = '[]'::jsonb
         AND revision.snapshot->'activityIds'->>'T001' = v_activity::text
         AND revision.snapshot#>>'{disciplines,0,stages,0,activities,0,sourceId}' = 'T001') THEN
    RAISE EXCEPTION 'Import source identity, dates, hierarchy, or R00 snapshot was not preserved.';
  END IF;

  SELECT operation.* INTO v_operation_row
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  SELECT schedule_version, history_watermark
    INTO v_schedule_version, v_history_watermark
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_operation_row.operation_id IS NULL OR v_operation_row.schedule_version <> 1 OR
     v_operation_row.actor_id <> v_actor OR v_operation_row.operation_type <> 'schedule_imported' OR
     jsonb_array_length(v_operation_row.events) <> 4 OR
     (SELECT count(*) FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100)) <> 1 OR
     v_schedule_version <> 1 OR v_history_watermark <= 0 THEN
    RAISE EXCEPTION 'Import audit grouping or exactly-once Living Schedule cursor advancement failed.';
  END IF;

  v_result := public.import_initial_schedule(v_workspace, v_actor, v_idempotency_key,
    v_source_hash, v_request_hash, v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'replayed' OR
     (v_result->>'productId')::uuid <> v_product THEN
    RAISE EXCEPTION 'An identical import retry did not return its original result.';
  END IF;
  IF public.import_initial_schedule(v_workspace, v_actor, v_idempotency_key,
      v_source_hash, repeat('c', 64), v_payload)->>'status' IS DISTINCT FROM 'conflict' OR
     public.import_initial_schedule(v_workspace, v_actor, gen_random_uuid(),
      v_source_hash, repeat('d', 64), v_payload)->>'status' IS DISTINCT FROM 'duplicate' THEN
    RAISE EXCEPTION 'Import conflict or duplicate-source behavior changed.';
  END IF;

  v_result := public.import_initial_schedule(v_workspace, gen_random_uuid(), gen_random_uuid(),
    repeat('e', 64), repeat('f', 64), v_payload || jsonb_build_object('productName', v_unauthorized_name));
  IF v_result->>'status' IS DISTINCT FROM 'denied' OR
     EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND name = v_unauthorized_name) THEN
    RAISE EXCEPTION 'An actor without active workspace membership was able to import.';
  END IF;

  SELECT workspace.id INTO v_foreign_workspace
    FROM public.workspaces AS workspace
    WHERE workspace.id <> v_workspace AND NOT EXISTS (
      SELECT 1 FROM public.workspace_memberships AS membership
      WHERE membership.workspace_id = workspace.id AND membership.auth_user_id = v_actor
        AND membership.active AND membership.role IN ('admin', 'editor'))
    ORDER BY workspace.id LIMIT 1;
  IF v_foreign_workspace IS NOT NULL THEN
    v_result := public.import_initial_schedule(v_foreign_workspace, v_actor, gen_random_uuid(),
      repeat('1', 64), repeat('2', 64), v_payload);
    IF v_result->>'status' IS DISTINCT FROM 'denied' THEN
      RAISE EXCEPTION 'A workspace member imported into a workspace they cannot edit.';
    END IF;
  END IF;

  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = '{}'::jsonb
      WHERE product_id = v_product AND label = 'R00';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    v_r00_update_denied := true;
  END;
  IF NOT v_r00_update_denied OR
     (SELECT snapshot FROM public.initial_schedule_revisions
       WHERE product_id = v_product AND label = 'R00')->>'activityIds' IS NULL THEN
    RAISE EXCEPTION 'R00 mutation was not rejected or the imported baseline changed.';
  END IF;

  SELECT md5(COALESCE(string_agg(revision.id::text || '|' || revision.snapshot::text,
    E'\n' ORDER BY revision.id), '')) INTO v_existing_r00_after
    FROM public.initial_schedule_revisions AS revision
    WHERE revision.label = 'R00' AND revision.product_id = ANY(v_existing_r00_products);
  IF v_existing_r00_after IS DISTINCT FROM v_existing_r00_before THEN
    RAISE EXCEPTION 'An existing R00 snapshot changed during import verification.';
  END IF;
END;
$authorized_import$;
ROLLBACK;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $atomic_import_failure$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_operation uuid := gen_random_uuid();
  v_product_name text := 'P1-0031 rolled-back import ' || gen_random_uuid()::text;
  v_payload jsonb;
  v_failed boolean := false;
BEGIN
  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Import rollback test requires an active Development administrator.';
  END IF;

  v_payload := jsonb_build_object(
    'productName', v_product_name,
    'sourceFilename', 'synthetic-0031-invalid.xlsx',
    'disciplines', jsonb_build_array(jsonb_build_object(
      'name', 'P1-0031 duplicate ID discipline', 'shortCode', 'P31D', 'color', '#335577',
      'displayOrder', 0, 'stages', jsonb_build_array(jsonb_build_object(
        'code', 'P31D', 'color', '#446688', 'displayName', 'P1-0031 duplicate ID stage',
        'displayOrder', 0, 'activities', jsonb_build_array(
          jsonb_build_object('name', 'First duplicate source', 'activityType', NULL,
            'plannedStart', '2031-03-03', 'plannedEnd', '2031-03-04', 'displayOrder', 5,
            'notes', NULL, 'sourceId', 'T901', 'sourceRow', 5),
          jsonb_build_object('name', 'Second duplicate source', 'activityType', NULL,
            'plannedStart', '2031-03-05', 'plannedEnd', '2031-03-06', 'displayOrder', 6,
            'notes', NULL, 'sourceId', 'T901', 'sourceRow', 6)))))),
    'targets', '[]'::jsonb, 'sourceMeta', '[]'::jsonb);

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_imported', true);
  BEGIN
    PERFORM public.import_initial_schedule(v_workspace, v_actor, gen_random_uuid(),
      repeat('9', 64), repeat('8', 64), v_payload);
  EXCEPTION WHEN unique_violation THEN
    v_failed := true;
  END;

  IF NOT v_failed OR
     EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND name = v_product_name) OR
     EXISTS (SELECT 1 FROM public.import_batches WHERE workspace_id = v_workspace
       AND source_hash = repeat('9', 64)) OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions
       WHERE workspace_id = v_workspace AND product_id IN (
         SELECT id FROM public.products WHERE name = v_product_name)) OR
      EXISTS (SELECT 1 FROM public.products AS product
        CROSS JOIN LATERAL public.list_product_schedule_operations(
          v_workspace, product.id, v_actor, NULL, 100) AS operation
        WHERE product.workspace_id = v_workspace AND operation.operation_id = v_operation) THEN
    RAISE EXCEPTION 'A partially failed import left product, baseline, or visible operation state.';
  END IF;
END;
$atomic_import_failure$;
ROLLBACK;
