-- P0-A rollback-only integration check for migration 0028.
-- Run only on the authorized Development branch as jlproject_worker.
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '3min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid := gen_random_uuid();
  v_discipline uuid := gen_random_uuid();
  v_stage_id uuid;
  v_legacy_stage_id uuid;
  v_clone_product_id uuid;
  v_clone_result jsonb;
  v_result jsonb;
  v_history jsonb;
  v_clone_history jsonb;
  v_snapshot jsonb;
  v_event jsonb;
  v_create_operation uuid := gen_random_uuid();
  v_update_operation uuid := gen_random_uuid();
  v_code text := 'P0A' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  v_legacy_code text := 'P0L' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  v_stage_text text;
  v_legacy_stage_text text;
  v_duplicate_operation_rejected boolean := false;
  v_direct_stage_write_rejected boolean := false;
  v_direct_audit_read_rejected boolean := false;
  v_direct_audit_write_rejected boolean := false;
  v_event_count integer;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text)',
       'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)',
       'EXECUTE') OR
     has_column_privilege(current_user, 'public.discipline_stages', 'planned_start', 'UPDATE') OR
     has_column_privilege(current_user, 'public.discipline_stages', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_date_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.stage_date_changes', 'INSERT') OR
     has_table_privilege(current_user, 'public.stage_date_changes', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_date_changes', 'DELETE') THEN
    RAISE EXCEPTION 'Development Worker identity or stage-date privilege boundary differs.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'An active workspace administrator is required.'; END IF;

  INSERT INTO public.products (id, workspace_id, name, description, created_by, updated_by)
    VALUES (v_product, v_workspace, 'P0-A synthetic stage-date verification',
      'Rollback-only verification fixture.', v_actor, v_actor);
  INSERT INTO public.product_disciplines
    (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_discipline, v_workspace, v_product, 'Synthetic discipline',
      'P0A', '#526777', 0, v_actor, v_actor);

  -- Date-bearing creation is audited and does not require activities.
  v_stage_text := public.create_discipline_stage_with_dates(
    v_workspace, v_product, v_discipline, v_actor, v_create_operation,
    v_code, '#526777', 'Synthetic explicit stage', 0,
    DATE '2027-01-05', NULL, 'Create a partial planned stage.');
  IF v_stage_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RAISE EXCEPTION 'Date-bearing stage creation failed: %.', v_stage_text;
  END IF;
  v_stage_id := v_stage_text::uuid;
  IF EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id = v_product) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE id = v_stage_id AND planned_start = DATE '2027-01-05'
         AND planned_end IS NULL AND version = 2) THEN
    RAISE EXCEPTION 'Partial planned stage creation or zero-activity behavior failed.';
  END IF;

  -- Legacy creation with no explicit dates remains supported and does not create a date event.
  v_legacy_stage_text := public.create_discipline_stage(
    v_workspace, v_product, v_discipline, v_actor,
    v_legacy_code, '#526777', 'Synthetic legacy stage', 1);
  IF v_legacy_stage_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RAISE EXCEPTION 'Legacy null-date stage creation failed: %.', v_legacy_stage_text;
  END IF;
  v_legacy_stage_id := v_legacy_stage_text::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE id = v_legacy_stage_id AND planned_start IS NULL AND planned_end IS NULL) THEN
    RAISE EXCEPTION 'Legacy stage did not retain null planned dates.';
  END IF;

  -- Invalid complete intervals and invalid justifications are rejected without mutation.
  v_result := public.change_discipline_stage_dates(
    v_workspace, v_product, v_discipline, v_stage_id, v_actor, gen_random_uuid(),
    DATE '2027-01-11', DATE '2027-01-10', 'Reject a reversed date range.', 2);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'A reversed explicit date interval was not rejected.';
  END IF;
  v_result := public.change_discipline_stage_dates(
    v_workspace, v_product, v_discipline, v_stage_id, v_actor, gen_random_uuid(),
    DATE '2027-01-06', NULL, 'short', 2);
  IF v_result->>'status' IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'A missing change justification was not rejected.';
  END IF;

  -- Authorization and stale-version results do not change the stage.
  v_result := public.change_discipline_stage_dates(
    v_workspace, v_product, v_discipline, v_stage_id,
    '00000000-0000-4000-8000-000000000099', gen_random_uuid(),
    DATE '2027-01-06', NULL, 'Unauthorized date modification.', 2);
  IF v_result->>'status' IS DISTINCT FROM 'forbidden' THEN
    RAISE EXCEPTION 'An unauthorized actor was not rejected.';
  END IF;
  v_result := public.change_discipline_stage_dates(
    v_workspace, v_product, v_discipline, v_stage_id, v_actor, gen_random_uuid(),
    DATE '2027-01-06', NULL, 'Reject a stale version token.', 1);
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'A stale stage version was not rejected.';
  END IF;

  v_result := public.change_discipline_stage_dates(
    v_workspace, v_product, v_discipline, v_stage_id, v_actor, v_update_operation,
    DATE '2027-01-05', DATE '2027-01-10', 'Set the explicit planned end.', 2);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE id = v_stage_id AND planned_start = DATE '2027-01-05'
         AND planned_end = DATE '2027-01-10' AND version = 3) THEN
    RAISE EXCEPTION 'An authorized full-date update failed.';
  END IF;

  -- Reusing an operation ID causes the entire update and trigger audit insert to roll back.
  BEGIN
    PERFORM public.change_discipline_stage_dates(
      v_workspace, v_product, v_discipline, v_stage_id, v_actor, v_create_operation,
      DATE '2027-01-05', DATE '2027-01-12', 'Must fail atomically on duplicate operation.', 3);
  EXCEPTION WHEN unique_violation THEN
    v_duplicate_operation_rejected := true;
  END;
  IF NOT v_duplicate_operation_rejected OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages
       WHERE id = v_stage_id AND planned_end = DATE '2027-01-10' AND version = 3) THEN
    RAISE EXCEPTION 'A failed audit insert did not roll back the stage date update atomically.';
  END IF;

  -- The Worker cannot update planned columns or access the audit ledger directly.
  BEGIN
    UPDATE public.discipline_stages SET planned_end = DATE '2027-01-12' WHERE id = v_stage_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_stage_write_rejected := true;
  END;
  BEGIN
    PERFORM 1 FROM public.stage_date_changes LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_audit_read_rejected := true;
  END;
  BEGIN
    DELETE FROM public.stage_date_changes WHERE operation_id = v_create_operation;
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_audit_write_rejected := true;
  END;
  IF NOT v_direct_stage_write_rejected OR NOT v_direct_audit_read_rejected OR
     NOT v_direct_audit_write_rejected THEN
    RAISE EXCEPTION 'The Worker can bypass a controlled stage-date or audit path.';
  END IF;

  v_history := public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL);
  IF v_history->>'status' IS DISTINCT FROM 'ok' OR
     (SELECT count(*) FROM jsonb_array_elements(v_history->'events') AS event(value)
       WHERE event.value->>'eventType' = 'stage_dates_changed') <> 2 OR
     (SELECT count(*) FROM jsonb_array_elements(v_history->'events') AS event(value)
       WHERE event.value->>'eventType' = 'product_created') <> 1 THEN
    RAISE EXCEPTION 'Stage-date audit events did not integrate with existing product history.';
  END IF;
  SELECT event.value INTO v_event
    FROM jsonb_array_elements(v_history->'events') AS event(value)
    WHERE event.value->>'id' = 'stage-date:' || v_create_operation::text;
  IF v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_event->>'occurredAt' IS NULL OR
     v_event->>'justification' IS DISTINCT FROM 'Create a partial planned stage.' OR
     v_event->'before' IS DISTINCT FROM jsonb_build_object('plannedStart', NULL, 'plannedEnd', NULL) OR
     v_event->'after' IS DISTINCT FROM jsonb_build_object('plannedStart', '2027-01-05', 'plannedEnd', NULL) THEN
    RAISE EXCEPTION 'Initial stage-date event is missing its actor, UTC timestamp, justification, or values.';
  END IF;
  SELECT event.value INTO v_event
    FROM jsonb_array_elements(v_history->'events') AS event(value)
    WHERE event.value->>'id' = 'stage-date:' || v_update_operation::text;
  IF v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
     v_event->>'justification' IS DISTINCT FROM 'Set the explicit planned end.' OR
     v_event->'before' IS DISTINCT FROM jsonb_build_object('plannedStart', '2027-01-05', 'plannedEnd', NULL) OR
     v_event->'after' IS DISTINCT FROM jsonb_build_object('plannedStart', '2027-01-05', 'plannedEnd', '2027-01-10') THEN
    RAISE EXCEPTION 'Stage-date update history did not preserve previous and new values.';
  END IF;
  SELECT count(*) INTO v_event_count
    FROM jsonb_array_elements(v_history->'events') AS event(value)
    WHERE event.value->>'eventType' = 'stage_dates_changed';
  IF v_event_count <> 2 THEN RAISE EXCEPTION 'A failed atomic update left an audit event.'; END IF;

  -- Clone checks the working stage and the newly created R00 snapshot.
  v_clone_result := public.clone_product(v_workspace, v_product, v_actor,
    'P0-A synthetic clone ' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  IF v_clone_result->>'status' IS DISTINCT FROM 'cloned' THEN
    RAISE EXCEPTION 'Synthetic product clone failed: %.', v_clone_result->>'status';
  END IF;
  v_clone_product_id := (v_clone_result->'product'->>'id')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages AS stage
      WHERE stage.product_id = v_clone_product_id AND stage.display_name = 'Synthetic explicit stage'
        AND stage.planned_start = DATE '2027-01-05' AND stage.planned_end = DATE '2027-01-10') OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages AS stage
      WHERE stage.product_id = v_clone_product_id AND stage.display_name = 'Synthetic legacy stage'
        AND stage.planned_start IS NULL AND stage.planned_end IS NULL) OR
     EXISTS (SELECT 1 FROM public.stage_activities WHERE product_id IN (v_product, v_clone_product_id)) THEN
    RAISE EXCEPTION 'Product clone did not preserve planned and legacy stage values without activities.';
  END IF;
  SELECT revision.snapshot INTO STRICT v_snapshot
    FROM public.initial_schedule_revisions AS revision
    WHERE revision.id = (v_clone_result->>'revisionId')::uuid
      AND revision.product_id = v_clone_product_id;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_snapshot->'disciplines') AS discipline(value)
    CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage(value)
    WHERE stage.value->>'displayName' = 'Synthetic explicit stage'
      AND stage.value->>'plannedStart' = '2027-01-05'
      AND stage.value->>'plannedEnd' = '2027-01-10'
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_snapshot->'disciplines') AS discipline(value)
    CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage(value)
    WHERE stage.value->>'displayName' = 'Synthetic legacy stage'
      AND stage.value->'plannedStart' = 'null'::jsonb
      AND stage.value->'plannedEnd' = 'null'::jsonb
  ) THEN
    RAISE EXCEPTION 'The clone R00 snapshot does not preserve the explicit and legacy stage date states.';
  END IF;
  v_clone_history := public.list_product_change_history(
    v_workspace, v_clone_product_id, v_actor, 100, NULL, NULL);
  IF v_clone_history->>'status' IS DISTINCT FROM 'ok' OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_clone_history->'events') AS event(value)
       WHERE event.value->>'eventType' = 'product_created') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_clone_history->'events') AS event(value)
       WHERE event.value->>'eventType' = 'stage_dates_changed') THEN
    RAISE EXCEPTION 'Cloned product history did not preserve existing history compatibility.';
  END IF;

  RAISE NOTICE 'P0-A stage-date, audit, concurrency, authorization, clone, R00 and history checks passed.';
END;
$$;

ROLLBACK;
