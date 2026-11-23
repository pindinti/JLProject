-- Set the four explicit D065 boundaries through separate audited Worker transactions.
\set ON_ERROR_STOP on
SELECT set_config('jlproject.phase4b3c1_stage_seed_scope', jsonb_build_object(
  'disposable', :'phase4b5_disposable_child_verified',
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'linkedProduct', :'test_linked_product', 'violationProduct', :'test_violation_product',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage',
  'violationSuccessorStage', :'violation_successor_stage',
  'violationPredecessorStage', :'test_violation_stage',
  'derivedPredecessorStage', :'test_derived_predecessor_stage',
  'derivedSuccessorStage', :'test_derived_successor_stage')::text, false);

DO $worker_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c1_stage_seed_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_product uuid := (v_scope->>'linkedProduct')::uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR v_scope->>'disposable' IS DISTINCT FROM 'true' OR
     NOT has_function_privilege(current_user,
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role = 'admin') OR
     (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace
       AND id IN (v_product, (v_scope->>'violationProduct')::uuid) AND active) <> 2 OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_product AND id IN ((v_scope->>'explicitStage')::uuid,
         (v_scope->>'partialStage')::uuid, (v_scope->>'fixedSuccessorStage')::uuid,
         (v_scope->>'derivedPredecessorStage')::uuid, (v_scope->>'derivedSuccessorStage')::uuid)
       AND version = 1 AND planned_start IS NULL AND planned_end IS NULL AND deleted_at IS NULL) <> 5 OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = (v_scope->>'violationProduct')::uuid
       AND id IN ((v_scope->>'violationSuccessorStage')::uuid,
         (v_scope->>'violationPredecessorStage')::uuid)
       AND version = 1 AND planned_start IS NULL AND planned_end IS NULL AND deleted_at IS NULL) <> 2 THEN
    RAISE EXCEPTION '0041 stage-date setup requires the expected active synthetic products, stages, versions, direct Worker identity, and admin membership.';
  END IF;
END;
$worker_preflight$;

SELECT schedule_version AS test_linked_schedule_version_before
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_linked_product'::uuid, :'test_actor'::uuid) \gset
SELECT schedule_version AS test_violation_schedule_version_before
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_violation_product'::uuid, :'test_actor'::uuid) \gset

\set test_product :test_linked_product
\set test_stage :test_explicit_stage
\set test_stage_version 1
\set test_operation_id 4b410000-0000-4000-8000-000000000301
\set test_start 2026-11-03
\set test_end 2026-11-05
\set test_justification 'Synthetic activity creation D065 date setup'
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_stage :test_partial_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000302
\set test_start __NULL__
\set test_end 2026-11-05
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_stage :fixed_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000303
\set test_start 2026-11-06
\set test_end 2026-11-10
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_product :test_violation_product
\set test_stage :violation_successor_stage
\set test_operation_id 4b410000-0000-4000-8000-000000000304
\set test_start 2026-11-06
\set test_end 2026-11-10
\i db/verification/phase4b5-seed-one-stage-date.sql

SELECT set_config('jlproject.phase4b3c1_stage_seed_postflight', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'linkedProduct', :'test_linked_product', 'violationProduct', :'test_violation_product',
  'linkedVersionBefore', :'test_linked_schedule_version_before',
  'violationVersionBefore', :'test_violation_schedule_version_before',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage',
  'violationSuccessorStage', :'violation_successor_stage')::text, false);
DO $worker_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c1_stage_seed_postflight')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_linked_product uuid := (v_scope->>'linkedProduct')::uuid;
  v_violation_product uuid := (v_scope->>'violationProduct')::uuid;
  v_cursor bigint;
BEGIN
  IF (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
      AND product_id = v_linked_product AND
      ((id = (v_scope->>'explicitStage')::uuid AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05') OR
       (id = (v_scope->>'partialStage')::uuid AND planned_start IS NULL AND planned_end = DATE '2026-11-05') OR
       (id = (v_scope->>'fixedSuccessorStage')::uuid AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10'))
      AND version = 2) <> 3 OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = v_violation_product AND id = (v_scope->>'violationSuccessorStage')::uuid
       AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10' AND version = 2) <> 1 THEN
    RAISE EXCEPTION '0041 audited stage-date setup did not produce the four expected explicit and partial intervals at version 2.';
  END IF;
  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(
    v_workspace, v_linked_product, v_actor);
  IF v_cursor <> (v_scope->>'linkedVersionBefore')::bigint + 3 THEN
    RAISE EXCEPTION 'Linked product schedule cursor did not advance once for each of three audited stage-date operations.';
  END IF;
  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(
    v_workspace, v_violation_product, v_actor);
  IF v_cursor <> (v_scope->>'violationVersionBefore')::bigint + 1 THEN
    RAISE EXCEPTION 'Violation product schedule cursor did not advance once for its audited stage-date operation.';
  END IF;
END;
$worker_postflight$;

SELECT schedule_version AS test_linked_schedule_version
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_linked_product'::uuid, :'test_actor'::uuid) \gset
SELECT schedule_version AS test_violation_schedule_version
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_violation_product'::uuid, :'test_actor'::uuid) \gset
\echo Worker psql variables: test_workspace=:test_workspace test_actor=:test_actor test_linked_product=:test_linked_product test_violation_product=:test_violation_product test_explicit_stage=:test_explicit_stage test_partial_stage=:test_partial_stage fixed_successor_stage=:fixed_successor_stage violation_successor_stage=:violation_successor_stage test_linked_schedule_version_before=:test_linked_schedule_version_before test_violation_schedule_version_before=:test_violation_schedule_version_before test_linked_schedule_version=:test_linked_schedule_version test_violation_schedule_version=:test_violation_schedule_version
