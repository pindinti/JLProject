\set ON_ERROR_STOP on

-- Development-only history integration. Synthetic schedule mutations are inside
-- one transaction and are always rolled back. Run as jlproject_worker.
SET statement_timeout = '90s';

DO $legacy_history$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_cursor jsonb;
  v_before_cursor jsonb;
  v_after_cursor jsonb;
  v_result jsonb;
  v_page jsonb;
  v_event jsonb;
  v_previous_at timestamptz;
  v_current_at timestamptz;
  v_previous_id text;
  v_current_id text;
  v_iteration integer;
  v_product_count integer := 0;
  v_event_count integer := 0;
  v_same_timestamp_count integer := 0;
  v_reversal_count integer := 0;
  v_deletion_count integer := 0;
  v_stage_date_count integer := 0;
  v_target_date_count integer := 0;
  v_hierarchy_count integer := 0;
  v_activity_date_count integer := 0;
  v_direct_read bigint;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_function_privilege(current_user, 'public.link_product_schedule_history_provenance()', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'SELECT') THEN
    RAISE EXCEPTION 'Worker identity, history execute, or generic-ledger privilege boundary differs.';
  END IF;

  BEGIN
    EXECUTE 'SELECT count(*) FROM public.product_schedule_operation_events' INTO v_direct_read;
    RAISE EXCEPTION 'Worker unexpectedly read the generic detail ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.product_schedule_operation_source_events' INTO v_direct_read;
    RAISE EXCEPTION 'Worker unexpectedly read the source-link ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'An active Development administrator is required.';
  END IF;

  IF public.list_product_change_history(gen_random_uuid(),
      (SELECT product.id FROM public.products AS product
       WHERE product.workspace_id = v_workspace ORDER BY product.id LIMIT 1),
      v_actor, 10, NULL, NULL)->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'History reader did not reject a non-member workspace.';
  END IF;

  FOR v_product IN
    SELECT product.id FROM public.products AS product
    WHERE product.workspace_id = v_workspace ORDER BY product.id
  LOOP
    v_product_count := v_product_count + 1;
    SELECT jsonb_build_object('version', cursor_row.schedule_version,
      'watermark', cursor_row.history_watermark)
      INTO v_before_cursor
      FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_row;
    IF v_before_cursor IS NULL THEN RAISE EXCEPTION 'Authorized schedule cursor was unavailable.'; END IF;

    v_cursor := NULL;
    v_previous_at := NULL;
    v_previous_id := NULL;
    v_iteration := 0;
    LOOP
      v_iteration := v_iteration + 1;
      IF v_iteration > 60 THEN RAISE EXCEPTION 'Legacy history pagination did not terminate.'; END IF;
      v_result := public.list_product_change_history(v_workspace, v_product, v_actor, 2,
        CASE WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb THEN NULL
          ELSE (v_cursor->>'occurredAt')::timestamptz END,
        CASE WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb THEN NULL
          ELSE v_cursor->>'eventId' END);
      IF v_result->>'status' IS DISTINCT FROM 'ok' THEN
        RAISE EXCEPTION 'Authorized legacy history read failed.';
      END IF;
      v_page := v_result->'events';
      IF jsonb_typeof(v_page) IS DISTINCT FROM 'array' OR jsonb_array_length(v_page) > 2 THEN
        RAISE EXCEPTION 'Legacy history pagination exceeded its page size.';
      END IF;
      FOR v_event IN SELECT value FROM jsonb_array_elements(v_page) AS row(value) LOOP
        v_event_count := v_event_count + 1;
        v_current_at := (v_event->>'occurredAt')::timestamptz;
        v_current_id := v_event->>'id';
        IF v_current_id IS NULL OR v_event->>'actorId' IS NULL OR
           jsonb_typeof(v_event->'details') IS DISTINCT FROM 'array' OR
           jsonb_typeof(v_event->'affectedItems') IS DISTINCT FROM 'array' OR
           v_current_id LIKE 'operation:%' OR v_event->>'operationId' IS NOT NULL THEN
          RAISE EXCEPTION 'Legacy event identity, details, or attribution differs.';
        END IF;
        IF v_previous_at IS NOT NULL AND
           (v_previous_at < v_current_at OR
             (v_previous_at = v_current_at AND v_previous_id COLLATE "C" < v_current_id COLLATE "C")) THEN
          RAISE EXCEPTION 'Legacy event ordering is not deterministic newest-first.';
        END IF;
        IF v_previous_at = v_current_at THEN v_same_timestamp_count := v_same_timestamp_count + 1; END IF;
        v_previous_at := v_current_at;
        v_previous_id := v_current_id;

        IF v_event->>'eventType' = 'calendar_reschedule_reversed' THEN
          IF v_event->'before'->>'originalOperationId' IS NULL OR
             v_event->'after'->>'originalOperationId' IS NULL OR
             v_event->'before'->>'originalOperationId' IS DISTINCT FROM
               v_event->'after'->>'originalOperationId' THEN
            RAISE EXCEPTION 'Legacy reversal lineage was not preserved.';
          END IF;
          v_reversal_count := v_reversal_count + 1;
        ELSIF v_event->>'eventType' = 'schedule_hierarchy_deleted' THEN
          IF v_event->'after'->>'targetId' IS NULL OR
             jsonb_typeof(v_event->'affectedItems') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'Legacy deletion identity or affected items were lost.';
          END IF;
          v_deletion_count := v_deletion_count + 1;
        ELSIF v_event->>'eventType' = 'stage_dates_changed' THEN
          v_stage_date_count := v_stage_date_count + 1;
        ELSIF v_event->>'eventType' = 'business_target_date_changed' THEN
          v_target_date_count := v_target_date_count + 1;
        ELSIF v_event->>'eventType' = 'hierarchy_moved' THEN
          v_hierarchy_count := v_hierarchy_count + 1;
        ELSIF v_event->>'eventType' = 'activity_dates_changed' THEN
          v_activity_date_count := v_activity_date_count + 1;
        END IF;
      END LOOP;
      v_cursor := v_result->'nextCursor';
      EXIT WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb;
      IF jsonb_typeof(v_cursor) IS DISTINCT FROM 'object' OR
         v_cursor->>'eventId' IS DISTINCT FROM v_previous_id OR
         (v_cursor->>'occurredAt')::timestamptz IS DISTINCT FROM v_previous_at THEN
        RAISE EXCEPTION 'History cursor did not point to the final page event.';
      END IF;
    END LOOP;

    SELECT jsonb_build_object('version', cursor_row.schedule_version,
      'watermark', cursor_row.history_watermark)
      INTO v_after_cursor
      FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_row;
    IF v_after_cursor IS DISTINCT FROM v_before_cursor THEN
      RAISE EXCEPTION 'A history read advanced the Living Schedule cursor.';
    END IF;
  END LOOP;

  IF v_product_count = 0 OR v_event_count = 0 OR v_reversal_count = 0 OR v_deletion_count = 0 OR
     v_stage_date_count = 0 OR v_target_date_count = 0 OR v_hierarchy_count = 0 OR
     v_activity_date_count = 0 THEN
    RAISE EXCEPTION 'Development legacy fixtures did not cover expected specialized event types.';
  END IF;
  RAISE NOTICE 'Legacy pages passed: products %, events %, timestamp ties %, reversals %, deletions %.',
    v_product_count, v_event_count, v_same_timestamp_count, v_reversal_count, v_deletion_count;
END;
$legacy_history$;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $synthetic_history$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_operation uuid := gen_random_uuid();
  v_product uuid;
  v_stage_code text := 'H' || left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_marker text := 'P1.1-0032 synthetic ' || gen_random_uuid()::text;
  v_payload jsonb;
  v_result jsonb;
  v_page jsonb;
  v_event jsonb;
  v_detail jsonb;
  v_cursor_before jsonb;
  v_cursor_after jsonb;
  v_source_types jsonb;
  v_product_specialized_count integer := 0;
  v_import_specialized_count integer := 0;
  v_generic_discipline_count integer := 0;
  v_generic_stage_count integer := 0;
  v_detail_count integer := 0;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     has_table_privilege(current_user, 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'SELECT') OR
     has_function_privilege(current_user,
       'public.link_product_schedule_history_provenance()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Worker identity or generic audit privilege boundary differs from the approved Development contract.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id
    LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Rollback-only import verification requires an active Development administrator.';
  END IF;

  v_payload := jsonb_build_object(
    'productName', v_marker,
    'sourceFilename', 'phase1.1-synthetic.xlsx',
    'disciplines', jsonb_build_array(jsonb_build_object(
      'name', 'Synthetic history discipline',
      'shortCode', 'D1',
      'color', '#336699',
      'displayOrder', 0,
      'stages', jsonb_build_array(jsonb_build_object(
        'code', v_stage_code,
        'color', '#336699',
        'displayName', 'Synthetic history stage',
        'displayOrder', 0,
        'activities', '[]'::jsonb
      ))
    )),
    'sourceMeta', '[]'::jsonb,
    'targets', '[]'::jsonb
  );

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_imported', true);
  PERFORM set_config('jlproject.schedule_justification', 'Rollback-only unified history import verification', true);
  v_result := public.import_initial_schedule(v_workspace, v_actor, gen_random_uuid(),
    md5('source:' || gen_random_uuid()::text) || md5('source-2:' || gen_random_uuid()::text),
    md5('request:' || gen_random_uuid()::text) || md5('request-2:' || gen_random_uuid()::text),
    v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'created' OR
     v_result->>'productId' IS NULL OR v_result->>'revisionId' IS NULL OR
     v_result->>'revisionLabel' IS DISTINCT FROM 'R00' THEN
    RAISE EXCEPTION 'Synthetic import did not create a product and R00 snapshot.';
  END IF;
  v_product := (v_result->>'productId')::uuid;

  SET CONSTRAINTS ALL IMMEDIATE;

  SELECT jsonb_build_object('version', cursor_row.schedule_version,
    'watermark', cursor_row.history_watermark)
    INTO v_cursor_before
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_row;
  IF v_cursor_before->>'version' <> '1' OR (v_cursor_before->>'watermark')::bigint < 1 THEN
    RAISE EXCEPTION 'Import did not create one audited operation and a positive history watermark.';
  END IF;

  v_page := public.list_product_change_history(v_workspace, v_product, v_actor, 1, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_array_length(COALESCE(v_page->'events', '[]'::jsonb)) <> 1 THEN
    RAISE EXCEPTION 'Unified history did not return the imported logical operation as one page item.';
  END IF;
  v_event := v_page->'events'->0;
  IF v_event->>'id' IS DISTINCT FROM 'operation:' || v_operation::text OR
     v_event->>'operationId' IS DISTINCT FROM v_operation::text OR
     v_event->>'eventType' IS DISTINCT FROM 'living_schedule_operation' OR
     v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_event->>'operationType' IS DISTINCT FROM 'schedule_imported' OR
     v_event->>'justification' IS DISTINCT FROM 'Rollback-only unified history import verification' OR
     jsonb_typeof(v_event->'details') IS DISTINCT FROM 'array' OR
     jsonb_typeof(v_event->'affectedItems') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Imported operation identity, grouping, actor, reason, or details are incorrect.';
  END IF;

  v_source_types := v_event->'sourceEventTypes';
  IF NOT (v_source_types @> '["product_created"]'::jsonb) OR
     NOT (v_source_types @> '["schedule_imported"]'::jsonb) OR
     NOT (v_source_types @> '["living_schedule_operation"]'::jsonb) THEN
    RAISE EXCEPTION 'Product creation, import, and generic audit event types were not grouped together.';
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(v_event->'details') LOOP
    v_detail_count := v_detail_count + 1;
    IF v_detail->>'source' = 'specialized' AND v_detail->>'eventType' = 'product_created' THEN
      v_product_specialized_count := v_product_specialized_count + 1;
    ELSIF v_detail->>'source' = 'specialized' AND v_detail->>'eventType' = 'schedule_imported' THEN
      v_import_specialized_count := v_import_specialized_count + 1;
    ELSIF v_detail->>'source' = 'living_schedule' AND
       v_detail->>'entityType' = 'product_disciplines' THEN
      v_generic_discipline_count := v_generic_discipline_count + 1;
    ELSIF v_detail->>'source' = 'living_schedule' AND
       v_detail->>'entityType' = 'discipline_stages' THEN
      v_generic_stage_count := v_generic_stage_count + 1;
    END IF;
  END LOOP;

  IF v_detail_count < 4 OR v_product_specialized_count <> 1 OR
     v_import_specialized_count <> 1 OR v_generic_discipline_count <> 1 OR
     v_generic_stage_count <> 1 OR v_page->'nextCursor' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Grouped import provenance or complete-operation page boundary is incorrect.';
  END IF;

  SELECT jsonb_build_object('version', cursor_row.schedule_version,
    'watermark', cursor_row.history_watermark)
    INTO v_cursor_after
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_row;
  IF v_cursor_after IS DISTINCT FROM v_cursor_before THEN
    RAISE EXCEPTION 'Reading imported history changed its schedule version or watermark.';
  END IF;

  v_page := public.list_product_change_history(
    gen_random_uuid(), v_product, v_actor, 25, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'Unified history did not deny a foreign workspace request.';
  END IF;

  RAISE NOTICE 'Synthetic import history passed: one operation group, % details, product/import provenance, R00 creation, workspace denial.',
    v_detail_count;
END;
$synthetic_history$;

ROLLBACK;
