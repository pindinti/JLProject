-- Run with jlproject_worker on the verified JLProject development branch only.
-- All synthetic products, hierarchy, schedule changes, and audit records are rolled back.
BEGIN;

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_other_product uuid;
  v_discipline uuid;
  v_stage uuid;
  v_definition uuid;
  v_manual_activity uuid;
  v_work_activity_one uuid;
  v_work_activity_two uuid;
  v_target uuid;
  v_import_batch uuid := gen_random_uuid();
  v_batch uuid := gen_random_uuid();
  v_reversal uuid := gen_random_uuid();
  v_calendar_version bigint;
  v_next_calendar_version bigint;
  v_tie timestamptz := TIMESTAMPTZ '2020-01-02 03:04:05+00';
  v_start date := DATE '2030-01-08';
  v_calendar_result jsonb;
  v_result jsonb;
  v_page jsonb;
  v_all jsonb := '[]'::jsonb;
  v_event jsonb;
  v_reschedule jsonb;
  v_reschedule_reversal jsonb;
  v_deletion jsonb;
  v_cursor jsonb;
  v_previous_at timestamptz;
  v_current_at timestamptz;
  v_previous_id text;
  v_current_id text;
  v_seen_ids text[] := ARRAY[]::text[];
  v_seen_types text[] := ARRAY[]::text[];
  v_snapshot_hash text;
  v_iteration integer := 0;
  v_rejected boolean := false;
  v_name text;
  v_source_hash text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_request_hash text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_reason text := 'Synthetic history verification only';
BEGIN
  IF current_user <> 'jlproject_worker' OR current_database() <> 'neondb' OR
     NOT has_function_privilege(current_user,
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Limited Worker and audit permissions are unexpected.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
    WHERE workspace.name = 'JLProject' AND membership.active AND membership.role = 'admin'
    ORDER BY membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'No active development administrator is available.'; END IF;

  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_version;
  WHILE EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
      WHERE exception.workspace_id = v_workspace AND exception.removed_at IS NULL
        AND exception.start_date <= v_start + 2 AND exception.end_date >= v_start) LOOP
    v_start := v_start + 7;
  END LOOP;

  v_name := 'Synthetic product history ' || replace(gen_random_uuid()::text, '-', '');
  INSERT INTO public.products (workspace_id, name, created_by, updated_by, created_at)
    VALUES (v_workspace, v_name, v_actor, v_actor, v_tie) RETURNING id INTO v_product;
  INSERT INTO public.products (workspace_id, name, created_by, updated_by, created_at)
    VALUES (v_workspace, v_name || ' isolated', v_actor, v_actor, v_tie)
    RETURNING id INTO v_other_product;

  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, 'Synthetic history discipline',
      'H' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10), '#336699', 0, v_actor, v_actor)
    RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
    VALUES (v_workspace, 'H' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10), '#557799')
    RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_definition,
      'Synthetic history stage', 0, v_actor, v_actor) RETURNING id INTO v_stage;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, v_discipline, v_stage, 'Synthetic manual activity',
      DATE '2030-02-01', DATE '2030-02-02', 0, v_actor, v_actor)
    RETURNING id INTO v_manual_activity;
  INSERT INTO public.business_targets
    (workspace_id, product_id, name, target_date, display_order, created_by)
    VALUES (v_workspace, v_product, 'Synthetic history target', DATE '2030-02-10', 0, v_actor)
    RETURNING id INTO v_target;

  INSERT INTO public.import_batches
    (workspace_id, product_id, idempotency_key, source_hash, request_hash,
     source_filename, created_by, created_at)
    VALUES (v_workspace, v_product, gen_random_uuid(), v_source_hash, v_request_hash,
      'synthetic-history.xlsx', v_actor, v_tie) RETURNING id INTO v_import_batch;
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
    VALUES (v_workspace, v_product, v_import_batch,
      jsonb_build_object('dependencies', '[]'::jsonb, 'synthetic', true), v_actor);
  INSERT INTO public.import_source_rows
    (import_batch_id, source_sheet, source_row, source_external_id, activity_id)
    VALUES (v_import_batch, 'Cronograma Produto', 4, 'T999', v_manual_activity);
  SELECT md5(snapshot::text) INTO v_snapshot_hash
    FROM public.initial_schedule_revisions WHERE product_id = v_product;

  v_result := public.change_activity_dates(v_workspace, v_product, v_discipline, v_stage,
    v_manual_activity, v_actor, gen_random_uuid(), DATE '2030-02-02', DATE '2030-02-03',
    v_reason, 1);
  IF v_result->>'status' <> 'updated' THEN RAISE EXCEPTION 'Synthetic manual date edit failed.'; END IF;
  IF public.update_business_target(v_workspace, v_product, v_target, v_actor, gen_random_uuid(),
      'Synthetic history target', NULL, '#AA4557', DATE '2030-02-11', 1, v_reason) <> 'updated' THEN
    RAISE EXCEPTION 'Synthetic target date edit failed.';
  END IF;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Synthetic reschedule activity one', NULL, v_start, v_start + 1,
    1, NULL, 2, v_calendar_version);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Synthetic working activity one failed.'; END IF;
  v_work_activity_one := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Synthetic reschedule activity two', NULL, v_start, v_start + 1,
    2, NULL, 2, v_calendar_version);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Synthetic working activity two failed.'; END IF;
  v_work_activity_two := (v_result->>'id')::uuid;

  v_calendar_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar_version, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback closure', v_start + 1, v_start + 1);
  IF v_calendar_result->>'status' <> 'created' THEN
    RAISE EXCEPTION 'Synthetic calendar version change failed.';
  END IF;
  v_next_calendar_version := (v_calendar_result->>'version')::bigint;

  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_batch,
    v_next_calendar_version, v_reason, jsonb_build_array(
      jsonb_build_object('activityId', v_work_activity_one, 'disciplineId', v_discipline,
        'stageId', v_stage, 'expectedVersion', 1, 'startDate', v_start,
        'currentEndDate', v_start + 1, 'proposedEndDate', v_start + 2,
        'workingDays', 2, 'savedCalendarVersion', v_calendar_version),
      jsonb_build_object('activityId', v_work_activity_two, 'disciplineId', v_discipline,
        'stageId', v_stage, 'expectedVersion', 1, 'startDate', v_start,
        'currentEndDate', v_start + 1, 'proposedEndDate', v_start + 2,
        'workingDays', 2, 'savedCalendarVersion', v_calendar_version)));
  IF v_result->>'status' <> 'updated' OR (v_result->>'count')::integer <> 2 THEN
    RAISE EXCEPTION 'Synthetic reschedule batch failed.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_batch, v_reversal, v_reason);
  IF v_result->>'status' <> 'reversed' OR (v_result->>'count')::integer <> 2 THEN
    RAISE EXCEPTION 'Synthetic reversal batch failed.';
  END IF;

  v_result := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_manual_activity);
  IF v_result->>'status' <> 'ok' THEN RAISE EXCEPTION 'Synthetic deletion preview failed.'; END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, gen_random_uuid(),
    'activity', v_manual_activity, v_result->>'fingerprint', v_reason);
  IF v_result->>'status' <> 'deleted' THEN RAISE EXCEPTION 'Synthetic logical deletion failed.'; END IF;

  IF (public.list_product_change_history(v_workspace, v_other_product, v_actor,
      25, NULL, NULL)->>'status') <> 'ok' OR
     jsonb_array_length(public.list_product_change_history(v_workspace, v_other_product,
      v_actor, 25, NULL, NULL)->'events') <> 1 THEN
    RAISE EXCEPTION 'Product history leaked events across products.';
  END IF;
  IF (public.list_product_change_history(gen_random_uuid(), v_product, v_actor,
      25, NULL, NULL)->>'status') <> 'forbidden' OR
     (public.list_product_change_history(v_workspace, v_product, gen_random_uuid(),
      25, NULL, NULL)->>'status') <> 'forbidden' OR
     (public.list_product_change_history(v_workspace, gen_random_uuid(), v_actor,
      25, NULL, NULL)->>'status') <> 'not_found' THEN
    RAISE EXCEPTION 'Workspace, membership, or product denial was incorrect.';
  END IF;
  IF (public.list_product_change_history(v_workspace, v_product, v_actor, 0,
      NULL, NULL)->>'status') <> 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, 25,
      NULL, 'invalid-cursor')->>'status') <> 'invalid' THEN
    RAISE EXCEPTION 'Invalid pagination input was accepted.';
  END IF;

  -- Walk every page at size two, ensuring strict stable ordering and no duplicate event IDs.
  v_cursor := NULL;
  v_previous_at := NULL;
  v_previous_id := NULL;
  LOOP
    v_iteration := v_iteration + 1;
    IF v_iteration > 20 THEN RAISE EXCEPTION 'Synthetic history pagination did not terminate.'; END IF;
    v_result := public.list_product_change_history(v_workspace, v_product, v_actor, 2,
      CASE WHEN v_cursor IS NULL THEN NULL ELSE (v_cursor->>'occurredAt')::timestamptz END,
      CASE WHEN v_cursor IS NULL THEN NULL ELSE v_cursor->>'eventId' END);
    IF v_result->>'status' <> 'ok' THEN RAISE EXCEPTION 'Synthetic history page request failed.'; END IF;
    v_page := v_result->'events';
    IF jsonb_array_length(v_page) > 2 THEN RAISE EXCEPTION 'History page exceeded its limit.'; END IF;
    FOR v_event IN SELECT value FROM jsonb_array_elements(v_page) AS page(value) LOOP
      v_current_at := (v_event->>'occurredAt')::timestamptz;
      v_current_id := v_event->>'id';
      IF v_current_id = ANY(v_seen_ids) THEN RAISE EXCEPTION 'History pagination duplicated an event.'; END IF;
      IF v_previous_at IS NOT NULL AND
         (v_previous_at < v_current_at OR
          (v_previous_at = v_current_at AND v_previous_id COLLATE "C" < v_current_id COLLATE "C")) THEN
        RAISE EXCEPTION 'History feed order is not stable newest-first.';
      END IF;
      v_seen_ids := array_append(v_seen_ids, v_current_id);
      v_seen_types := array_append(v_seen_types, v_event->>'eventType');
      v_all := v_all || jsonb_build_array(v_event);
      v_previous_at := v_current_at;
      v_previous_id := v_current_id;
    END LOOP;
    v_cursor := v_result->'nextCursor';
    EXIT WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb;
  END LOOP;

  IF NOT ('product_created' = ANY(v_seen_types)) OR
     NOT ('schedule_imported' = ANY(v_seen_types)) OR
     NOT ('activity_dates_changed' = ANY(v_seen_types)) OR
     NOT ('business_target_date_changed' = ANY(v_seen_types)) OR
     NOT ('calendar_rescheduled' = ANY(v_seen_types)) OR
     NOT ('calendar_reschedule_reversed' = ANY(v_seen_types)) OR
     NOT ('schedule_hierarchy_deleted' = ANY(v_seen_types)) THEN
    RAISE EXCEPTION 'Synthetic event type coverage is incomplete.';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'activity_dates_changed') <> 1 OR
     (SELECT (value->>'item')::jsonb->>'id' FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'activity_dates_changed') <> v_manual_activity::text THEN
    RAISE EXCEPTION 'Reschedule/reversal date audit rows were duplicated as manual events.';
  END IF;
  SELECT value INTO v_reschedule FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'calendar_rescheduled';
  SELECT value INTO v_reschedule_reversal FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'calendar_reschedule_reversed';
  IF jsonb_array_length(v_reschedule->'affectedItems') <> 2 OR
     jsonb_array_length(v_reschedule->'before'->'activities') <> 2 OR
     jsonb_array_length(v_reschedule->'after'->'activities') <> 2 OR
     jsonb_array_length(v_reschedule_reversal->'affectedItems') <> 2 THEN
    RAISE EXCEPTION 'Reschedule/reversal batches were not grouped by operation.';
  END IF;
  SELECT value INTO v_deletion FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'schedule_hierarchy_deleted';
  IF v_deletion->'item'->>'name' <> 'Synthetic manual activity' OR
     v_deletion->'item'->'hierarchy'->>'discipline' <> 'Synthetic history discipline' OR
     v_deletion->'item'->'hierarchy'->>'stage' <> 'Synthetic history stage' OR
     v_deletion->'affectedItems'->0->>'name' <> 'Synthetic manual activity' OR
     v_deletion->'affectedItems'->0->'hierarchy'->>'stage' <> 'Synthetic history stage' THEN
    RAISE EXCEPTION 'Deleted hierarchy names were not retained in authorized history.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'schedule_imported'
        AND value->'after'->>'sourceReferenceCount' = '1') OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'business_target_date_changed'
        AND value->'before'->>'targetDate' = '2030-02-10'
        AND value->'after'->>'targetDate' = '2030-02-11') THEN
    RAISE EXCEPTION 'Import provenance count or target before/after details are incorrect.';
  END IF;
  SELECT md5(snapshot::text) INTO v_name FROM public.initial_schedule_revisions
    WHERE product_id = v_product;
  IF v_name <> v_snapshot_hash THEN RAISE EXCEPTION 'Synthetic R00 snapshot changed.'; END IF;
  v_rejected := false;
  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = '{"dependencies":[]}'::jsonb
      WHERE product_id = v_product;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Worker was able to modify R00.'; END IF;

  RAISE NOTICE 'Synthetic product history scope, ordering, grouping, provenance, retained names, and R00 checks passed; transaction will roll back.';
END;
$$;

ROLLBACK;
