-- REL-03M: migration 0022 product history on the isolated rehearsal branch.
-- Run as jlproject_worker on br-snowy-wave-b6vn905p only. All writes roll back.
\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'target_audits', (SELECT count(*) FROM public.business_target_date_changes),
  'import_batches', (SELECT count(*) FROM public.import_batches),
  'import_source_rows', (SELECT count(*) FROM public.import_source_rows),
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events),
  'calendar_state', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('workspace_id', c.workspace_id, 'version', c.version,
      'updated_at', c.updated_at)::text, '|' ORDER BY c.workspace_id::text), ''))
    FROM public.workspace_calendar_versions AS c),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS baseline
\gset rel03m_
ROLLBACK;

SELECT 1 / CASE WHEN
  (:'rel03m_baseline'::jsonb->>'products')::bigint = 5 AND
  (:'rel03m_baseline'::jsonb->>'disciplines')::bigint = 19 AND
  (:'rel03m_baseline'::jsonb->>'stages')::bigint = 40 AND
  (:'rel03m_baseline'::jsonb->>'activities')::bigint = 73 AND
  (:'rel03m_baseline'::jsonb->>'r00')::bigint = 1 AND
  (:'rel03m_baseline'::jsonb->>'dates') = '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS reported_baseline_matches;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '3min';
SET LOCAL idle_in_transaction_session_timeout = '5min';

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
  v_date_operation uuid := gen_random_uuid();
  v_target_operation uuid := gen_random_uuid();
  v_deletion_operation uuid := gen_random_uuid();
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
  v_product_event jsonb;
  v_import_event jsonb;
  v_date_event jsonb;
  v_target_event jsonb;
  v_first_page jsonb;
  v_empty_page jsonb;
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
  v_calendar_attempts integer := 0;
  v_direct_read bigint;
  v_name text;
  v_source_hash text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_request_hash text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_reason text := 'Synthetic history verification only';
BEGIN
  IF current_user IS DISTINCT FROM 'jlproject_worker' OR
     current_database() IS DISTINCT FROM 'neondb' OR
     NOT has_function_privilege(current_user,
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_any_column_privilege(current_user, 'public.calendar_reschedule_changes', 'SELECT') OR
     has_any_column_privilege(current_user, 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_any_column_privilege(current_user, 'public.schedule_deletion_events', 'SELECT') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege(current_user, 'public.initial_schedule_revisions', 'DELETE') OR
     (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'jlproject_date_executor') THEN
    RAISE EXCEPTION 'Limited Worker and audit permissions are unexpected.';
  END IF;

  -- Check the actual permission boundary without returning ledger contents.
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.calendar_reschedule_changes' INTO v_direct_read;
    RAISE EXCEPTION 'Worker unexpectedly read the reschedule ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.calendar_reschedule_reversals' INTO v_direct_read;
    RAISE EXCEPTION 'Worker unexpectedly read the reversal ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.schedule_deletion_events' INTO v_direct_read;
    RAISE EXCEPTION 'Worker unexpectedly read the deletion ledger.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  IF NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'workspace_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'product_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'created_by', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'created_at', 'SELECT') OR
     has_table_privilege('jlproject_date_executor', 'public.import_batches', 'SELECT') OR
     has_column_privilege('jlproject_date_executor', 'public.import_batches', 'source_filename', 'SELECT') THEN
    RAISE EXCEPTION 'Executor import permission differs from the reviewed column grant.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal
      AND c.relname IN ('products','product_disciplines','stage_definitions',
        'discipline_stages','stage_activities','business_targets','import_batches',
        'import_source_rows','initial_schedule_revisions','workspace_calendar_versions',
        'workspace_calendar_exceptions','workspace_calendar_events',
        'activity_date_changes','business_target_date_changes',
        'calendar_reschedule_changes','calendar_reschedule_reversals',
        'schedule_deletion_events')
      AND ((t.tgtype & 4) IS DISTINCT FROM 0 OR (t.tgtype & 16) IS DISTINCT FROM 0 OR (t.tgtype & 8) IS DISTINCT FROM 0)
      AND t.tgname NOT IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard','stage_activities_deletion_guard',
        'stage_activities_dates_immutable','business_targets_audit_date_update',
        'initial_schedule_revisions_immutable','activity_date_changes_append_only',
        'business_target_date_changes_immutable','workspace_calendar_events_append_only',
        'calendar_reschedule_changes_append_only',
        'calendar_reschedule_reversals_append_only',
        'schedule_deletion_events_immutable')) THEN
    RAISE EXCEPTION 'Unreviewed trigger could have external effects.';
  END IF;

  SELECT membership.workspace_id, membership.auth_user_id
    INTO v_workspace, v_actor
    FROM public.workspace_memberships AS membership
    WHERE membership.active AND membership.role = 'admin'
    ORDER BY membership.workspace_id, membership.auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'No active administrator is available.'; END IF;

  SELECT COALESCE((SELECT version FROM public.workspace_calendar_versions
    WHERE workspace_id = v_workspace), 0) INTO v_calendar_version;
  WHILE EXISTS (SELECT 1 FROM public.workspace_calendar_exceptions AS exception
      WHERE exception.workspace_id = v_workspace AND exception.removed_at IS NULL
        AND exception.start_date <= v_start + 2 AND exception.end_date >= v_start) LOOP
    v_calendar_attempts := v_calendar_attempts + 1;
    IF v_calendar_attempts > 26 THEN
      RAISE EXCEPTION 'No clear synthetic calendar date window was found.';
    END IF;
    v_start := v_start + 7;
  END LOOP;

  v_name := 'REL03M synthetic history ' || replace(gen_random_uuid()::text, '-', '');
  IF EXISTS (SELECT 1 FROM public.products WHERE name LIKE 'REL03M synthetic history %') THEN
    RAISE EXCEPTION 'Existing REL-03M marker; inspect before testing.';
  END IF;
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
    v_manual_activity, v_actor, v_date_operation, DATE '2030-02-02', DATE '2030-02-03',
    v_reason, 1);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN RAISE EXCEPTION 'Synthetic manual date edit failed.'; END IF;
  IF public.update_business_target(v_workspace, v_product, v_target, v_actor, v_target_operation,
      'Synthetic history target', NULL, '#AA4557', DATE '2030-02-11', 1, v_reason) IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Synthetic target date edit failed.';
  END IF;

  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Synthetic reschedule activity one', NULL, v_start, v_start + 1,
    1, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Synthetic working activity one failed.'; END IF;
  v_work_activity_one := (v_result->>'id')::uuid;
  v_result := public.create_activity_with_working_plan(v_workspace, v_product, v_discipline,
    v_stage, v_actor, 'Synthetic reschedule activity two', NULL, v_start, v_start + 1,
    2, NULL, 2, v_calendar_version);
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Synthetic working activity two failed.'; END IF;
  v_work_activity_two := (v_result->>'id')::uuid;

  v_calendar_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(),
    v_calendar_version, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic rollback closure', v_start + 1, v_start + 1);
  IF v_calendar_result->>'status' IS DISTINCT FROM 'created' THEN
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
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Synthetic reschedule batch failed.';
  END IF;
  v_result := public.reverse_calendar_reschedule(v_workspace, v_product, v_actor,
    v_batch, v_reversal, v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR (v_result->>'count')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Synthetic reversal batch failed.';
  END IF;

  v_result := public.preview_schedule_deletion(v_workspace, v_product, v_actor,
    'activity', v_manual_activity);
  IF v_result->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Synthetic deletion preview failed.'; END IF;
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, v_deletion_operation,
    'activity', v_manual_activity, v_result->>'fingerprint', v_reason);
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN RAISE EXCEPTION 'Synthetic logical deletion failed.'; END IF;

  IF (public.list_product_change_history(v_workspace, v_other_product, v_actor,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'ok' OR
     jsonb_array_length(public.list_product_change_history(v_workspace, v_other_product,
      v_actor, 25, NULL, NULL)->'events') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Product history leaked events across products.';
  END IF;
  IF (public.list_product_change_history(gen_random_uuid(), v_product, v_actor,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'forbidden' OR
     (public.list_product_change_history(v_workspace, v_product, gen_random_uuid(),
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'forbidden' OR
     (public.list_product_change_history(v_workspace, gen_random_uuid(), v_actor,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Workspace, membership, or product denial was incorrect.';
  END IF;
  IF (public.list_product_change_history(NULL, v_product, v_actor,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, NULL, v_actor,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, NULL,
      25, NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Null scope was accepted.';
  END IF;
  IF (public.list_product_change_history(v_workspace, v_product, v_actor, 0,
      NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, NULL,
      NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, 101,
      NULL, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, 1,
      v_tie, NULL)->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, 25,
      v_tie, 'invalid-cursor')->>'status') IS DISTINCT FROM 'invalid' OR
     (public.list_product_change_history(v_workspace, v_product, v_actor, 25,
      NULL, 'product:' || v_product::text)->>'status') IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'Invalid pagination input was accepted.';
  END IF;

  v_first_page := public.list_product_change_history(v_workspace, v_product, v_actor,
    1, NULL, NULL);
  IF v_first_page->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_array_length(v_first_page->'events') IS DISTINCT FROM 1 OR
     jsonb_typeof(v_first_page->'nextCursor') IS DISTINCT FROM 'object' OR
     v_first_page->'nextCursor'->>'eventId' IS DISTINCT FROM
       v_first_page->'events'->0->>'id' OR
     v_first_page->'nextCursor'->>'occurredAt' IS DISTINCT FROM
       v_first_page->'events'->0->>'occurredAt' THEN
    RAISE EXCEPTION 'Limit-one page or cursor shape differs.';
  END IF;
  v_result := public.list_product_change_history(v_workspace, v_product, v_actor,
    1, (v_first_page->'nextCursor'->>'occurredAt')::timestamptz,
    v_first_page->'nextCursor'->>'eventId');
  IF v_result->>'status' IS DISTINCT FROM 'ok' OR
     jsonb_array_length(v_result->'events') IS DISTINCT FROM 1 OR
     v_result->'events'->0->>'id' IS NOT DISTINCT FROM
       v_first_page->'events'->0->>'id' THEN
    RAISE EXCEPTION 'Limit-one cursor did not advance.';
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
    IF v_result->>'status' IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'Synthetic history page request failed.'; END IF;
    v_page := v_result->'events';
    IF jsonb_typeof(v_page) IS DISTINCT FROM 'array' OR
       jsonb_array_length(v_page) NOT BETWEEN 1 AND 2 THEN
      RAISE EXCEPTION 'History page shape or limit differs.';
    END IF;
    FOR v_event IN SELECT value FROM jsonb_array_elements(v_page) AS page(value) LOOP
      IF jsonb_typeof(v_event) IS DISTINCT FROM 'object' OR
         v_event->>'id' IS NULL OR v_event->>'eventType' IS NULL OR
         v_event->>'occurredAt' IS NULL OR v_event->>'actorId' IS DISTINCT FROM v_actor::text OR
         v_event->>'actorName' IS NOT NULL OR
         jsonb_typeof(v_event->'item') IS DISTINCT FROM 'object' OR
         jsonb_typeof(v_event->'affectedItems') IS DISTINCT FROM 'array' OR
         v_event->>'occurredAt' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$' THEN
        RAISE EXCEPTION 'History event metadata or JSON shape differs.';
      END IF;
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
    IF v_cursor IS NOT NULL AND v_cursor IS DISTINCT FROM 'null'::jsonb AND
       (jsonb_typeof(v_cursor) IS DISTINCT FROM 'object' OR
        v_cursor->>'occurredAt' IS DISTINCT FROM to_char(
          v_previous_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') OR
        v_cursor->>'eventId' IS DISTINCT FROM v_previous_id) THEN
      RAISE EXCEPTION 'History cursor did not point to the page boundary.';
    END IF;
    EXIT WHEN v_cursor IS NULL OR v_cursor = 'null'::jsonb;
  END LOOP;

  IF jsonb_array_length(v_all) IS DISTINCT FROM 7 OR
     NOT ('product_created' = ANY(v_seen_types)) OR
     NOT ('schedule_imported' = ANY(v_seen_types)) OR
     NOT ('activity_dates_changed' = ANY(v_seen_types)) OR
     NOT ('business_target_date_changed' = ANY(v_seen_types)) OR
     NOT ('calendar_rescheduled' = ANY(v_seen_types)) OR
     NOT ('calendar_reschedule_reversed' = ANY(v_seen_types)) OR
     NOT ('schedule_hierarchy_deleted' = ANY(v_seen_types)) THEN
    RAISE EXCEPTION 'Synthetic event type coverage is incomplete.';
  END IF;

  -- An existing product always has product_created; an exhausted cursor is
  -- the valid empty-history page under the migration-0022 contract.
  v_empty_page := public.list_product_change_history(v_workspace, v_product, v_actor,
    1, v_previous_at, v_previous_id);
  IF v_empty_page->>'status' IS DISTINCT FROM 'ok' OR
     v_empty_page->'events' IS DISTINCT FROM '[]'::jsonb OR
     v_empty_page->'nextCursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Exhausted cursor did not return an empty history page.';
  END IF;
  v_result := public.list_product_change_history(v_workspace, v_product, v_actor,
    100, NULL, NULL);
  IF v_result->>'status' IS DISTINCT FROM 'ok' OR
     v_result->'events' IS DISTINCT FROM v_all OR
     v_result->'nextCursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Full history and paginated history differ.';
  END IF;

  SELECT value INTO v_product_event FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'product_created';
  SELECT value INTO v_import_event FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'schedule_imported';
  SELECT value INTO v_date_event FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'activity_dates_changed';
  SELECT value INTO v_target_event FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'business_target_date_changed';
  IF v_product_event->>'id' IS DISTINCT FROM 'product:' || v_product::text OR
     v_product_event->'item'->>'id' IS DISTINCT FROM v_product::text OR
     v_product_event->'item'->>'kind' IS DISTINCT FROM 'product' OR
     v_product_event->'item'->>'name' IS DISTINCT FROM v_name OR
     v_product_event->>'justification' IS NOT NULL OR
     v_product_event->'before' IS DISTINCT FROM 'null'::jsonb OR
     v_product_event->'after' IS DISTINCT FROM 'null'::jsonb OR
     v_product_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb OR
     v_import_event->>'id' IS DISTINCT FROM 'import:' || v_import_batch::text OR
     v_import_event->'before' IS DISTINCT FROM 'null'::jsonb OR
     v_import_event->'after'->>'sourceReferenceCount' IS DISTINCT FROM '1' OR
     v_import_event->'affectedItems' IS DISTINCT FROM '[]'::jsonb OR
     v_product_event->>'occurredAt' IS DISTINCT FROM v_import_event->>'occurredAt' OR
     v_date_event->>'id' IS DISTINCT FROM 'activity-date:' || v_date_operation::text OR
     v_date_event->'item'->>'id' IS DISTINCT FROM v_manual_activity::text OR
     v_date_event->'before'->>'plannedStart' IS DISTINCT FROM '2030-02-01' OR
     v_date_event->'before'->>'plannedEnd' IS DISTINCT FROM '2030-02-02' OR
     v_date_event->'after'->>'plannedStart' IS DISTINCT FROM '2030-02-02' OR
     v_date_event->'after'->>'plannedEnd' IS DISTINCT FROM '2030-02-03' OR
     v_date_event->>'justification' IS DISTINCT FROM v_reason OR
     v_target_event->>'id' IS DISTINCT FROM 'target-date:' || v_target_operation::text OR
     v_target_event->'item'->>'id' IS DISTINCT FROM v_target::text OR
     v_target_event->'before'->>'targetDate' IS DISTINCT FROM '2030-02-10' OR
     v_target_event->'after'->>'targetDate' IS DISTINCT FROM '2030-02-11' OR
     v_target_event->>'justification' IS DISTINCT FROM v_reason THEN
    RAISE EXCEPTION 'Product, import, date, or target event metadata differs.';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'activity_dates_changed') IS DISTINCT FROM 1 OR
     (SELECT value->'item'->>'id' FROM jsonb_array_elements(v_all) AS event(value)
      WHERE value->>'eventType' = 'activity_dates_changed') IS DISTINCT FROM v_manual_activity::text THEN
    RAISE EXCEPTION 'Reschedule/reversal date audit rows were duplicated as manual events.';
  END IF;
  SELECT value INTO v_reschedule FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'calendar_rescheduled';
  SELECT value INTO v_reschedule_reversal FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'calendar_reschedule_reversed';
  IF v_reschedule->>'id' IS DISTINCT FROM 'calendar-reschedule:' || v_batch::text OR
     v_reschedule->>'justification' IS DISTINCT FROM v_reason OR
     v_reschedule_reversal->>'id' IS DISTINCT FROM 'calendar-reversal:' || v_reversal::text OR
     v_reschedule_reversal->'before'->>'originalOperationId' IS DISTINCT FROM v_batch::text OR
     v_reschedule_reversal->'after'->>'originalOperationId' IS DISTINCT FROM v_batch::text OR
     v_reschedule->'after'->'activities'->0->>'plannedEnd' IS DISTINCT FROM
       to_char(v_start + 2, 'YYYY-MM-DD') OR
     v_reschedule->'after'->'activities'->0->>'workingDays' IS DISTINCT FROM '2' OR
     v_reschedule->'after'->'activities'->0->>'calendarVersion' IS DISTINCT FROM
       v_next_calendar_version::text OR
     v_reschedule_reversal->'after'->'activities'->0->>'plannedEnd' IS DISTINCT FROM
       to_char(v_start + 1, 'YYYY-MM-DD') OR
     jsonb_array_length(v_reschedule->'affectedItems') IS DISTINCT FROM 2 OR
     jsonb_array_length(v_reschedule->'before'->'activities') IS DISTINCT FROM 2 OR
     jsonb_array_length(v_reschedule->'after'->'activities') IS DISTINCT FROM 2 OR
     jsonb_array_length(v_reschedule_reversal->'affectedItems') IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Reschedule/reversal batches were not grouped by operation.';
  END IF;
  SELECT value INTO v_deletion FROM jsonb_array_elements(v_all) AS event(value)
    WHERE value->>'eventType' = 'schedule_hierarchy_deleted';
  IF v_deletion->>'id' IS DISTINCT FROM 'deletion:' || v_deletion_operation::text OR
     v_deletion->>'justification' IS DISTINCT FROM v_reason OR
     v_deletion->'after'->>'targetKind' IS DISTINCT FROM 'activity' OR
     v_deletion->'after'->>'targetId' IS DISTINCT FROM v_manual_activity::text OR
     v_deletion->'after'->>'affectedCount' IS DISTINCT FROM '1' OR
     v_deletion->'before' IS DISTINCT FROM 'null'::jsonb OR
     jsonb_array_length(v_deletion->'affectedItems') IS DISTINCT FROM 1 OR
     v_deletion->'item'->>'name' IS DISTINCT FROM 'Synthetic manual activity' OR
     v_deletion->'item'->'hierarchy'->>'discipline' IS DISTINCT FROM 'Synthetic history discipline' OR
     v_deletion->'item'->'hierarchy'->>'stage' IS DISTINCT FROM 'Synthetic history stage' OR
     v_deletion->'affectedItems'->0->>'name' IS DISTINCT FROM 'Synthetic manual activity' OR
     v_deletion->'affectedItems'->0->'hierarchy'->>'stage' IS DISTINCT FROM 'Synthetic history stage' THEN
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
  IF v_name IS DISTINCT FROM v_snapshot_hash THEN RAISE EXCEPTION 'Synthetic R00 snapshot changed.'; END IF;
  v_rejected := false;
  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = '{"dependencies":[]}'::jsonb
      WHERE product_id = v_product;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Worker was able to modify R00.'; END IF;

  RAISE NOTICE 'REL03M history contract, pagination, scope, grouping and privilege checks PASS';
END;
$$;

WITH original_state AS (
  SELECT
    (SELECT count(*) FROM public.products
      WHERE name NOT LIKE 'REL03M synthetic history %') AS products,
    (SELECT count(*) FROM public.product_disciplines
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03M synthetic history %')) AS disciplines,
    (SELECT count(*) FROM public.discipline_stages
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03M synthetic history %')) AS stages,
    (SELECT count(*) FROM public.stage_activities
      WHERE product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03M synthetic history %')) AS activities,
    (SELECT md5(COALESCE(string_agg(
      jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
        'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
      FROM public.stage_activities AS a
      WHERE a.product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03M synthetic history %')) AS dates,
    (SELECT md5(COALESCE(string_agg(
      r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
      FROM public.initial_schedule_revisions AS r
      WHERE r.product_id NOT IN (SELECT id FROM public.products
        WHERE name LIKE 'REL03M synthetic history %')) AS r00_fingerprint
)
SELECT 1 / CASE WHEN products = (:'rel03m_baseline'::jsonb->>'products')::bigint
  AND disciplines = (:'rel03m_baseline'::jsonb->>'disciplines')::bigint
  AND stages = (:'rel03m_baseline'::jsonb->>'stages')::bigint
  AND activities = (:'rel03m_baseline'::jsonb->>'activities')::bigint
  AND dates = (:'rel03m_baseline'::jsonb->>'dates')
  AND r00_fingerprint = (:'rel03m_baseline'::jsonb->>'r00_fingerprint')
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
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'target_audits', (SELECT count(*) FROM public.business_target_date_changes),
  'import_batches', (SELECT count(*) FROM public.import_batches),
  'import_source_rows', (SELECT count(*) FROM public.import_source_rows),
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events),
  'calendar_state', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('workspace_id', c.workspace_id, 'version', c.version,
      'updated_at', c.updated_at)::text, '|' ORDER BY c.workspace_id::text), ''))
    FROM public.workspace_calendar_versions AS c),
  'dates', (SELECT md5(COALESCE(string_agg(
    jsonb_build_object('id', a.id, 'planned_start', a.planned_start,
      'planned_end', a.planned_end)::text, '|' ORDER BY a.id::text), ''))
    FROM public.stage_activities AS a),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(
    r.id::text || '|' || r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r)
) AS after_rollback
\gset rel03m_
SELECT 1 / CASE WHEN count(*) = 0 THEN 1 ELSE 0 END AS synthetic_products_absent
FROM public.products WHERE name LIKE 'REL03M synthetic history %';
ROLLBACK;

SELECT 1 / CASE WHEN :'rel03m_after_rollback'::jsonb = :'rel03m_baseline'::jsonb
  THEN 1 ELSE 0 END AS full_accessible_baseline_preserved;
