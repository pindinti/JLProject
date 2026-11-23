-- Set one D065 boundary through the public audited Worker routine per transaction.
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
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_workspace.'; END; $$;
\endif
\if :{?test_actor}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_actor.'; END; $$;
\endif
\if :{?test_product}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_product.'; END; $$;
\endif
\if :{?test_stage}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_stage.'; END; $$;
\endif
\if :{?test_stage_version}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_stage_version.'; END; $$;
\endif
\if :{?test_operation}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_operation.'; END; $$;
\endif
\if :{?test_start}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_start as YYYY-MM-DD or an empty string for NULL.'; END; $$;
\endif
\if :{?test_end}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_end as YYYY-MM-DD or an empty string for NULL.'; END; $$;
\endif

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b3c4_stage_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_product',
  'stage', :'test_stage', 'version', :'test_stage_version', 'operation', :'test_operation',
  'start', NULLIF(:'test_start', ''), 'end', NULLIF(:'test_end', ''))::text, true),
  set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'test_operation', true),
  set_config('jlproject.schedule_operation_type', 'stage_dates_changed', true),
  set_config('jlproject.schedule_justification', 'Synthetic clone source D065 date setup', true);

DO $stage_update$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_stage_seed')::jsonb;
  v_discipline_id uuid;
  v_result jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'Stage-date fixture must use a direct Worker session.';
  END IF;
  SELECT discipline_id INTO STRICT v_discipline_id FROM public.discipline_stages
    WHERE workspace_id = (v_scope->>'workspace')::uuid
      AND product_id = (v_scope->>'product')::uuid
      AND id = (v_scope->>'stage')::uuid AND deleted_at IS NULL;
  v_result := public.change_discipline_stage_dates(
    (v_scope->>'workspace')::uuid, (v_scope->>'product')::uuid, v_discipline_id,
    (v_scope->>'stage')::uuid, (v_scope->>'actor')::uuid, (v_scope->>'operation')::uuid,
    NULLIF(v_scope->>'start', '')::date, NULLIF(v_scope->>'end', '')::date,
    'Synthetic clone source D065 date setup', (v_scope->>'version')::bigint);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Synthetic stage date update failed: %', v_result;
  END IF;
END;
$stage_update$;
COMMIT;
