-- Add complete/partial stage dates and root working-plan activities to imported sources.
-- Run directly as jlproject_worker; every stage-date edit commits in its own transaction.
\set ON_ERROR_STOP on
\if :{?phase4b5_disposable_child_verified}
\else
\set phase4b5_disposable_child_verified false
\endif
\if :phase4b5_disposable_child_verified
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A verified disposable Development child is required.'; END; $$;
\endif
\if :{?test_workspace}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_workspace from phase4b3c4-clone-seed-owner.sql.'; END; $$;
\endif
\if :{?test_actor}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_actor from phase4b3c4-clone-seed-owner.sql.'; END; $$;
\endif

SELECT set_config('jlproject.phase4b3c4_schedule_worker_scope', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor')::text, false);

DO $worker_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_schedule_worker_scope')::jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)',
       'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = (v_scope->>'workspace')::uuid
       AND auth_user_id = (v_scope->>'actor')::uuid AND active AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Expected a direct authorized Worker session for clone schedule setup.';
  END IF;
END;
$worker_preflight$;

SELECT id::text AS vigente_product FROM public.products
  WHERE workspace_id = :'test_workspace'::uuid AND name = 'Synthetic Phase 4B.3c.4 vigente source' \gset
SELECT id::text AS study_product FROM public.products
  WHERE workspace_id = :'test_workspace'::uuid AND name = 'Synthetic Phase 4B.3c.4 study source' \gset
SELECT id::text AS archived_product FROM public.products
  WHERE workspace_id = :'test_workspace'::uuid AND name = 'Synthetic Phase 4B.3c.4 archived source' \gset
SELECT id::text AS empty_product FROM public.products
  WHERE workspace_id = :'test_workspace'::uuid AND name = 'Synthetic Phase 4B.3c.4 empty source' \gset

SELECT stage.id::text AS vigente_complete_stage, stage.version AS vigente_complete_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'vigente_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CV-D1-S1' \gset
SELECT stage.id::text AS vigente_partial_stage, stage.version AS vigente_partial_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'vigente_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CV-D1-S2' \gset
SELECT stage.id::text AS study_complete_stage, stage.version AS study_complete_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'study_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CS-D1-S1' \gset
SELECT stage.id::text AS study_partial_stage, stage.version AS study_partial_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'study_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CS-D1-S2' \gset
SELECT stage.id::text AS archived_complete_stage, stage.version AS archived_complete_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'archived_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CA-D1-S1' \gset
SELECT stage.id::text AS archived_partial_stage, stage.version AS archived_partial_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'archived_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CA-D1-S2' \gset
SELECT stage.id::text AS empty_complete_stage, stage.version AS empty_complete_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'empty_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CE-D1-S1' \gset
SELECT stage.id::text AS empty_partial_stage, stage.version AS empty_partial_version
FROM public.discipline_stages stage JOIN public.product_disciplines discipline
  ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
  AND discipline.id = stage.discipline_id
WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'empty_product'::uuid
  AND discipline.short_code = 'D1' AND stage.display_name = 'CE-D1-S2' \gset

\set test_product :vigente_product
\set test_stage :vigente_complete_stage
\set test_stage_version :vigente_complete_version
\set test_operation 4b440000-0000-4000-8000-000000000301
\set test_start 2026-11-02
\set test_end 2026-11-03
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql
\set test_stage :vigente_partial_stage
\set test_stage_version :vigente_partial_version
\set test_operation 4b440000-0000-4000-8000-000000000302
\set test_start ''
\set test_end 2026-11-05
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql

\set test_product :study_product
\set test_stage :study_complete_stage
\set test_stage_version :study_complete_version
\set test_operation 4b440000-0000-4000-8000-000000000303
\set test_start 2026-11-02
\set test_end 2026-11-03
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql
\set test_stage :study_partial_stage
\set test_stage_version :study_partial_version
\set test_operation 4b440000-0000-4000-8000-000000000304
\set test_start ''
\set test_end 2026-11-05
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql

\set test_product :archived_product
\set test_stage :archived_complete_stage
\set test_stage_version :archived_complete_version
\set test_operation 4b440000-0000-4000-8000-000000000305
\set test_start 2026-11-02
\set test_end 2026-11-03
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql
\set test_stage :archived_partial_stage
\set test_stage_version :archived_partial_version
\set test_operation 4b440000-0000-4000-8000-000000000306
\set test_start ''
\set test_end 2026-11-05
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql

\set test_product :empty_product
\set test_stage :empty_complete_stage
\set test_stage_version :empty_complete_version
\set test_operation 4b440000-0000-4000-8000-000000000307
\set test_start 2026-11-02
\set test_end 2026-11-03
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql
\set test_stage :empty_partial_stage
\set test_stage_version :empty_partial_version
\set test_operation 4b440000-0000-4000-8000-000000000308
\set test_start ''
\set test_end 2026-11-05
\i db/verification/phase4b3c4-clone-seed-worker-stage-date.sql

-- The root pair is a single audited operation per product and uses the public working-plan writer.
\set test_product :vigente_product
\set test_operation 4b440000-0000-4000-8000-000000000311
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b3c4_root_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_product')::text, true),
  set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'test_operation', true),
  set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
  set_config('jlproject.schedule_justification', 'Synthetic clone source root activity setup', true);
DO $root_pair$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_root_seed')::jsonb;
  v_predecessor jsonb;
  v_successor jsonb;
BEGIN
  IF current_user <> 'jlproject_worker' OR session_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'Root activity setup requires a direct Worker session.';
  END IF;
  v_predecessor := public.create_activity_with_working_plan(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, NULL, NULL,
    (v_scope->>'actor')::uuid, 'Synthetic vigente root predecessor', 'Synthetic activity',
    DATE '2026-11-12', DATE '2026-11-12', 900000, 'Synthetic root dependency endpoint', 1, 0);
  v_successor := public.create_activity_with_working_plan(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, NULL, NULL,
    (v_scope->>'actor')::uuid, 'Synthetic vigente root successor', 'Synthetic activity',
    DATE '2026-11-13', DATE '2026-11-13', 900001, 'Synthetic root dependency endpoint', 1, 0);
  IF v_predecessor->>'status' IS DISTINCT FROM 'created' OR
     v_successor->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Vigente root working-plan creation failed: %, %', v_predecessor, v_successor;
  END IF;
  RAISE NOTICE 'ROOT_SOURCE|vigente|%|%', v_predecessor->>'id', v_successor->>'id';
END;
$root_pair$;
COMMIT;

\set test_product :archived_product
\set test_operation 4b440000-0000-4000-8000-000000000312
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b3c4_root_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_product')::text, true),
  set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'test_operation', true),
  set_config('jlproject.schedule_operation_type', 'activity_created_with_dates', true),
  set_config('jlproject.schedule_justification', 'Synthetic clone source root activity setup', true);
DO $root_pair$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_root_seed')::jsonb;
  v_predecessor jsonb;
  v_successor jsonb;
BEGIN
  IF current_user <> 'jlproject_worker' OR session_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'Root activity setup requires a direct Worker session.';
  END IF;
  v_predecessor := public.create_activity_with_working_plan(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, NULL, NULL,
    (v_scope->>'actor')::uuid, 'Synthetic archived root predecessor', 'Synthetic activity',
    DATE '2026-11-12', DATE '2026-11-12', 900000, 'Synthetic root dependency endpoint', 1, 0);
  v_successor := public.create_activity_with_working_plan(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, NULL, NULL,
    (v_scope->>'actor')::uuid, 'Synthetic archived root successor', 'Synthetic activity',
    DATE '2026-11-13', DATE '2026-11-13', 900001, 'Synthetic root dependency endpoint', 1, 0);
  IF v_predecessor->>'status' IS DISTINCT FROM 'created' OR
     v_successor->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Archived root working-plan creation failed: %, %', v_predecessor, v_successor;
  END IF;
  RAISE NOTICE 'ROOT_SOURCE|archived|%|%', v_predecessor->>'id', v_successor->>'id';
END;
$root_pair$;
COMMIT;

\echo Worker clone schedule setup committed. Sources: :vigente_product :study_product :archived_product :empty_product
\echo Complete stage dates: 2026-11-02 through 2026-11-03. Partial stage dates: NULL through 2026-11-05.
\echo Root working-plan activities: Vigente and Arquivado, with 1 working day and calendar version 0.
