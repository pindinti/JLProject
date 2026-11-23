-- Verify the audited fixed-stage seed before committing the six hierarchy edges.
\set ON_ERROR_STOP on
\i db/verification/phase4b5-seed-safety-owner.sql
SELECT set_config('jlproject.phase4b3c2_stage_audit_scope', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_fixed_product',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage',
  'versionBefore', :'test_fixed_schedule_version_before', 'versionAfter', :'test_fixed_schedule_version',
  'historicalR00Count', :'test_r00_count', 'historicalR00Fingerprint', :'test_r00_fingerprint',
  'derivedConflictProduct', :'test_conflict_product',
  'conflictDestination', :'test_conflict_destination_stage', 'conflictDestinationSuccessor', :'conflict_destination_successor',
  'conflictSource', :'test_conflict_source_stage', 'conflictSourceSuccessor', :'conflict_source_successor',
  'validProduct', :'test_valid_product', 'validDestination', :'test_valid_destination_stage', 'validSuccessor', :'valid_successor_stage',
  'rootProduct', :'test_root_product', 'rootStage', :'test_root_stage', 'rootSuccessor', :'root_successor_stage')::text, false);

DO $stage_seed_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c2_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
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
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace AND product_id = v_product
       AND version = 2 AND
       ((id = (v_scope->>'explicitStage')::uuid AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05') OR
        (id = (v_scope->>'partialStage')::uuid AND planned_start IS NULL AND planned_end = DATE '2026-11-05') OR
        (id = (v_scope->>'fixedSuccessorStage')::uuid AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10'))) <> 3 THEN
    RAISE EXCEPTION '0042 audited D065 dates, stage versions, or historical R00 fingerprint differ from the Worker setup.';
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
  v_scope jsonb := current_setting('jlproject.phase4b3c2_stage_audit_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_before bigint := (v_scope->>'versionBefore')::bigint;
  v_after bigint := (v_scope->>'versionAfter')::bigint;
  v_count bigint;
  v_edge record;
BEGIN
  IF current_user <> 'jlproject_date_executor' OR session_user <> 'neondb_owner' THEN
    RAISE EXCEPTION '0042 stage-date audit verification requires the temporary owner SET context.';
  END IF;
  SELECT count(*) INTO v_count
  FROM (VALUES
    ('4b420000-0000-4000-8000-000000000301'::uuid, (v_scope->>'explicitStage')::uuid, DATE '2026-11-03', DATE '2026-11-05'),
    ('4b420000-0000-4000-8000-000000000302'::uuid, (v_scope->>'partialStage')::uuid, NULL::date, DATE '2026-11-05'),
    ('4b420000-0000-4000-8000-000000000303'::uuid, (v_scope->>'fixedSuccessorStage')::uuid, DATE '2026-11-06', DATE '2026-11-10')
  ) AS expected(operation_id, stage_id, new_start, new_end)
  JOIN public.stage_date_changes AS change ON change.operation_id = expected.operation_id
    AND change.workspace_id = v_workspace AND change.product_id = v_product AND change.stage_id = expected.stage_id
    AND change.actor_id = v_actor AND change.previous_start IS NULL AND change.previous_end IS NULL
    AND change.new_start IS NOT DISTINCT FROM expected.new_start AND change.new_end IS NOT DISTINCT FROM expected.new_end
    AND change.reason = 'Synthetic hierarchy movement D065 date setup'
    AND change.version_before = 1 AND change.version_after = 2;
  IF v_count <> 3 OR (SELECT count(*) FROM public.stage_date_changes
      WHERE workspace_id = v_workspace AND product_id = v_product) <> 3 THEN
    RAISE EXCEPTION '0042 expected exactly three individually audited D065 stage-date changes.';
  END IF;

  SELECT count(*) INTO v_count
  FROM (VALUES
    ('4b420000-0000-4000-8000-000000000301'::uuid, v_before + 1),
    ('4b420000-0000-4000-8000-000000000302'::uuid, v_before + 2),
    ('4b420000-0000-4000-8000-000000000303'::uuid, v_before + 3)
  ) AS expected(operation_id, schedule_version)
  JOIN public.product_schedule_operations AS operation ON operation.workspace_id = v_workspace
    AND operation.product_id = v_product AND operation.operation_id = expected.operation_id
    AND operation.schedule_version = expected.schedule_version AND operation.actor_id = v_actor
    AND operation.operation_type = 'stage_dates_changed'
    AND operation.justification = 'Synthetic hierarchy movement D065 date setup';
  IF v_count <> 3 OR v_after <> v_before + 3 OR
     (SELECT count(DISTINCT transaction_id) FROM public.product_schedule_operations
       WHERE workspace_id = v_workspace AND product_id = v_product AND operation_id IN (
         '4b420000-0000-4000-8000-000000000301', '4b420000-0000-4000-8000-000000000302',
         '4b420000-0000-4000-8000-000000000303')) <> 3 OR
     (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id IN (
         '4b420000-0000-4000-8000-000000000301', '4b420000-0000-4000-8000-000000000302',
         '4b420000-0000-4000-8000-000000000303') AND entity_type = 'discipline_stages'
       AND change_type = 'discipline_stages_dates_changed'
       AND entity_id IN ((v_scope->>'explicitStage')::uuid, (v_scope->>'partialStage')::uuid,
         (v_scope->>'fixedSuccessorStage')::uuid)) <> 3 OR
     (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id IN (
         '4b420000-0000-4000-8000-000000000301', '4b420000-0000-4000-8000-000000000302',
         '4b420000-0000-4000-8000-000000000303')) <> 3 OR
     (SELECT count(*)
      FROM (VALUES
        ('4b420000-0000-4000-8000-000000000301'::uuid,
          (v_scope->>'explicitStage')::uuid, v_before + 1),
        ('4b420000-0000-4000-8000-000000000302'::uuid,
          (v_scope->>'partialStage')::uuid, v_before + 2),
        ('4b420000-0000-4000-8000-000000000303'::uuid,
          (v_scope->>'fixedSuccessorStage')::uuid, v_before + 3)
      ) AS expected(operation_id, stage_id, schedule_version)
      JOIN public.stage_date_changes AS change
        ON change.workspace_id = v_workspace AND change.product_id = v_product
        AND change.operation_id = expected.operation_id AND change.stage_id = expected.stage_id
      JOIN public.product_schedule_operations AS operation
        ON operation.workspace_id = v_workspace AND operation.product_id = v_product
        AND operation.schedule_version = expected.schedule_version
        AND operation.operation_id = expected.operation_id AND operation.actor_id = v_actor
        AND operation.operation_type = 'stage_dates_changed'
        AND operation.justification = 'Synthetic hierarchy movement D065 date setup'
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
        AND source.source_event_id = change.event_id AND source.link_kind = 'audit_detail') <> 3 OR
     (SELECT count(*) FROM public.product_schedule_operation_source_events AS source
       WHERE source.operation_id IN ('4b420000-0000-4000-8000-000000000301',
               '4b420000-0000-4000-8000-000000000302', '4b420000-0000-4000-8000-000000000303')
          OR source.source_operation_id IN ('4b420000-0000-4000-8000-000000000301',
               '4b420000-0000-4000-8000-000000000302', '4b420000-0000-4000-8000-000000000303')) <> 3 OR
     (SELECT schedule_version FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor)) <> v_after THEN
    RAISE EXCEPTION '0042 stage-date Living Schedule operations, events, source-event associations, transactions, or cursor did not match the three audited changes.';
  END IF;

  -- Check all positive edges before committing any of them, with the reviewed D065 and calendar helpers.
  FOR v_edge IN
    SELECT edge.label, predecessor.end_date AS finish, successor.start_date AS start,
      public.dependency_first_working_start(v_workspace, predecessor.end_date) AS earliest_start
    FROM (VALUES
      ('conflict destination', 'derivedConflictProduct', 'conflictDestination', 'conflictDestinationSuccessor'),
      ('conflict source', 'derivedConflictProduct', 'conflictSource', 'conflictSourceSuccessor'),
      ('valid destination', 'validProduct', 'validDestination', 'validSuccessor'),
      ('explicit stage', 'product', 'explicitStage', 'fixedSuccessorStage'),
      ('partial stage', 'product', 'partialStage', 'fixedSuccessorStage'),
      ('root scenario stage', 'rootProduct', 'rootStage', 'rootSuccessor')
    ) AS edge(label, product_key, predecessor_key, successor_key)
    LEFT JOIN LATERAL public.dependency_effective_date_interval(v_workspace, (v_scope->>edge.product_key)::uuid,
      'stage', (v_scope->>edge.predecessor_key)::uuid, NULL, NULL, NULL, NULL) AS predecessor ON true
    LEFT JOIN LATERAL public.dependency_effective_date_interval(v_workspace, (v_scope->>edge.product_key)::uuid,
      'stage', (v_scope->>edge.successor_key)::uuid, NULL, NULL, NULL, NULL) AS successor ON true
  LOOP
    IF v_edge.finish IS NULL OR v_edge.start IS NULL OR v_edge.earliest_start IS NULL
       OR v_edge.start < v_edge.earliest_start THEN
      RAISE EXCEPTION '0042 fixture edge % requires valid Finish-to-Start boundaries (finish %, start %, earliest start %).',
        v_edge.label, v_edge.finish, v_edge.start, v_edge.earliest_start;
    END IF;
  END LOOP;
END;
$stage_audit_assertions$;
RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;
DO $role_cleanup$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION '0042 temporary stage-date audit privileges were not cleaned up.';
  END IF;
END;
$role_cleanup$;
COMMIT;

\set test_product :test_conflict_product
\set test_edge_id :test_conflict_dependency
\set test_endpoint_kind stage
\set test_predecessor_id :test_conflict_destination_stage
\set test_successor_id :conflict_destination_successor
\set test_operation_id 4b420000-0000-4000-8000-000000000201
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id 4b420000-0000-4000-8000-000000000102
\set test_predecessor_id :test_conflict_source_stage
\set test_successor_id :conflict_source_successor
\set test_operation_id 4b420000-0000-4000-8000-000000000202
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_valid_product
\set test_edge_id 4b420000-0000-4000-8000-000000000103
\set test_predecessor_id :test_valid_destination_stage
\set test_successor_id :valid_successor_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000203
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_fixed_product
\set test_edge_id 4b420000-0000-4000-8000-000000000104
\set test_predecessor_id :test_explicit_stage
\set test_successor_id :fixed_successor_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000204
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id 4b420000-0000-4000-8000-000000000105
\set test_predecessor_id :test_partial_stage
\set test_successor_id :fixed_successor_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000205
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product :test_root_product
\set test_edge_id 4b420000-0000-4000-8000-000000000106
\set test_predecessor_id :test_root_stage
\set test_successor_id :root_successor_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000206
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Audited hierarchy D065 dates and Living Schedule state verified before dependency confirmation.
