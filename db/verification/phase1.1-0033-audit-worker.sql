-- Rollback-only integration coverage for Living Schedule migration 0030.
-- Run against the verified Development branch as jlproject_worker after separate authorization and application.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $phase1_test$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_operation uuid := gen_random_uuid();
  v_product uuid;
  v_discipline uuid;
  v_other_discipline uuid;
  v_stage uuid;
  v_partial_stage uuid;
  v_legacy_stage uuid;
  v_definition uuid;
  v_partial_definition uuid;
  v_legacy_definition uuid;
  v_activity_a uuid;
  v_activity_b uuid;
  v_activity_c uuid;
  v_activity_without_dates uuid;
  v_target uuid;
  v_product_name text := 'P1-0030 synthetic ' || gen_random_uuid()::text;
  v_code text := 'P1' || left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_code_partial text := 'P1' || left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_code_legacy text := 'P1' || left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_result jsonb;
  v_preview jsonb;
  v_event_details jsonb;
  v_source_links jsonb;
  v_product_history jsonb;
  v_source_order jsonb;
  v_schedule_version bigint;
  v_stage_test_version bigint;
  v_history_watermark bigint;
  v_before_events integer;
  v_after_events integer;
  v_before_stage_history integer;
  v_after_stage_history integer;
  v_duplicate_events integer;
  v_operation_rows integer;
  v_stage_date_events integer;
  v_distinct_stage_event_ids integer;
  v_generic_detail_events integer;
  v_distinct_generic_event_ids integer;
  v_exact_stage_links integer;
  v_calendar_detail_links integer;
  v_calendar_detail_event_ids integer;
  v_calendar_reversal_links integer;
  v_calendar_reversal_event_ids integer;
  v_calendar_activity_links integer;
  v_calendar_activity_event_ids integer;
  v_reversal_of_links integer;
  v_reversal_of_event_ids integer;
  v_denied boolean;
  v_reason text := 'P1-0030 rollback-only verification';
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_attribute
       WHERE attrelid = 'public.stage_date_changes'::regclass
         AND attname = 'event_id' AND NOT attisdropped AND attnotnull) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_pkey' AND contype = 'p'
         AND pg_get_constraintdef(oid, true) = 'PRIMARY KEY (event_id)') OR
     position('change.event_id' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     NOT has_function_privilege(current_user,
       'public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.update_business_target(uuid,uuid,uuid,uuid,uuid,text,text,text,date,bigint,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.read_product_schedule_cursor(uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_links', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'INSERT') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'UPDATE') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'DELETE') OR
     has_table_privilege(current_user, 'public.product_schedule_operation_source_events', 'TRUNCATE') OR
     has_table_privilege(current_user, 'public.product_schedule_state', 'UPDATE') OR
     has_function_privilege(current_user,
       'public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)', 'EXECUTE') OR
     has_function_privilege(current_user,
       'public.link_product_schedule_operation_source_events()', 'EXECUTE') OR
     has_function_privilege(current_user,
       'public.link_product_schedule_audit_source()', 'EXECUTE') OR
     has_function_privilege(current_user,
       'public.delete_business_target(uuid,uuid,uuid,uuid,uuid,bigint)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Worker privilege boundary or required operation grants differ from the approved Development contract.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id
    LIMIT 1;
  IF v_workspace IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'Rollback-only integration requires an active Development administrator.';
  END IF;

  -- One synthetic product operation exercises direct writes and controlled
  -- stage/activity/target/hierarchy/deletion operations under one stable ID.
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_created', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, v_product_name, v_actor, v_actor)
    RETURNING id INTO v_product;

  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, 'P1 synthetic discipline', 'P1A', '#335577', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, 'P1 synthetic destination', 'P1B', '#557733', 1, v_actor, v_actor)
    RETURNING id INTO v_other_discipline;

  PERFORM set_config('jlproject.schedule_operation_type', 'stage_created_with_dates', true);
  v_result := jsonb_build_object('id', public.create_discipline_stage_with_dates(
    v_workspace, v_product, v_discipline, v_actor, v_operation, v_code, '#335577',
    'Explicit date stage', 0, DATE '2030-01-07', DATE '2030-01-11', v_reason));
  IF v_result->>'id' IS NULL THEN RAISE EXCEPTION 'Full planned stage creation failed.'; END IF;
  v_stage := (v_result->>'id')::uuid;
  IF EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_product AND stage_id = v_stage) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE id = v_stage
       AND planned_start = DATE '2030-01-07' AND planned_end = DATE '2030-01-11') THEN
    RAISE EXCEPTION 'A full planned stage without activities was not preserved.';
  END IF;

  v_result := jsonb_build_object('id', public.create_discipline_stage_with_dates(
    v_workspace, v_product, v_discipline, v_actor, v_operation, v_code_partial, '#446688',
    'Partial date stage', 1, DATE '2030-01-12', NULL, v_reason));
  IF v_result->>'id' IS NULL THEN RAISE EXCEPTION 'Partial planned stage creation failed.'; END IF;
  v_partial_stage := (v_result->>'id')::uuid;
  IF EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_product AND stage_id = v_partial_stage) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE id = v_partial_stage
       AND planned_start = DATE '2030-01-12' AND planned_end IS NULL) THEN
    RAISE EXCEPTION 'A partial planned stage without activities was not preserved.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_entity_created', true);
  v_result := jsonb_build_object('id', public.create_discipline_stage(
    v_workspace, v_product, v_discipline, v_actor, v_code_legacy, '#668844',
    'Legacy derived stage', 2));
  v_legacy_stage := (v_result->>'id')::uuid;
  SELECT definition.id INTO v_definition FROM public.stage_definitions AS definition
    WHERE definition.workspace_id = v_workspace AND definition.code = v_code;
  SELECT definition.id INTO v_partial_definition FROM public.stage_definitions AS definition
    WHERE definition.workspace_id = v_workspace AND definition.code = v_code_partial;
  SELECT definition.id INTO v_legacy_definition FROM public.stage_definitions AS definition
    WHERE definition.workspace_id = v_workspace AND definition.code = v_code_legacy;

  PERFORM set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true);
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_stage, 'Activity alpha',
      DATE '2030-01-07', DATE '2030-01-08', 0, v_actor, v_actor)
    RETURNING id INTO v_activity_a;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_stage, 'Activity beta',
      DATE '2030-01-08', DATE '2030-01-09', 1, v_actor, v_actor)
    RETURNING id INTO v_activity_b;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_legacy_stage, 'Legacy derived activity',
      DATE '2030-01-10', DATE '2030-01-14', 0, v_actor, v_actor)
    RETURNING id INTO v_activity_c;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_stage, 'Activity without dates',
      2, v_actor, v_actor)
    RETURNING id INTO v_activity_without_dates;
  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE id = v_legacy_stage
       AND planned_start IS NULL AND planned_end IS NULL) OR
     (SELECT min(planned_start) FROM public.stage_activities WHERE id = v_activity_c) <> DATE '2030-01-10' OR
     (SELECT max(planned_end) FROM public.stage_activities WHERE id = v_activity_c) <> DATE '2030-01-14' THEN
    RAISE EXCEPTION 'Legacy activity-derived stage boundaries changed.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'business_target_created', true);
  INSERT INTO public.business_targets
    (workspace_id, product_id, name, target_date, source_external_id, source_row,
     display_order, created_by, description, color)
    VALUES (v_workspace, v_product, 'Synthetic target', DATE '2030-02-01', 'T901', 4,
      0, v_actor, 'Before metadata update', '#336699')
    RETURNING id INTO v_target;

  PERFORM set_config('jlproject.schedule_operation_type', 'activity_dates_changed', true);
  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_activity_without_dates, v_actor, v_operation, DATE '2030-01-15', DATE '2030-01-16',
    v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Controlled activity date edit failed: %', v_result;
  END IF;
  IF public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
      v_activity_without_dates, v_actor, v_operation, DATE '2030-01-17', DATE '2030-01-18',
      v_reason, 1)->>'status' IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'A stale activity version was accepted.';
  END IF;
  IF public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
      v_activity_without_dates, gen_random_uuid(), v_operation, DATE '2030-01-17', DATE '2030-01-18',
      v_reason, 2)->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'An actor outside the workspace was accepted.';
  END IF;
  IF public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
      v_activity_without_dates, v_actor, v_operation, DATE '2030-01-18', DATE '2030-01-17',
      v_reason, 2)->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'An invalid activity interval was accepted.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'stage_dates_changed', true);
  IF public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_partial_stage,
      v_actor, v_operation, DATE '2030-01-14', NULL, v_reason, 1)->>'status'
      IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'A stale stage-date version was accepted.';
  END IF;
  -- The date-bearing creation advanced the stage row to version 2.
  IF public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_partial_stage,
      v_actor, v_operation, DATE '2030-01-14', NULL, v_reason, 2)->>'status'
      IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Controlled partial stage-date edit failed.';
  END IF;
  IF public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_partial_stage,
      v_actor, v_operation, DATE '2030-01-20', DATE '2030-01-19', v_reason, 3)->>'status'
      IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'An invalid stage interval was accepted.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'business_target_updated', true);
  IF public.update_business_target(v_workspace, v_product, v_target, v_actor, v_operation,
      'Synthetic target', 'After metadata update', '#4A7C59', DATE '2030-02-02', 1, v_reason)
      IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Controlled target update failed.';
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_metadata_updated', true);
  UPDATE public.products SET description = 'Synthetic metadata update',
    version = version + 1, updated_by = v_actor, updated_at = clock_timestamp()
    WHERE id = v_product;
  UPDATE public.product_disciplines SET name = 'Updated synthetic discipline',
    version = version + 1, updated_by = v_actor, updated_at = clock_timestamp()
    WHERE id = v_discipline;
  IF public.update_discipline_stage(v_workspace, v_product, v_discipline, v_stage, v_actor,
      v_code, '#335577', 'Updated explicit date stage', 0, 2) IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Controlled stage metadata edit failed.';
  END IF;
  UPDATE public.stage_activities SET name = 'Updated activity alpha', version = version + 1,
    updated_by = v_actor, updated_at = clock_timestamp() WHERE id = v_activity_a;

  -- A forced later error must roll back both the row write and its generic audit detail.
  SELECT operation.events INTO v_event_details
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  v_before_events := jsonb_array_length(v_event_details);
  v_denied := false;
  BEGIN
    UPDATE public.product_disciplines SET description = 'Must roll back', version = version + 1,
      updated_by = v_actor, updated_at = clock_timestamp() WHERE id = v_discipline;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Expected rollback-only sentinel.';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_denied := true;
  END;
  IF NOT v_denied OR (SELECT description FROM public.product_disciplines WHERE id = v_discipline)
      IS NOT NULL THEN
    RAISE EXCEPTION 'The forced rollback did not restore the schedule row.';
  END IF;
  SELECT operation.events INTO v_event_details
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  v_after_events := jsonb_array_length(v_event_details);
  IF v_after_events <> v_before_events THEN
    RAISE EXCEPTION 'A rolled-back mutation left generic audit details.';
  END IF;

  -- Reorder two activities and then soft-delete one through the controlled path.
  SELECT COALESCE(jsonb_agg(activity.id::text ORDER BY activity.display_order, activity.id), '[]'::jsonb)
    INTO v_source_order FROM public.stage_activities AS activity
    WHERE activity.product_id = v_product AND activity.stage_id = v_stage AND activity.deleted_at IS NULL;
  SELECT version INTO v_schedule_version FROM public.stage_activities WHERE id = v_activity_a;
  PERFORM set_config('jlproject.schedule_operation_type', 'hierarchy_moved', true);
  v_result := public.move_schedule_item(v_workspace, v_product, v_actor, v_operation,
    'activity', v_activity_a, v_schedule_version, v_discipline, v_stage, 2,
    v_source_order, v_source_order);
  IF v_result->>'status' IS DISTINCT FROM 'moved' THEN
    RAISE EXCEPTION 'Controlled hierarchy movement failed: %', v_result;
  END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_activity_b);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'Synthetic deletion preview failed: %', v_preview;
  END IF;
  PERFORM set_config('jlproject.schedule_operation_type', 'schedule_deleted', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, v_operation,
    'activity', v_activity_b, v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'deleted' OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_activity_b AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Controlled hierarchy deletion failed: %', v_result;
  END IF;

  PERFORM set_config('jlproject.schedule_operation_type', 'business_target_deleted', true);
  IF public.delete_business_target_with_reason(v_workspace, v_product, v_target, v_actor,
      v_operation, 2, v_reason) IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'The reason-bearing target delete wrapper failed.';
  END IF;

  -- Direct writes to protected paths must remain denied to the Worker.
  v_denied := false;
  BEGIN
    UPDATE public.stage_activities SET planned_start = DATE '2030-01-19'
      WHERE id = v_activity_without_dates;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Worker direct activity-date bypass succeeded.'; END IF;
  v_denied := false;
  BEGIN
    UPDATE public.product_schedule_state SET schedule_version = schedule_version + 1
      WHERE product_id = v_product;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Worker direct cursor update succeeded.'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.write_product_schedule_operation_event(
      NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::text,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text, NULL::jsonb, NULL::jsonb,
      NULL::jsonb, NULL::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Worker executed the internal audit writer directly.'; END IF;
  v_denied := false;
  BEGIN
    PERFORM public.delete_business_target(v_workspace, v_product, v_target, v_actor, v_operation, 3);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Worker executed the legacy target-delete bypass.'; END IF;

  -- A failed operation after its row and audit triggers run must leave neither
  -- schedule, specialized history, generic details, nor the cursor advanced.
  SELECT jsonb_array_length(operation.events) INTO v_before_events
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  v_product_history := public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL);
  SELECT count(*) INTO v_before_stage_history
    FROM jsonb_array_elements(COALESCE(v_product_history->'events', '[]'::jsonb)) AS history_event(value)
    WHERE history_event.value->>'eventType' = 'stage_dates_changed'
      AND history_event.value->'item'->>'operationId' = v_operation::text;
  SELECT version INTO v_stage_test_version
    FROM public.discipline_stages WHERE workspace_id = v_workspace
      AND product_id = v_product AND id = v_stage;
  BEGIN
    PERFORM set_config('jlproject.schedule_operation_type', 'stage_dates_changed', true);
    v_result := public.change_discipline_stage_dates(v_workspace, v_product, v_discipline,
      v_stage, v_actor, v_operation, DATE '2030-01-08', DATE '2030-01-11', v_reason,
      v_stage_test_version);
    IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
      RAISE EXCEPTION 'Rollback probe did not reach its post-write failure point: %', v_result;
    END IF;
    RAISE EXCEPTION 'Intentional rollback-only audit atomicity probe.' USING ERRCODE = 'P1T01';
  EXCEPTION WHEN SQLSTATE 'P1T01' THEN
    NULL;
  END;
  SELECT jsonb_array_length(operation.events) INTO v_after_events
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  v_product_history := public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL);
  SELECT count(*) INTO v_after_stage_history
    FROM jsonb_array_elements(COALESCE(v_product_history->'events', '[]'::jsonb)) AS history_event(value)
    WHERE history_event.value->>'eventType' = 'stage_dates_changed'
      AND history_event.value->'item'->>'operationId' = v_operation::text;
  IF v_after_events <> v_before_events OR
     v_after_stage_history <> v_before_stage_history OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages AS stage
       WHERE stage.workspace_id = v_workspace AND stage.product_id = v_product
         AND stage.id = v_stage AND stage.planned_start = DATE '2030-01-07'
         AND stage.planned_end = DATE '2030-01-11' AND stage.version = v_stage_test_version) OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor)) <> 1 THEN
    RAISE EXCEPTION 'Failed stage-date operation did not roll back atomically.';
  END IF;

  SELECT count(*) INTO v_operation_rows
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100);
  SELECT operation.events, operation.source_operations, operation.actor_id
    INTO v_event_details, v_source_links, v_actor
    FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100) AS operation
    WHERE operation.operation_id = v_operation;
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_stage_date_events, v_distinct_stage_event_ids
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'stage_date_changes'
      AND source.value->>'operationId' = v_operation::text
      AND source.value->>'kind' = 'audit_detail';
  SELECT count(*), count(DISTINCT source.value->>'eventId')
    INTO v_exact_stage_links, v_duplicate_events
    FROM jsonb_array_elements(v_source_links) AS source(value)
    WHERE source.value->>'ledger' = 'stage_date_changes'
      AND source.value->>'kind' = 'audit_detail'
      AND source.value->>'operationId' = v_operation::text;
  SELECT schedule_version, history_watermark INTO v_schedule_version, v_history_watermark
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_operation_rows <> 1 OR v_exact_stage_links <> 3 OR v_stage_date_events <> 3 OR
     v_distinct_stage_event_ids <> 3 OR v_duplicate_events <> 3 OR
     v_schedule_version <> 1 OR v_history_watermark <= 0 OR
     NOT EXISTS (SELECT 1 FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100)
       AS operation WHERE operation.operation_id = v_operation AND operation.actor_id = v_actor
         AND operation.justification = v_reason) THEN
    RAISE EXCEPTION 'Exactly-once cursor, operation actor, or reason attribution failed: operation rows %, stage links %, stage events %, distinct events %, expected distinct %, schedule version %, watermark %, actor/reason matched %.',
      v_operation_rows, v_exact_stage_links, v_stage_date_events, v_distinct_stage_event_ids,
      v_duplicate_events, v_schedule_version, v_history_watermark,
      EXISTS (SELECT 1 FROM public.list_product_schedule_operations(v_workspace, v_product, v_actor, NULL, 100)
        AS operation WHERE operation.operation_id = v_operation AND operation.actor_id = v_actor
          AND operation.justification = v_reason);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS link
       WHERE link->>'ledger' = 'stage_date_changes') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS link
       WHERE link->>'ledger' = 'activity_date_changes') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS link
       WHERE link->>'ledger' = 'business_target_date_changes') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS link
       WHERE link->>'ledger' = 'hierarchy_movement_events') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_source_links) AS link
       WHERE link->>'ledger' = 'schedule_deletion_events') THEN
    RAISE EXCEPTION 'Specialized audit ledgers were not linked to the grouped operation.';
  END IF;
  SELECT count(*), count(DISTINCT event->>'eventId')
    INTO v_generic_detail_events, v_distinct_generic_event_ids
    FROM jsonb_array_elements(v_event_details) AS entry(event);
  IF v_generic_detail_events <> v_distinct_generic_event_ids THEN
    RAISE EXCEPTION 'Generic audit detail event identities are not unique.';
  END IF;
  v_product_history := public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL);
  IF v_product_history->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_array_length(COALESCE(v_product_history->'events', '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'Existing specialized product history became unavailable.';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_source_links) AS source(value)
    JOIN jsonb_array_elements(v_product_history->'events') AS grouped(value)
      ON grouped.value->>'operationId' = v_operation::text
    CROSS JOIN LATERAL jsonb_array_elements(grouped.value->'details') AS detail(value)
    WHERE source.value->>'ledger' = 'stage_date_changes'
      AND source.value->>'operationId' = v_operation::text
      AND source.value->>'kind' = 'audit_detail'
      AND detail.value->>'eventId' = 'stage-date:' || (source.value->>'eventId')
      AND detail.value->>'eventType' = 'stage_dates_changed'
      AND detail.value->>'source' = 'specialized') <> 3 THEN
    RAISE EXCEPTION 'Grouped stage-date identities were not preserved in exact audit/history links.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.list_product_schedule_operations(
      gen_random_uuid(), v_product, v_actor, NULL, 100)) THEN
    RAISE EXCEPTION 'An actor read schedule operations through a mismatched workspace scope.';
  END IF;
END;
$phase1_test$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
