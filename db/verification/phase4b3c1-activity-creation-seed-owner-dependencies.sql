-- Verify the audited D065 seed state, then add its four edges in separate operations.
\set ON_ERROR_STOP on
\i db/verification/phase4b5-seed-safety-owner.sql

SELECT set_config('jlproject.phase4b3c1_stage_audit_scope', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'linkedProduct', :'test_linked_product', 'violationProduct', :'test_violation_product',
  'derivedPredecessor', :'test_derived_predecessor_stage',
  'derivedSuccessor', :'test_derived_successor_stage',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage', 'violationStage', :'test_violation_stage',
  'violationSuccessorStage', :'violation_successor_stage',
  'linkedVersionBefore', :'test_linked_schedule_version_before',
  'violationVersionBefore', :'test_violation_schedule_version_before',
  'linkedVersionAfter', :'test_linked_schedule_version',
  'violationVersionAfter', :'test_violation_schedule_version',
  'historicalR00Count', :'test_r00_count', 'historicalR00Fingerprint', :'test_r00_fingerprint')::text, false);

DO $stage_seed_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c1_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_linked uuid := (v_scope->>'linkedProduct')::uuid;
  v_violation uuid := (v_scope->>'violationProduct')::uuid;
  v_r00_count bigint;
  v_r00_fingerprint text;
BEGIN
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_r00_count, v_r00_fingerprint
    FROM public.initial_schedule_revisions AS revision;
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_r00_count <> (v_scope->>'historicalR00Count')::bigint OR
     v_r00_fingerprint IS DISTINCT FROM v_scope->>'historicalR00Fingerprint' OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace) OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_linked AND
       ((id = (v_scope->>'derivedPredecessor')::uuid AND planned_start IS NULL AND planned_end IS NULL AND version = 1) OR
        (id = (v_scope->>'derivedSuccessor')::uuid AND planned_start IS NULL AND planned_end IS NULL AND version = 1) OR
        (id = (v_scope->>'explicitStage')::uuid AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05' AND version = 2) OR
        (id = (v_scope->>'partialStage')::uuid AND planned_start IS NULL AND planned_end = DATE '2026-11-05' AND version = 2) OR
        (id = (v_scope->>'fixedSuccessorStage')::uuid AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10' AND version = 2))) <> 5 OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_violation AND
       ((id = (v_scope->>'violationStage')::uuid AND planned_start IS NULL AND planned_end IS NULL AND version = 1) OR
        (id = (v_scope->>'violationSuccessorStage')::uuid AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10' AND version = 2))) <> 2 THEN
    RAISE EXCEPTION '0041 D065 seed dates, stage versions, or historical R00 fingerprints differ from the audited Worker setup.';
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
  v_scope jsonb := current_setting('jlproject.phase4b3c1_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_linked uuid := (v_scope->>'linkedProduct')::uuid;
  v_violation uuid := (v_scope->>'violationProduct')::uuid;
  v_linked_before bigint := (v_scope->>'linkedVersionBefore')::bigint;
  v_violation_before bigint := (v_scope->>'violationVersionBefore')::bigint;
  v_linked_after bigint := (v_scope->>'linkedVersionAfter')::bigint;
  v_violation_after bigint := (v_scope->>'violationVersionAfter')::bigint;
  v_count bigint;
BEGIN
  IF current_user <> 'jlproject_date_executor' OR session_user <> 'neondb_owner' OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') THEN
    RAISE EXCEPTION 'Audited stage-date verification requires the temporary owner SET context.';
  END IF;

  SELECT count(*) INTO v_count
  FROM (VALUES
    ('4b410000-0000-4000-8000-000000000301'::uuid, v_linked, (v_scope->>'explicitStage')::uuid, DATE '2026-11-03', DATE '2026-11-05'),
    ('4b410000-0000-4000-8000-000000000302'::uuid, v_linked, (v_scope->>'partialStage')::uuid, NULL::date, DATE '2026-11-05'),
    ('4b410000-0000-4000-8000-000000000303'::uuid, v_linked, (v_scope->>'fixedSuccessorStage')::uuid, DATE '2026-11-06', DATE '2026-11-10'),
    ('4b410000-0000-4000-8000-000000000304'::uuid, v_violation, (v_scope->>'violationSuccessorStage')::uuid, DATE '2026-11-06', DATE '2026-11-10')
  ) AS expected(operation_id, product_id, stage_id, new_start, new_end)
  JOIN public.stage_date_changes AS change ON change.operation_id = expected.operation_id
    AND change.workspace_id = v_workspace AND change.product_id = expected.product_id
    AND change.stage_id = expected.stage_id AND change.actor_id = v_actor
    AND change.previous_start IS NULL AND change.previous_end IS NULL
    AND change.new_start IS NOT DISTINCT FROM expected.new_start
    AND change.new_end IS NOT DISTINCT FROM expected.new_end
    AND change.reason = 'Synthetic activity creation D065 date setup'
    AND change.version_before = 1 AND change.version_after = 2;
  IF v_count <> 4 OR
     (SELECT count(*) FROM public.stage_date_changes WHERE workspace_id = v_workspace
       AND product_id IN (v_linked, v_violation)) <> 4 THEN
    RAISE EXCEPTION 'Expected exactly four individually audited stage-date changes with the planned before/after values.';
  END IF;

  SELECT count(*) INTO v_count
  FROM (VALUES
    ('4b410000-0000-4000-8000-000000000301'::uuid, v_linked, v_linked_before + 1),
    ('4b410000-0000-4000-8000-000000000302'::uuid, v_linked, v_linked_before + 2),
    ('4b410000-0000-4000-8000-000000000303'::uuid, v_linked, v_linked_before + 3),
    ('4b410000-0000-4000-8000-000000000304'::uuid, v_violation, v_violation_before + 1)
  ) AS expected(operation_id, product_id, schedule_version)
  JOIN public.product_schedule_operations AS operation ON operation.workspace_id = v_workspace
    AND operation.product_id = expected.product_id AND operation.operation_id = expected.operation_id
    AND operation.schedule_version = expected.schedule_version AND operation.actor_id = v_actor
    AND operation.operation_type = 'stage_dates_changed'
    AND operation.justification = 'Synthetic activity creation D065 date setup';
  IF v_count <> 4 OR v_linked_after <> v_linked_before + 3 OR
     v_violation_after <> v_violation_before + 1 OR
     (SELECT count(*) FROM public.product_schedule_operations WHERE workspace_id = v_workspace
       AND product_id IN (v_linked, v_violation) AND operation_id IN (
         '4b410000-0000-4000-8000-000000000301', '4b410000-0000-4000-8000-000000000302',
         '4b410000-0000-4000-8000-000000000303', '4b410000-0000-4000-8000-000000000304')) <> 4 OR
     (SELECT count(DISTINCT transaction_id) FROM public.product_schedule_operations
       WHERE workspace_id = v_workspace AND product_id = v_linked AND operation_id IN (
         '4b410000-0000-4000-8000-000000000301', '4b410000-0000-4000-8000-000000000302',
         '4b410000-0000-4000-8000-000000000303')) <> 3 OR
     (SELECT count(DISTINCT transaction_id) FROM public.product_schedule_operations
       WHERE workspace_id = v_workspace AND product_id = v_violation
         AND operation_id = '4b410000-0000-4000-8000-000000000304') <> 1 THEN
    RAISE EXCEPTION 'Expected one separately committed Living Schedule operation per stage-date change and the corresponding cursor advances.';
  END IF;

  IF (SELECT count(*) FROM public.product_schedule_operation_events AS event
      JOIN (VALUES
        ('4b410000-0000-4000-8000-000000000301'::uuid, (v_scope->>'explicitStage')::uuid),
        ('4b410000-0000-4000-8000-000000000302'::uuid, (v_scope->>'partialStage')::uuid),
        ('4b410000-0000-4000-8000-000000000303'::uuid, (v_scope->>'fixedSuccessorStage')::uuid),
        ('4b410000-0000-4000-8000-000000000304'::uuid, (v_scope->>'violationSuccessorStage')::uuid)
      ) AS expected(operation_id, stage_id) ON expected.operation_id = event.operation_id
      WHERE event.workspace_id = v_workspace AND event.product_id IN (v_linked, v_violation)
        AND event.entity_type = 'discipline_stages' AND event.entity_id = expected.stage_id
        AND event.change_type = 'discipline_stages_dates_changed') <> 4 OR
     (SELECT count(*) FROM public.product_schedule_operation_events AS event WHERE
       event.workspace_id = v_workspace AND event.product_id IN (v_linked, v_violation)
       AND event.operation_id IN ('4b410000-0000-4000-8000-000000000301',
         '4b410000-0000-4000-8000-000000000302', '4b410000-0000-4000-8000-000000000303',
         '4b410000-0000-4000-8000-000000000304')) <> 4 OR
     (SELECT count(*)
      FROM (VALUES
        ('4b410000-0000-4000-8000-000000000301'::uuid, v_linked,
          (v_scope->>'explicitStage')::uuid, v_linked_before + 1),
        ('4b410000-0000-4000-8000-000000000302'::uuid, v_linked,
          (v_scope->>'partialStage')::uuid, v_linked_before + 2),
        ('4b410000-0000-4000-8000-000000000303'::uuid, v_linked,
          (v_scope->>'fixedSuccessorStage')::uuid, v_linked_before + 3),
        ('4b410000-0000-4000-8000-000000000304'::uuid, v_violation,
          (v_scope->>'violationSuccessorStage')::uuid, v_violation_before + 1)
      ) AS expected(operation_id, product_id, stage_id, schedule_version)
      JOIN public.stage_date_changes AS change
        ON change.workspace_id = v_workspace AND change.product_id = expected.product_id
        AND change.operation_id = expected.operation_id AND change.stage_id = expected.stage_id
      JOIN public.product_schedule_operations AS operation
        ON operation.workspace_id = v_workspace AND operation.product_id = expected.product_id
        AND operation.schedule_version = expected.schedule_version
        AND operation.operation_id = expected.operation_id AND operation.actor_id = v_actor
        AND operation.operation_type = 'stage_dates_changed'
        AND operation.justification = 'Synthetic activity creation D065 date setup'
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
        AND source.source_event_id = change.event_id AND source.link_kind = 'audit_detail') <> 4 OR
     (SELECT count(*) FROM public.product_schedule_operation_source_events AS source
      WHERE source.operation_id IN ('4b410000-0000-4000-8000-000000000301',
              '4b410000-0000-4000-8000-000000000302', '4b410000-0000-4000-8000-000000000303',
              '4b410000-0000-4000-8000-000000000304')
        OR source.source_operation_id IN ('4b410000-0000-4000-8000-000000000301',
              '4b410000-0000-4000-8000-000000000302', '4b410000-0000-4000-8000-000000000303',
              '4b410000-0000-4000-8000-000000000304')) <> 4 THEN
    RAISE EXCEPTION 'Expected exactly four correctly scoped stage-date source-event associations for the Living Schedule operations.';
  END IF;

  IF (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_linked, v_actor)) <> v_linked_after OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_violation, v_actor)) <> v_violation_after THEN
    RAISE EXCEPTION 'Worker-reported schedule cursors do not match the audited database state.';
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
    RAISE EXCEPTION 'Temporary stage-date audit verification privileges were not cleaned up.';
  END IF;
END;
$role_cleanup$;
COMMIT;

\set test_product :test_linked_product
\set test_edge_id 4b410000-0000-4000-8000-000000000101
\set test_endpoint_kind stage
\set test_predecessor_id :test_derived_predecessor_stage
\set test_successor_id :test_derived_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000201
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id 4b410000-0000-4000-8000-000000000102
\set test_predecessor_id :test_explicit_stage
\set test_successor_id :fixed_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000202
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id 4b410000-0000-4000-8000-000000000103
\set test_predecessor_id :test_partial_stage
\set test_successor_id :fixed_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000203
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_violation_product
\set test_edge_id 4b410000-0000-4000-8000-000000000104
\set test_predecessor_id :test_violation_stage
\set test_successor_id :violation_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000204
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Audited 0041 stage dates, stage versions, Living Schedule operations, audit events, cursor advances and historical R00 fingerprint verified before dependency confirmation.
