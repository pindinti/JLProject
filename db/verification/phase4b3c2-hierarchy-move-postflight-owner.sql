-- Run after the six edge confirmations commit and before the Worker hierarchy fixture.
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b3c2_edge_postflight', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'products', jsonb_build_array(:'test_conflict_product', :'test_valid_product',
    :'test_fixed_product', :'test_root_product', :'test_empty_product'),
  'edges', jsonb_build_array(
    jsonb_build_array(1, 2, :'test_conflict_product', :'test_conflict_dependency', :'test_conflict_destination_stage', :'conflict_destination_successor'),
    jsonb_build_array(2, 3, :'test_conflict_product', '4b420000-0000-4000-8000-000000000102', :'test_conflict_source_stage', :'conflict_source_successor'),
    jsonb_build_array(3, 2, :'test_valid_product', '4b420000-0000-4000-8000-000000000103', :'test_valid_destination_stage', :'valid_successor_stage'),
    jsonb_build_array(4, 5, :'test_fixed_product', '4b420000-0000-4000-8000-000000000104', :'test_explicit_stage', :'fixed_successor_stage'),
    jsonb_build_array(5, 6, :'test_fixed_product', '4b420000-0000-4000-8000-000000000105', :'test_partial_stage', :'fixed_successor_stage'),
    jsonb_build_array(6, 2, :'test_root_product', '4b420000-0000-4000-8000-000000000106', :'test_root_stage', :'root_successor_stage')),
  'fixedProduct', :'test_fixed_product',
  'dateStages', jsonb_build_array(:'test_explicit_stage', :'test_partial_stage', :'fixed_successor_stage'),
  'conflictProduct', :'test_conflict_product', 'conflictDestination', :'test_conflict_destination_stage'
)::text, true) AS postflight_scope \gset

DO $edge_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c2_edge_postflight')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_fixed uuid := (v_scope->>'fixedProduct')::uuid;
  v_product uuid;
  v_expected_cursor bigint;
  v_seed_id uuid := md5('jlproject.phase4b3c2.setup_operation')::uuid;
  v_reason constant text := 'Synthetic audited dependency fixture setup';
  v_expected record;
  v_edge record;
  v_event_values jsonb;
  v_finish date;
  v_start date;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner'
     OR NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = v_workspace
       AND name = 'Synthetic Phase 4B.3c.2 hierarchy move workspace')
     OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role = 'admin') THEN
    RAISE EXCEPTION '0042 edge postflight requires the synthetic hierarchy fixture and its owner session.';
  END IF;

  -- Each product starts with one structural operation. Only the fixed product has three date operations.
  FOR v_product IN SELECT value::uuid FROM jsonb_array_elements_text(v_scope->'products') LOOP
    SELECT 1 + count(*) + CASE WHEN v_product = v_fixed THEN 3 ELSE 0 END INTO v_expected_cursor
    FROM jsonb_array_elements(v_scope->'edges') AS edge(value) WHERE (value->>2)::uuid = v_product;
    IF NOT EXISTS (SELECT 1 FROM public.product_schedule_operations
         WHERE workspace_id = v_workspace AND product_id = v_product AND schedule_version = 1
           AND operation_id = v_seed_id AND operation_type = 'product_created' AND actor_id = v_actor)
       OR (SELECT count(*) FROM public.product_schedule_operations
         WHERE workspace_id = v_workspace AND product_id = v_product) <> v_expected_cursor
       OR NOT EXISTS (SELECT 1 FROM public.product_schedule_state AS state
         WHERE state.workspace_id = v_workspace AND state.product_id = v_product
           AND state.schedule_version = v_expected_cursor
           AND state.history_watermark = (SELECT max(event_id) FROM public.product_schedule_operation_events
             WHERE workspace_id = v_workspace AND product_id = v_product)) THEN
      RAISE EXCEPTION '0042 unexpected operation history or cursor for product % (expected version %).', v_product, v_expected_cursor;
    END IF;
  END LOOP;

  -- Keep the preceding exact source-event checks in the date seed. Recheck the committed date operation identities here.
  FOR v_expected IN
    SELECT value::uuid AS stage_id, ordinal + 1 AS version,
      format('4b420000-0000-4000-8000-00000000030%s', ordinal)::uuid AS operation_id
    FROM jsonb_array_elements_text(v_scope->'dateStages') WITH ORDINALITY AS stage(value, ordinal)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.product_schedule_operations AS operation
         JOIN public.product_schedule_operation_events AS event USING (workspace_id, product_id, schedule_version, operation_id)
         WHERE operation.workspace_id = v_workspace AND operation.product_id = v_fixed
           AND operation.schedule_version = v_expected.version AND operation.operation_id = v_expected.operation_id
           AND operation.operation_type = 'stage_dates_changed' AND operation.actor_id = v_actor
           AND event.entity_type = 'discipline_stages' AND event.entity_id = v_expected.stage_id
           AND event.change_type = 'discipline_stages_dates_changed')
       OR (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
         AND product_id = v_fixed AND schedule_version = v_expected.version) <> 1 THEN
      RAISE EXCEPTION '0042 unexpected committed date audit at version %.', v_expected.version;
    END IF;
  END LOOP;

  FOR v_edge IN
    SELECT (value->>1)::bigint AS version, (value->>2)::uuid AS product_id, (value->>3)::uuid AS edge_id,
      (value->>4)::uuid AS predecessor, (value->>5)::uuid AS successor,
      format('4b420000-0000-4000-8000-00000000020%s', value->>0)::uuid AS operation_id
    FROM jsonb_array_elements(v_scope->'edges') AS expected(value)
  LOOP
    v_event_values := jsonb_build_object('id', v_edge.edge_id, 'kind', 'stage',
      'predecessor', jsonb_build_object('productId', v_edge.product_id, 'kind', 'stage', 'id', v_edge.predecessor),
      'successor', jsonb_build_object('productId', v_edge.product_id, 'kind', 'stage', 'id', v_edge.successor));
    IF NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies
         WHERE workspace_id = v_workspace AND product_id = v_edge.product_id AND id = v_edge.edge_id
           AND endpoint_kind = 'stage' AND predecessor_stage_id = v_edge.predecessor
           AND successor_stage_id = v_edge.successor AND predecessor_activity_id IS NULL AND successor_activity_id IS NULL)
       OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operations AS operation
         JOIN public.product_schedule_operation_events AS event USING (workspace_id, product_id, schedule_version, operation_id)
         WHERE operation.workspace_id = v_workspace AND operation.product_id = v_edge.product_id
           AND operation.schedule_version = v_edge.version AND operation.operation_id = v_edge.operation_id
           AND operation.operation_type = 'schedule_dependencies_confirmed' AND operation.actor_id = v_actor
           AND operation.justification = v_reason AND event.entity_type = 'product_schedule_dependencies'
           AND event.entity_id = v_edge.edge_id AND event.change_type = 'dependency_added'
           AND event.new_values = v_event_values)
       OR (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
         AND product_id = v_edge.product_id AND schedule_version = v_edge.version) <> 1 THEN
      RAISE EXCEPTION '0042 edge % graph or committed audit assertion failed at version %.', v_edge.edge_id, v_edge.version;
    END IF;
  END LOOP;

  IF (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(v_scope->'products')) <> 5
     OR (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace) <> 5
     OR (SELECT count(*) FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace) <> 6
     OR (SELECT count(*) FROM public.product_schedule_operations WHERE workspace_id = v_workspace) <> 14
     OR (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND (entity_type = 'product_schedule_dependencies' OR change_type IN ('dependency_added', 'dependency_removed'))) <> 6 THEN
    RAISE EXCEPTION '0042 unexpected graph or audit records in the synthetic hierarchy workspace.';
  END IF;

  SELECT min(child.planned_start), max(child.planned_end) INTO v_start, v_finish
  FROM public.discipline_stages AS stage
  JOIN public.stage_activities AS child ON child.workspace_id = stage.workspace_id AND child.product_id = stage.product_id
    AND child.discipline_id = stage.discipline_id AND child.stage_id = stage.id AND child.deleted_at IS NULL
  WHERE stage.workspace_id = v_workspace AND stage.product_id = (v_scope->>'conflictProduct')::uuid
    AND stage.id = (v_scope->>'conflictDestination')::uuid AND stage.deleted_at IS NULL
    AND stage.planned_start IS NULL AND stage.planned_end IS NULL;
  IF v_start IS DISTINCT FROM DATE '2026-11-03' OR v_finish IS DISTINCT FROM DATE '2026-11-05' THEN
    RAISE EXCEPTION '0042 expected conflict destination derived interval 2026-11-03 through 2026-11-05 (actual % through %).', v_start, v_finish;
  END IF;
END;
$edge_postflight$;
ROLLBACK;
\echo PASS 0042 committed edges, audit histories, cursors and derived interval
