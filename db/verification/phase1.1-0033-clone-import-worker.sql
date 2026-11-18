\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $clone_import_test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_operation uuid := gen_random_uuid();
  v_source_product uuid;
  v_clone_product uuid;
  v_import_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_definition uuid;
  v_activity uuid;
  v_result jsonb;
  v_import_result jsonb;
  v_code text := 'P1' || left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_source_name text := 'P1-0030 clone source ' || gen_random_uuid()::text;
  v_clone_name text := 'P1-0030 clone ' || gen_random_uuid()::text;
  v_import_name text := 'P1-0030 import ' || gen_random_uuid()::text;
  v_r00_products uuid[];
  v_r00_before text;
  v_r00_after text;
  v_snapshot_before jsonb;
  v_color text;
  v_reason text := 'P1-0030 rollback-only clone/import verification';
BEGIN
  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id
    LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Clone/import verification requires an active Development administrator.';
  END IF;
  SELECT COALESCE(array_agg(revision.product_id ORDER BY revision.product_id), ARRAY[]::uuid[])
    INTO v_r00_products FROM public.initial_schedule_revisions AS revision WHERE revision.label = 'R00';
  SELECT md5(COALESCE(string_agg(revision.id::text || '|' || revision.snapshot::text,
    E'\n' ORDER BY revision.id), '')) INTO v_r00_before
    FROM public.initial_schedule_revisions AS revision
    WHERE revision.label = 'R00' AND revision.product_id = ANY(v_r00_products);

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, v_source_name, v_actor, v_actor) RETURNING id INTO v_source_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_source_product, 'Clone source discipline', 'PCS', '#335577', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  PERFORM set_config('jlproject.schedule_operation_type', 'stage_created_with_dates', true);
  v_result := jsonb_build_object('id', public.create_discipline_stage_with_dates(
    v_workspace, v_source_product, v_discipline, v_actor, v_operation, v_code, '#335577',
    'Clone source stage', 0, DATE '2030-02-02', DATE '2030-02-06', v_reason));
  v_stage := (v_result->>'id')::uuid;
  SELECT definition.id INTO v_definition FROM public.stage_definitions AS definition
    WHERE definition.workspace_id = v_workspace AND definition.code = v_code;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_source_product, v_discipline, v_stage, 'Clone source activity',
      DATE '2030-02-02', DATE '2030-02-04', 0, v_actor, v_actor)
    RETURNING id INTO v_activity;

  PERFORM set_config('jlproject.schedule_operation_type', 'product_cloned', true);
  v_result := public.clone_product(v_workspace, v_source_product, v_actor, v_clone_name);
  IF v_result->>'status' IS DISTINCT FROM 'cloned' THEN
    RAISE EXCEPTION 'Product clone failed: %', v_result;
  END IF;
  v_clone_product := (v_result->'product'->>'id')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages AS stage
       WHERE stage.workspace_id = v_workspace AND stage.product_id = v_clone_product
         AND stage.planned_start = DATE '2030-02-02' AND stage.planned_end = DATE '2030-02-06') OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions AS revision
       CROSS JOIN LATERAL jsonb_array_elements(revision.snapshot->'disciplines') AS discipline(value)
       CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage(value)
       WHERE revision.workspace_id = v_workspace AND revision.product_id = v_clone_product
         AND revision.label = 'R00' AND stage.value->>'plannedStart' = '2030-02-02'
         AND stage.value->>'plannedEnd' = '2030-02-06') THEN
    RAISE EXCEPTION 'Clone did not preserve planned stage dates in working data and its new R00.';
  END IF;
  SELECT snapshot INTO v_snapshot_before FROM public.initial_schedule_revisions
    WHERE product_id = v_clone_product AND label = 'R00';

  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_imported', true);
  v_import_result := public.import_initial_schedule(
    v_workspace, v_actor, gen_random_uuid(), repeat('a', 64), repeat('b', 64),
    jsonb_build_object(
      'productName', v_import_name,
      'sourceFilename', 'synthetic-only.xlsx',
      'disciplines', jsonb_build_array(jsonb_build_object(
        'name', 'Imported synthetic discipline', 'shortCode', 'PIM', 'color', '#445566',
        'displayOrder', 0, 'stages', jsonb_build_array(jsonb_build_object(
          'code', 'IM' || left(replace(gen_random_uuid()::text, '-', ''), 12),
          'color', '#445566', 'displayName', 'Imported synthetic stage', 'displayOrder', 0,
          'activities', jsonb_build_array(jsonb_build_object(
            'name', 'Imported synthetic activity', 'activityType', NULL,
            'plannedStart', '2030-03-01', 'plannedEnd', '2030-03-02',
            'displayOrder', 0, 'notes', NULL, 'sourceId', 'T902', 'sourceRow', 4)))))),
      'targets', '[]'::jsonb, 'sourceMeta', '[]'::jsonb));
  IF v_import_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Initial schedule import failed: %', v_import_result;
  END IF;
  v_import_product := (v_import_result->>'productId')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
       WHERE product_id = v_import_product AND label = 'R00') OR
     (SELECT count(*) FROM (
       SELECT scoped.product_id, operation.schedule_version, operation.operation_id
       FROM (VALUES (v_source_product), (v_clone_product), (v_import_product)) AS scoped(product_id)
       CROSS JOIN LATERAL public.list_product_schedule_operations(
         v_workspace, scoped.product_id, v_actor, NULL, 100) AS operation
       WHERE operation.schedule_version = 1 AND operation.operation_id = v_operation
     ) AS grouped_operations) <> 3 THEN
    RAISE EXCEPTION 'Import/clone product provenance or grouped cursor state is incomplete.';
  END IF;

  -- Shared stage-definition metadata emits one detail per affected product,
  -- while preserving the snapshot already captured in the clone R00.
  SELECT color INTO v_color FROM public.stage_definitions WHERE id = v_definition;
  PERFORM set_config('jlproject.schedule_operation_type', 'stage_definition_color_changed', true);
  UPDATE public.stage_definitions SET color = '#446688' WHERE id = v_definition;
  IF (SELECT snapshot FROM public.initial_schedule_revisions
        WHERE product_id = v_clone_product AND label = 'R00') IS DISTINCT FROM v_snapshot_before OR
     (SELECT count(*) FROM (
        SELECT scoped.product_id, operation.operation_id
        FROM (VALUES (v_source_product), (v_clone_product), (v_import_product)) AS scoped(product_id)
        CROSS JOIN LATERAL public.list_product_schedule_operations(
          v_workspace, scoped.product_id, v_actor, NULL, 100) AS operation
      ) AS grouped_operations) <> 3 OR
     (SELECT count(*) FROM (
        SELECT detail.value
        FROM (VALUES (v_source_product), (v_clone_product)) AS scoped(product_id)
        CROSS JOIN LATERAL public.list_product_schedule_operations(
          v_workspace, scoped.product_id, v_actor, NULL, 100) AS operation
        CROSS JOIN LATERAL jsonb_array_elements(operation.events) AS detail(value)
        WHERE operation.operation_id = v_operation
      ) AS grouped_details
      WHERE grouped_details.value->>'entityType' = 'stage_definition') < 2 THEN
    RAISE EXCEPTION 'Cross-product metadata grouping or R00 immutability failed.';
  END IF;

  SELECT md5(COALESCE(string_agg(revision.id::text || '|' || revision.snapshot::text,
    E'\n' ORDER BY revision.id), '')) INTO v_r00_after
    FROM public.initial_schedule_revisions AS revision
    WHERE revision.label = 'R00' AND revision.product_id = ANY(v_r00_products);
  IF v_r00_after IS DISTINCT FROM v_r00_before THEN
    RAISE EXCEPTION 'An existing R00 snapshot changed during clone/import.';
  END IF;
END;
$clone_import_test$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
