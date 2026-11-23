-- Verify audited explicit/partial D065 setup before committing deletion-fixture graph edges.
\set ON_ERROR_STOP on
\i db/verification/phase4b5-seed-safety-owner.sql
SELECT set_config('jlproject.phase4b3c3_stage_audit_scope', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'fixedProduct', :'test_fixed_product', 'partialProduct', :'test_partial_product',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedVersionBefore', :'test_fixed_schedule_version_before',
  'fixedVersionAfter', :'test_fixed_schedule_version',
  'partialVersionBefore', :'test_partial_schedule_version_before',
  'partialVersionAfter', :'test_partial_schedule_version',
  'historicalR00Count', :'test_r00_count', 'historicalR00Fingerprint', :'test_r00_fingerprint')::text, false);
DO $stage_seed_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_r00_count bigint;
  v_r00_fingerprint text;
BEGIN
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_r00_count, v_r00_fingerprint FROM public.initial_schedule_revisions AS revision;
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_r00_count <> (v_scope->>'historicalR00Count')::bigint OR
     v_r00_fingerprint IS DISTINCT FROM (v_scope->>'historicalR00Fingerprint') OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = (v_scope->>'fixedProduct')::uuid AND id = (v_scope->>'explicitStage')::uuid
       AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05' AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = (v_scope->>'partialProduct')::uuid AND id = (v_scope->>'partialStage')::uuid
       AND planned_start IS NULL AND planned_end = DATE '2026-11-05' AND version = 2) THEN
    RAISE EXCEPTION '0043 D065 dates, versions, or historical R00 fingerprint differ from the Worker setup.';
  END IF;
END;
$stage_seed_preflight$;

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
GRANT jlproject_date_executor TO neondb_owner
  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
SET LOCAL ROLE jlproject_date_executor;
DO $stage_audit_assertions$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_fixed uuid := (v_scope->>'fixedProduct')::uuid;
  v_partial uuid := (v_scope->>'partialProduct')::uuid;
  v_count bigint;
BEGIN
  IF current_user <> 'jlproject_date_executor' OR session_user <> 'neondb_owner' THEN
    RAISE EXCEPTION '0043 stage-date audit verification requires the temporary owner SET context.';
  END IF;
  SELECT count(*) INTO v_count
  FROM (VALUES
    ('4b430000-0000-4000-8000-000000000301'::uuid, v_fixed, (v_scope->>'explicitStage')::uuid, DATE '2026-11-03', DATE '2026-11-05'),
    ('4b430000-0000-4000-8000-000000000302'::uuid, v_partial, (v_scope->>'partialStage')::uuid, NULL::date, DATE '2026-11-05')
  ) AS expected(operation_id, product_id, stage_id, new_start, new_end)
  JOIN public.stage_date_changes AS change ON change.operation_id = expected.operation_id
    AND change.workspace_id = v_workspace AND change.product_id = expected.product_id
    AND change.stage_id = expected.stage_id AND change.actor_id = v_actor
    AND change.previous_start IS NULL AND change.previous_end IS NULL
    AND change.new_start IS NOT DISTINCT FROM expected.new_start
    AND change.new_end IS NOT DISTINCT FROM expected.new_end
    AND change.reason = 'Synthetic schedule deletion D065 date setup'
    AND change.version_before = 1 AND change.version_after = 2;
  IF v_count <> 2 OR (SELECT count(*) FROM public.stage_date_changes
      WHERE workspace_id = v_workspace AND product_id IN (v_fixed, v_partial)) <> 2 OR
     (SELECT count(*) FROM public.product_schedule_operations WHERE workspace_id = v_workspace
       AND ((product_id = v_fixed AND operation_id = '4b430000-0000-4000-8000-000000000301'
           AND schedule_version = (v_scope->>'fixedVersionBefore')::bigint + 1) OR
        (product_id = v_partial AND operation_id = '4b430000-0000-4000-8000-000000000302'
           AND schedule_version = (v_scope->>'partialVersionBefore')::bigint + 1))
       AND actor_id = v_actor AND operation_type = 'stage_dates_changed'
       AND justification = 'Synthetic schedule deletion D065 date setup') <> 2 OR
     (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND ((product_id = v_fixed AND operation_id = '4b430000-0000-4000-8000-000000000301'
           AND entity_id = (v_scope->>'explicitStage')::uuid) OR
        (product_id = v_partial AND operation_id = '4b430000-0000-4000-8000-000000000302'
           AND entity_id = (v_scope->>'partialStage')::uuid))
       AND entity_type = 'discipline_stages' AND change_type = 'discipline_stages_dates_changed') <> 2 OR
     (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND ((product_id = v_fixed AND operation_id = '4b430000-0000-4000-8000-000000000301') OR
         (product_id = v_partial AND operation_id = '4b430000-0000-4000-8000-000000000302'))) <> 2 OR
     (SELECT count(*)
      FROM (VALUES
        ('4b430000-0000-4000-8000-000000000301'::uuid, v_fixed,
          (v_scope->>'explicitStage')::uuid, (v_scope->>'fixedVersionBefore')::bigint + 1),
        ('4b430000-0000-4000-8000-000000000302'::uuid, v_partial,
          (v_scope->>'partialStage')::uuid, (v_scope->>'partialVersionBefore')::bigint + 1)
      ) AS expected(operation_id, product_id, stage_id, schedule_version)
      JOIN public.stage_date_changes AS change
        ON change.workspace_id = v_workspace AND change.product_id = expected.product_id
        AND change.operation_id = expected.operation_id AND change.stage_id = expected.stage_id
      JOIN public.product_schedule_operations AS operation
        ON operation.workspace_id = v_workspace AND operation.product_id = expected.product_id
        AND operation.schedule_version = expected.schedule_version
        AND operation.operation_id = expected.operation_id AND operation.actor_id = v_actor
        AND operation.operation_type = 'stage_dates_changed'
        AND operation.justification = 'Synthetic schedule deletion D065 date setup'
      JOIN public.product_schedule_operation_events AS event
        ON event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
        AND event.schedule_version = operation.schedule_version AND event.operation_id = operation.operation_id
        AND event.entity_type = 'discipline_stages' AND event.entity_id = expected.stage_id
        AND event.change_type = 'discipline_stages_dates_changed'
      JOIN public.product_schedule_operation_source_events AS source
        ON source.workspace_id = change.workspace_id AND source.product_id = change.product_id
        AND source.schedule_version = operation.schedule_version AND source.operation_id = operation.operation_id
        AND source.source_ledger = 'stage_date_changes'
        AND source.source_operation_id = change.operation_id
        AND source.source_event_id = change.event_id AND source.link_kind = 'audit_detail') <> 2 OR
     (SELECT count(*) FROM public.product_schedule_operation_source_events AS source
       WHERE source.operation_id IN ('4b430000-0000-4000-8000-000000000301',
               '4b430000-0000-4000-8000-000000000302')
          OR source.source_operation_id IN ('4b430000-0000-4000-8000-000000000301',
               '4b430000-0000-4000-8000-000000000302')) <> 2 OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_fixed, v_actor)) <>
       (v_scope->>'fixedVersionAfter')::bigint OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_partial, v_actor)) <>
       (v_scope->>'partialVersionAfter')::bigint OR
     (v_scope->>'fixedVersionAfter')::bigint <> (v_scope->>'fixedVersionBefore')::bigint + 1 OR
     (v_scope->>'partialVersionAfter')::bigint <> (v_scope->>'partialVersionBefore')::bigint + 1 THEN
    RAISE EXCEPTION '0043 stage-date audit history, Living Schedule operations/events/source-event associations, or cursor state did not match the two explicit operations.';
  END IF;
END;
$stage_audit_assertions$;
RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;
DO $role_cleanup$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION '0043 temporary stage-date audit privileges were not cleaned up.';
  END IF;
END;
$role_cleanup$;
COMMIT;

\set test_product :test_linked_product
\set test_edge_id :test_linked_activity_dependency
\set test_endpoint_kind activity
\set test_predecessor_id :test_linked_activity
\set test_successor_id :linked_successor_activity
\set test_operation_id 4b430000-0000-4000-8000-000000000601
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id :test_linked_stage_dependency
\set test_endpoint_kind stage
\set test_predecessor_id :test_linked_stage
\set test_successor_id :linked_successor_stage
\set test_operation_id 4b430000-0000-4000-8000-000000000602
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_descendant_product
\set test_edge_id :test_descendant_dependency
\set test_endpoint_kind stage
\set test_predecessor_id :test_descendant_stage
\set test_successor_id :descendant_successor_stage
\set test_operation_id 4b430000-0000-4000-8000-000000000603
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_missing_product
\set test_edge_id :test_missing_dependency
\set test_endpoint_kind stage
\set test_predecessor_id :test_missing_stage
\set test_successor_id :missing_successor_stage
\set test_operation_id 4b430000-0000-4000-8000-000000000604
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_valid_product
\set test_edge_id :test_valid_dependency
\set test_endpoint_kind stage
\set test_predecessor_id :test_valid_stage
\set test_successor_id :valid_successor_stage
\set test_operation_id 4b430000-0000-4000-8000-000000000605
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Audited deletion D065 dates and Living Schedule state verified before dependency confirmation.
