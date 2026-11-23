-- Transition the Em estudo and Arquivado sources using the public audited status workflow.
-- Dependency links are already committed; this script never edits the dependency graph.
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

SELECT set_config('jlproject.phase4b3c4_status_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor')::text, false);

DO $preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_status_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.change_product_status(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Expected an authorized direct Worker session for source status transitions.';
  END IF;
END;
$preflight$;

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
DO $study_status$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_status_seed')::jsonb;
  v_product public.products%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_product FROM public.products WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND name = 'Synthetic Phase 4B.3c.4 study source';
  v_result := public.change_product_status(v_product.workspace_id, v_product.id,
    (v_scope->>'actor')::uuid, 'em_estudo', v_product.version,
    'Synthetic clone source set to Em estudo');
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Em estudo source transition failed: %', v_result;
  END IF;
END;
$study_status$;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
DO $archived_status$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_status_seed')::jsonb;
  v_product public.products%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_product FROM public.products WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND name = 'Synthetic Phase 4B.3c.4 archived source';
  v_result := public.change_product_status(v_product.workspace_id, v_product.id,
    (v_scope->>'actor')::uuid, 'arquivado', v_product.version,
    'Synthetic clone source set to Arquivado');
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Archived source transition failed: %', v_result;
  END IF;
END;
$archived_status$;
COMMIT;

DO $postflight$
DECLARE
  v_workspace uuid := (current_setting('jlproject.phase4b3c4_status_seed')::jsonb->>'workspace')::uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
        AND name = 'Synthetic Phase 4B.3c.4 study source' AND active
        AND planning_classification = 'em_estudo') OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
        AND name = 'Synthetic Phase 4B.3c.4 archived source' AND NOT active
        AND planning_classification = 'vigente') THEN
    RAISE EXCEPTION 'Source status transitions did not produce the expected active and archived states.';
  END IF;
END;
$postflight$;

\echo Status setup committed: study source is Em estudo; archived root-linked source is Arquivado.
