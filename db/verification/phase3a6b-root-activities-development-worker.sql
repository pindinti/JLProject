-- Rollback-only synthetic verification for Phase 3A.6b.
-- Run as jlproject_worker on the independently verified JLProject Development branch.
BEGIN;

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_clone uuid;
  v_source_r00 uuid;
  v_clone_r00 uuid;
  v_discipline uuid;
  v_definition uuid;
  v_stage uuid;
  v_root_working uuid;
  v_root_manual uuid;
  v_stage_activity uuid;
  v_calendar bigint;
  v_next_calendar bigint;
  v_calendar_batch uuid;
  v_start date := DATE '2030-03-04';
  v_calendar_result jsonb;
  v_result jsonb;
  v_preview jsonb;
  v_clone_result jsonb;
  v_snapshot jsonb;
  v_source_snapshot jsonb;
  v_history_cursor jsonb;
  v_history_page jsonb;
  v_history_text text;
  v_product_row record;
  v_reason text := 'Synthetic root activity verification only';
  v_activity_hash_before text;
  v_activity_hash_after text;
  v_date_audit_hash_before text;
  v_date_audit_hash_after text;
  v_history_hash_before text;
  v_history_hash_after text;
  v_r00_hash_before text;
  v_r00_hash_after text;
  v_error_seen boolean;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'Verification must run as the limited Worker on JLProject Development.';
  END IF;
  IF NOT has_function_privilege(current_user,
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'INSERT') OR
     has_table_privilege(current_user, 'public.stage_activities', 'UPDATE') OR
     has_table_privilege(current_user, 'public.stage_activities', 'DELETE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_mode', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'working_day_duration', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planning_calendar_version', 'INSERT') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege(current_user, 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     pg_has_role(current_user, 'jlproject_date_executor', 'member') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Worker or date-executor permissions are broader than approved.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
  FROM public.workspace_memberships AS membership
  JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
  WHERE workspace.name = 'JLProject' AND membership.active AND membership.role = 'admin'
  ORDER BY membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'An active JLProject Development administrator is required.'; END IF;

  SELECT md5(COALESCE(string_agg(to_jsonb(activity)::text, '|' ORDER BY activity.id), ''))
    INTO v_activity_hash_before FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace;
  SELECT md5(COALESCE(string_agg(to_jsonb(change)::text, '|' ORDER BY change.operation_id), ''))
    INTO v_date_audit_hash_before FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace;
  v_history_text := '';
  FOR v_product_row IN SELECT product.id FROM public.products AS product
    WHERE product.workspace_id = v_workspace ORDER BY product.id
  LOOP
    v_history_cursor := NULL;
    LOOP
      v_history_page := public.list_product_change_history(v_workspace, v_product_row.id,
        v_actor, 100,
        CASE WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb THEN NULL
          ELSE (v_history_cursor->>'occurredAt')::timestamptz END,
        CASE WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb THEN NULL
          ELSE v_history_cursor->>'eventId' END);
      IF v_history_page->>'status' <> 'ok' THEN
        RAISE EXCEPTION 'Unable to read existing product history for preservation check.';
      END IF;
      v_history_text := v_history_text || v_product_row.id::text || ':' ||
        COALESCE((v_history_page->'events')::text, '[]') || '|';
      v_history_cursor := v_history_page->'nextCursor';
      EXIT WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb;
    END LOOP;
  END LOOP;
  v_history_hash_before := md5(v_history_text);
  SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text, '|' ORDER BY revision.id), ''))
    INTO v_r00_hash_before FROM public.initial_schedule_revisions AS revision
    WHERE revision.workspace_id = v_workspace;
  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar;
  WHILE EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
      WHERE exception.workspace_id = v_workspace AND exception.removed_at IS NULL
        AND exception.start_date <= v_start + 3 AND exception.end_date >= v_start) LOOP
    v_start := v_start + 7;
  END LOOP;

  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
  VALUES (v_workspace, 'Synthetic root activity ' || replace(gen_random_uuid()::text, '-', ''),
    'Rollback-only root activity verification', v_actor, v_actor)
  RETURNING id INTO v_product;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, 'Synthetic stage discipline',
    'R' || left(replace(gen_random_uuid()::text, '-', ''), 10), '#334455', 0, v_actor, v_actor)
  RETURNING id INTO v_discipline;
  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace, 'R' || left(replace(gen_random_uuid()::text, '-', ''), 10), '#556677')
  RETURNING id INTO v_definition;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, v_discipline, v_definition, 'Synthetic stage', 0, v_actor, v_actor)
  RETURNING id INTO v_stage;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    NULL, NULL, v_actor, 'Synthetic root working plan', NULL, v_start, v_start + 1,
    0, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Root working-day activity creation failed.'; END IF;
  v_root_working := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    v_discipline, v_stage, v_actor, 'Synthetic stage working plan', NULL, v_start, v_start + 1,
    0, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Stage working-day activity creation failed.'; END IF;
  v_stage_activity := (v_result->>'id')::uuid;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
  VALUES (v_workspace, v_product, NULL, NULL, 'Synthetic default-color root activity',
    v_start, v_start + 1, 1, v_actor, v_actor)
  RETURNING id INTO v_root_manual;
  UPDATE public.stage_activities SET color_override = '#123456', version = version + 1,
    updated_by = v_actor, updated_at = clock_timestamp()
  WHERE workspace_id = v_workspace AND product_id = v_product AND id = v_root_working AND version = 1;

  -- Reject mixed parent pairs and a root row with a foreign direct product scope.
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, v_product, NULL, v_stage, 'Invalid mixed-parent activity', 2, v_actor, v_actor);
  EXCEPTION WHEN check_violation THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Mixed root/stage parent pair was accepted.'; END IF;
  v_error_seen := false;
  BEGIN
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name, display_order, created_by, updated_by)
    VALUES (v_workspace, gen_random_uuid(), NULL, NULL, 'Invalid product scope', 2, v_actor, v_actor);
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN v_error_seen := true;
  END;
  IF NOT v_error_seen THEN RAISE EXCEPTION 'Activity without a direct product/workspace owner was accepted.'; END IF;

  -- Date changes through the same guarded function must create nullable-parent audit rows.
  v_result := public.change_activity_planning(v_workspace, v_product, NULL, NULL,
    v_root_working, v_actor, gen_random_uuid(), 'working_days', v_start + 1,
    v_start + 2, 2, v_calendar, v_reason, 2);
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id = v_product
      AND change.activity_id = v_root_working AND change.discipline_id IS NULL
      AND change.stage_id IS NULL AND change.previous_start = v_start
      AND change.new_start = v_start + 1 AND change.version_after = 3
  ) THEN RAISE EXCEPTION 'Root date audit did not persist with a NULL parent pair.'; END IF;
  v_result := public.change_activity_planning(v_workspace, v_product, v_discipline, v_stage,
    v_stage_activity, v_actor, gen_random_uuid(), 'working_days', v_start + 1,
    v_start + 2, 2, v_calendar, v_reason, 1);
  IF v_result->>'status' <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id = v_product
      AND change.activity_id = v_stage_activity AND change.discipline_id = v_discipline
      AND change.stage_id = v_stage AND change.version_after = 2
  ) THEN RAISE EXCEPTION 'Stage date audit behavior changed.'; END IF;

  v_result := public.change_activity_planning(v_workspace, v_product, NULL, NULL,
    v_root_working, v_actor, gen_random_uuid(), 'working_days', v_start + 2,
    v_start + 3, 2, v_calendar, v_reason, 1);
  IF v_result->>'status' <> 'stale' THEN RAISE EXCEPTION 'Stale root activity version was accepted.'; END IF;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product,
    NULL, NULL, gen_random_uuid(), 'Synthetic denied root', NULL, v_start, v_start + 1,
    3, NULL, 2, v_calendar);
  IF v_result->>'status' <> 'forbidden' THEN RAISE EXCEPTION 'Unqualified actor created a root activity.'; END IF;
  IF (public.preview_schedule_deletion(gen_random_uuid(), v_product, v_actor,
      'activity', v_root_working)->>'status') <> 'forbidden' OR
     (public.preview_schedule_deletion(v_workspace, gen_random_uuid(), v_actor,
      'activity', v_root_working)->>'status') <> 'not_found' THEN
    RAISE EXCEPTION 'Workspace or product isolation failed for root activity operations.';
  END IF;

  v_source_snapshot := jsonb_build_object(
    'product', jsonb_build_object('id', v_product, 'name', 'Synthetic root source'),
    'rootActivities', '[]'::jsonb, 'disciplines', '[]'::jsonb,
    'sourceMeta', '[]'::jsonb, 'targets', '[]'::jsonb,
    'actualStageColors', '{}'::jsonb, 'disciplineIds', '{}'::jsonb,
    'stageIds', '[]'::jsonb, 'activityIds', '{}'::jsonb, 'dependencies', '[]'::jsonb);
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (v_workspace, v_product, NULL, v_source_snapshot, v_actor)
  RETURNING id INTO v_source_r00;
  v_clone_result := public.clone_product(v_workspace, v_product, v_actor,
    'Synthetic root clone ' || replace(gen_random_uuid()::text, '-', ''));
  IF v_clone_result->>'status' <> 'cloned' THEN RAISE EXCEPTION 'Synthetic product clone failed.'; END IF;
  v_clone := (v_clone_result->'product'->>'id')::uuid;
  v_clone_r00 := (v_clone_result->>'revisionId')::uuid;
  SELECT snapshot INTO v_snapshot FROM public.initial_schedule_revisions
    WHERE workspace_id = v_workspace AND product_id = v_clone
      AND id = v_clone_r00 AND label = 'R00' AND import_batch_id IS NULL;
  IF v_snapshot IS NULL OR v_clone = v_product OR v_clone_r00 = v_source_r00 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE product_id = v_clone) <> 1 OR
     jsonb_array_length(v_snapshot->'rootActivities') <> 2 OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_clone AND discipline_id IS NULL AND stage_id IS NULL) <> 2 OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_clone AND discipline_id IS NOT NULL AND stage_id IS NOT NULL) <> 1 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities AS source
       JOIN public.stage_activities AS clone ON clone.workspace_id = v_workspace
         AND clone.product_id = v_clone AND clone.name = source.name
       WHERE source.workspace_id = v_workspace AND source.product_id = v_product
         AND source.id = v_root_working AND clone.id <> source.id
         AND clone.color_override = '#123456' AND clone.planning_mode = 'working_days'
         AND clone.working_day_duration = 2 AND clone.planning_calendar_version = v_calendar) OR
     NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot->'rootActivities') AS root
       WHERE root->>'effectiveColor' = '#8D9A89' AND root->'colorOverride' = 'null'::jsonb) OR
     (SELECT snapshot FROM public.initial_schedule_revisions WHERE id = v_source_r00)
       IS DISTINCT FROM v_source_snapshot THEN
    RAISE EXCEPTION 'Root activity clone or independent R00 baseline failed.';
  END IF;

  v_calendar_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback root schedule closure', v_start + 2, v_start + 2);
  IF v_calendar_result->>'status' <> 'created' THEN RAISE EXCEPTION 'Synthetic calendar change failed.'; END IF;
  v_next_calendar := (v_calendar_result->>'version')::bigint;
  v_calendar_batch := gen_random_uuid();
  v_result := public.apply_calendar_reschedule(v_workspace, v_product, v_actor, v_calendar_batch,
    v_next_calendar, v_reason, jsonb_build_array(
      jsonb_build_object('activityId', v_root_working, 'disciplineId', NULL, 'stageId', NULL,
        'expectedVersion', 3, 'startDate', v_start + 1, 'currentEndDate', v_start + 2,
        'proposedEndDate', v_start + 3, 'workingDays', 2, 'savedCalendarVersion', v_calendar),
      jsonb_build_object('activityId', v_stage_activity, 'disciplineId', v_discipline, 'stageId', v_stage,
        'expectedVersion', 2, 'startDate', v_start + 1, 'currentEndDate', v_start + 2,
        'proposedEndDate', v_start + 3, 'workingDays', 2, 'savedCalendarVersion', v_calendar)));
  IF v_result->>'status' <> 'updated' OR (v_result->>'count')::integer <> 2 THEN
    RAISE EXCEPTION 'Calendar rescheduling did not update root and stage activities atomically.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_calendar_batch, gen_random_uuid(), v_reason);
  IF v_result->>'status' <> 'reversed' OR (v_result->>'count')::integer <> 2 OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_root_working
       AND discipline_id IS NULL AND stage_id IS NULL AND planned_end = v_start + 2) OR
     NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity
       AND discipline_id = v_discipline AND stage_id = v_stage AND planned_end = v_start + 2) THEN
    RAISE EXCEPTION 'Calendar reversal failed for root or stage activity.';
  END IF;

  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_root_manual);
  IF v_preview->>'status' <> 'ok' OR (v_preview->'counts'->>'activities')::integer <> 1 THEN
    RAISE EXCEPTION 'Root soft-delete preview omitted the root activity.';
  END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, gen_random_uuid(),
    'activity', v_root_manual, v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' <> 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_root_manual AND deleted_at IS NOT NULL
      AND discipline_id IS NULL AND stage_id IS NULL
  ) THEN RAISE EXCEPTION 'Root soft deletion failed.'; END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor, 'stage', v_stage);
  IF v_preview->>'status' <> 'ok' OR (v_preview->'counts'->>'activities')::integer <> 1 THEN
    RAISE EXCEPTION 'Stage soft-delete behavior changed or included root activities.';
  END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, gen_random_uuid(),
    'stage', v_stage, v_preview->>'fingerprint', v_reason);
  IF v_result->>'status' <> 'deleted' OR NOT EXISTS (
    SELECT 1 FROM public.stage_activities WHERE id = v_stage_activity AND deleted_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Stage activity soft deletion failed.'; END IF;

  v_result := public.list_product_change_history(v_workspace, v_product, v_actor, 100, NULL, NULL);
  IF v_result->>'status' <> 'ok' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'events') AS event
    WHERE event->>'eventType' = 'activity_dates_changed'
      AND event->'item'->>'id' = v_root_working::text
      AND event->'item'->'hierarchy'->>'discipline' IS NULL
      AND event->'item'->'hierarchy'->>'stage' IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'events') AS event
    WHERE event->>'eventType' = 'schedule_hierarchy_deleted'
      AND event->'item'->>'id' = v_root_manual::text
  ) THEN RAISE EXCEPTION 'Product history omitted root activity events.'; END IF;

  SELECT md5(COALESCE(string_agg(to_jsonb(activity)::text, '|' ORDER BY activity.id), ''))
    INTO v_activity_hash_after FROM public.stage_activities AS activity
    WHERE activity.workspace_id = v_workspace AND activity.product_id NOT IN (v_product, v_clone);
  SELECT md5(COALESCE(string_agg(to_jsonb(change)::text, '|' ORDER BY change.operation_id), ''))
    INTO v_date_audit_hash_after FROM public.activity_date_changes AS change
    WHERE change.workspace_id = v_workspace AND change.product_id <> v_product;
  v_history_text := '';
  FOR v_product_row IN SELECT product.id FROM public.products AS product
    WHERE product.workspace_id = v_workspace AND product.id NOT IN (v_product, v_clone)
    ORDER BY product.id
  LOOP
    v_history_cursor := NULL;
    LOOP
      v_history_page := public.list_product_change_history(v_workspace, v_product_row.id,
        v_actor, 100,
        CASE WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb THEN NULL
          ELSE (v_history_cursor->>'occurredAt')::timestamptz END,
        CASE WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb THEN NULL
          ELSE v_history_cursor->>'eventId' END);
      IF v_history_page->>'status' <> 'ok' THEN
        RAISE EXCEPTION 'Unable to re-read existing product history for preservation check.';
      END IF;
      v_history_text := v_history_text || v_product_row.id::text || ':' ||
        COALESCE((v_history_page->'events')::text, '[]') || '|';
      v_history_cursor := v_history_page->'nextCursor';
      EXIT WHEN v_history_cursor IS NULL OR v_history_cursor = 'null'::jsonb;
    END LOOP;
  END LOOP;
  v_history_hash_after := md5(v_history_text);
  SELECT md5(COALESCE(string_agg(to_jsonb(revision)::text, '|' ORDER BY revision.id), ''))
    INTO v_r00_hash_after FROM public.initial_schedule_revisions AS revision
    WHERE revision.workspace_id = v_workspace AND revision.product_id NOT IN (v_product, v_clone);
  IF v_activity_hash_after <> v_activity_hash_before OR
     v_date_audit_hash_after <> v_date_audit_hash_before OR
     v_history_hash_after <> v_history_hash_before OR v_r00_hash_after <> v_r00_hash_before OR
     (SELECT snapshot FROM public.initial_schedule_revisions WHERE id = v_source_r00)
       IS DISTINCT FROM v_source_snapshot THEN
    RAISE EXCEPTION 'Existing workspace activities, audit records, or R00 snapshots changed.';
  END IF;
  RAISE NOTICE 'Root/stage parent pairs, direct scope, working plans, date audits, calendar apply/reversal, deletion, history, cloning, R00 independence, and limited Worker grants passed.';
END;
$$;

ROLLBACK;
