-- Establish complete and partial deletion-fixture stage boundaries through audited Worker calls.
\set ON_ERROR_STOP on
SELECT set_config('jlproject.phase4b3c3_stage_seed_scope', jsonb_build_object(
  'disposable', :'phase4b5_disposable_child_verified', 'workspace', :'test_workspace',
  'actor', :'test_actor', 'fixedProduct', :'test_fixed_product', 'partialProduct', :'test_partial_product',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage')::text, false);
DO $worker_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_stage_seed_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR v_scope->>'disposable' IS DISTINCT FROM 'true' OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = (v_scope->>'actor')::uuid AND active AND role = 'admin') OR
     (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace AND active
       AND id IN ((v_scope->>'fixedProduct')::uuid, (v_scope->>'partialProduct')::uuid)) <> 2 OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = (v_scope->>'fixedProduct')::uuid AND id = (v_scope->>'explicitStage')::uuid
       AND version = 1 AND planned_start IS NULL AND planned_end IS NULL AND deleted_at IS NULL) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = v_workspace
       AND product_id = (v_scope->>'partialProduct')::uuid AND id = (v_scope->>'partialStage')::uuid
       AND version = 1 AND planned_start IS NULL AND planned_end IS NULL AND deleted_at IS NULL) THEN
    RAISE EXCEPTION '0043 D065 setup requires direct Worker identity, admin membership, active products, and null-dated version-1 stages.';
  END IF;
END;
$worker_preflight$;

SELECT schedule_version AS test_fixed_schedule_version_before
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_fixed_product'::uuid, :'test_actor'::uuid) \gset
SELECT schedule_version AS test_partial_schedule_version_before
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_partial_product'::uuid, :'test_actor'::uuid) \gset

\set test_product :test_fixed_product
\set test_stage :test_explicit_stage
\set test_stage_version 1
\set test_operation_id 4b430000-0000-4000-8000-000000000301
\set test_start 2026-11-03
\set test_end 2026-11-05
\set test_justification 'Synthetic schedule deletion D065 date setup'
\i db/verification/phase4b5-seed-one-stage-date.sql

\set test_product :test_partial_product
\set test_stage :test_partial_stage
\set test_operation_id 4b430000-0000-4000-8000-000000000302
\set test_start __NULL__
\set test_end 2026-11-05
\i db/verification/phase4b5-seed-one-stage-date.sql

SELECT set_config('jlproject.phase4b3c3_stage_seed_postflight', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'fixedProduct', :'test_fixed_product', 'partialProduct', :'test_partial_product',
  'fixedVersionBefore', :'test_fixed_schedule_version_before',
  'partialVersionBefore', :'test_partial_schedule_version_before',
  'explicitStage', :'test_explicit_stage', 'partialStage', :'test_partial_stage')::text, false);
DO $worker_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_stage_seed_postflight')::jsonb;
  v_cursor bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = (v_scope->>'workspace')::uuid
      AND product_id = (v_scope->>'fixedProduct')::uuid AND id = (v_scope->>'explicitStage')::uuid
      AND planned_start = DATE '2026-11-03' AND planned_end = DATE '2026-11-05' AND version = 2) OR
     NOT EXISTS (SELECT 1 FROM public.discipline_stages WHERE workspace_id = (v_scope->>'workspace')::uuid
      AND product_id = (v_scope->>'partialProduct')::uuid AND id = (v_scope->>'partialStage')::uuid
      AND planned_start IS NULL AND planned_end = DATE '2026-11-05' AND version = 2) THEN
    RAISE EXCEPTION '0043 audited D065 setup did not produce the complete and partial expected intervals at stage version 2.';
  END IF;
  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(
    (v_scope->>'workspace')::uuid, (v_scope->>'fixedProduct')::uuid, (v_scope->>'actor')::uuid);
  IF v_cursor <> (v_scope->>'fixedVersionBefore')::bigint + 1 THEN
    RAISE EXCEPTION '0043 fixed-product cursor did not advance once for its audited stage-date operation.';
  END IF;
  SELECT schedule_version INTO STRICT v_cursor FROM public.read_product_schedule_cursor(
    (v_scope->>'workspace')::uuid, (v_scope->>'partialProduct')::uuid, (v_scope->>'actor')::uuid);
  IF v_cursor <> (v_scope->>'partialVersionBefore')::bigint + 1 THEN
    RAISE EXCEPTION '0043 partial-product cursor did not advance once for its audited stage-date operation.';
  END IF;
END;
$worker_postflight$;

SELECT schedule_version AS test_fixed_schedule_version
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_fixed_product'::uuid, :'test_actor'::uuid) \gset
SELECT schedule_version AS test_partial_schedule_version
FROM public.read_product_schedule_cursor(:'test_workspace'::uuid, :'test_partial_product'::uuid, :'test_actor'::uuid) \gset
\echo Worker psql variables: test_workspace=:test_workspace test_actor=:test_actor test_fixed_product=:test_fixed_product test_explicit_stage=:test_explicit_stage test_fixed_schedule_version_before=:test_fixed_schedule_version_before test_fixed_schedule_version=:test_fixed_schedule_version test_partial_product=:test_partial_product test_partial_stage=:test_partial_stage test_partial_schedule_version_before=:test_partial_schedule_version_before test_partial_schedule_version=:test_partial_schedule_version
