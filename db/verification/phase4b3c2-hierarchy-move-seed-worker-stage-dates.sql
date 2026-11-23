-- Establish the fixed D065 intervals through one audited Worker transaction per stage.
\set ON_ERROR_STOP on
SELECT set_config('jlproject.phase4b3c2_stage_seed_scope', jsonb_build_object(
  'disposable', :'phase4b5_disposable_child_verified', 'workspace', :'test_workspace',
  'actor', :'test_actor', 'product', :'test_fixed_product',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage')::text, false);
DO $worker_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c2_stage_seed_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR v_scope->>'disposable' IS DISTINCT FROM 'true' OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = (v_scope->>'actor')::uuid AND active AND role = 'admin') OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND id = v_product AND active) OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace AND product_id = v_product
       AND id IN ((v_scope->>'explicitStage')::uuid, (v_scope->>'partialStage')::uuid,
         (v_scope->>'fixedSuccessorStage')::uuid) AND version = 1
       AND planned_start IS NULL AND planned_end IS NULL AND deleted_at IS NULL) <> 3 THEN
    RAISE EXCEPTION '0042 D065 setup requires the expected direct Worker session, admin membership, active product, and null-dated version-1 stages.';
  END IF;
END;
$worker_preflight$;

SELECT schedule_version AS test_fixed_schedule_version_before
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_fixed_product'::uuid, :'test_actor'::uuid) \gset

\set test_product :test_fixed_product
\set test_stage :test_explicit_stage
\set test_stage_version 1
\set test_operation_id 4b420000-0000-4000-8000-000000000301
\set test_start 2026-11-03
\set test_end 2026-11-05
\set test_justification 'Synthetic hierarchy movement D065 date setup'
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_stage :test_partial_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000302
\set test_start __NULL__
\set test_end 2026-11-05
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_stage :fixed_successor_stage
\set test_operation_id 4b420000-0000-4000-8000-000000000303
\set test_start 2026-11-06
\set test_end 2026-11-10
\i db/verification/phase4b5-seed-one-stage-date.sql

SELECT set_config('jlproject.phase4b3c2_stage_seed_postflight', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_fixed_product',
  'versionBefore', :'test_fixed_schedule_version_before',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage',
  'fixedSuccessorStage', :'fixed_successor_stage')::text, false);
DO $worker_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c2_stage_seed_postflight')::jsonb;
  v_cursor bigint;
BEGIN
  IF (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = (v_scope->>'workspace')::uuid
      AND product_id = (v_scope->>'product')::uuid AND version = 2 AND
      ((id = (v_scope->>'explicitStage')::uuid AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05') OR
       (id = (v_scope->>'partialStage')::uuid AND planned_start IS NULL AND planned_end = DATE '2026-11-05') OR
       (id = (v_scope->>'fixedSuccessorStage')::uuid AND planned_start = DATE '2026-11-06' AND planned_end = DATE '2026-11-10'))) <> 3 THEN
    RAISE EXCEPTION '0042 audited D065 setup did not produce all three expected intervals at stage version 2.';
  END IF;
  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, (v_scope->>'actor')::uuid);
  IF v_cursor <> (v_scope->>'versionBefore')::bigint + 3 THEN
    RAISE EXCEPTION '0042 fixed-product cursor did not advance once for each audited stage-date operation.';
  END IF;
END;
$worker_postflight$;
SELECT schedule_version AS test_fixed_schedule_version
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_fixed_product'::uuid, :'test_actor'::uuid) \gset
\echo Worker psql variables: test_workspace=:test_workspace test_actor=:test_actor test_fixed_product=:test_fixed_product test_explicit_stage=:test_explicit_stage test_partial_stage=:test_partial_stage fixed_successor_stage=:fixed_successor_stage test_fixed_schedule_version_before=:test_fixed_schedule_version_before test_fixed_schedule_version=:test_fixed_schedule_version
