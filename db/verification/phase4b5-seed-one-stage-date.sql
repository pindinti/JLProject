-- Apply one explicit D065 boundary with its own audited Worker operation and transaction.
\set ON_ERROR_STOP on

SELECT set_config('jlproject.phase4b5_stage_date_seed_request', jsonb_build_object(
  'disposable', :'phase4b5_disposable_child_verified',
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_product',
  'stage', :'test_stage', 'version', :'test_stage_version', 'operation', :'test_operation_id',
  'start', CASE WHEN :'test_start' = '__NULL__' THEN NULL ELSE NULLIF(:'test_start', '') END,
  'end', CASE WHEN :'test_end' = '__NULL__' THEN NULL ELSE NULLIF(:'test_end', '') END,
  'justification', :'test_justification')::text, false);

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
DO $stage_date_seed$
DECLARE
  v_request jsonb := current_setting('jlproject.phase4b5_stage_date_seed_request')::jsonb;
  v_workspace uuid := (v_request->>'workspace')::uuid;
  v_actor uuid := (v_request->>'actor')::uuid;
  v_product uuid := (v_request->>'product')::uuid;
  v_stage uuid := (v_request->>'stage')::uuid;
  v_expected_version bigint := (v_request->>'version')::bigint;
  v_operation uuid := (v_request->>'operation')::uuid;
  v_start date := CASE WHEN v_request->>'start' IN ('', '__NULL__') THEN NULL
    ELSE (v_request->>'start')::date END;
  v_end date := CASE WHEN v_request->>'end' IN ('', '__NULL__') THEN NULL
    ELSE (v_request->>'end')::date END;
  v_justification text := v_request->>'justification';
  v_discipline uuid;
  v_result jsonb;
  v_version_before bigint;
  v_version_after bigint;
  v_stage_version bigint;
  v_stage_start date;
  v_stage_end date;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR v_request->>'disposable' IS DISTINCT FROM 'true' OR
     v_workspace IS NULL OR v_actor IS NULL OR v_product IS NULL OR v_stage IS NULL OR
     v_operation IS NULL OR v_expected_version IS NULL OR v_justification IS NULL OR
     char_length(v_justification) NOT BETWEEN 10 AND 2000 OR
     v_justification <> btrim(v_justification) OR v_justification ~ '[[:cntrl:]]' OR
     NOT has_function_privilege(current_user,
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Expected a direct authorized Worker session, verified disposable child, and valid audit justification.';
  END IF;

  SELECT stage.discipline_id, stage.version, stage.planned_start, stage.planned_end
    INTO STRICT v_discipline, v_stage_version, v_stage_start, v_stage_end
    FROM public.discipline_stages AS stage
    JOIN public.products AS product ON product.workspace_id = stage.workspace_id
      AND product.id = stage.product_id
    WHERE stage.workspace_id = v_workspace AND stage.product_id = v_product AND stage.id = v_stage
      AND stage.deleted_at IS NULL AND product.active;
  IF v_stage_version <> v_expected_version OR v_stage_start IS NOT NULL OR v_stage_end IS NOT NULL OR
     (v_start IS NOT NULL AND v_end IS NOT NULL AND v_start > v_end) THEN
    RAISE EXCEPTION 'Stage-date seed precondition differs: stage %, version %, dates % to %.',
      v_stage, v_stage_version, v_stage_start, v_stage_end;
  END IF;

  SELECT cursor_state.schedule_version INTO STRICT v_version_before
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_state;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'stage_dates_changed', true),
    set_config('jlproject.schedule_justification', v_justification, true);
  v_result := public.change_discipline_stage_dates(v_workspace, v_product, v_discipline, v_stage,
    v_actor, v_operation, v_start, v_end, v_justification, v_expected_version);
  IF v_result->>'status' IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'Audited stage-date seed operation % failed: %', v_operation, v_result;
  END IF;

  SELECT stage.version, stage.planned_start, stage.planned_end
    INTO STRICT v_stage_version, v_stage_start, v_stage_end
    FROM public.discipline_stages AS stage
    WHERE stage.workspace_id = v_workspace AND stage.product_id = v_product AND stage.id = v_stage;
  SELECT cursor_state.schedule_version INTO STRICT v_version_after
    FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor) AS cursor_state;
  IF v_stage_version <> v_expected_version + 1 OR v_stage_start IS DISTINCT FROM v_start OR
     v_stage_end IS DISTINCT FROM v_end OR v_version_after <> v_version_before + 1 THEN
    RAISE EXCEPTION 'Audited stage-date operation % produced unexpected dates or versions.', v_operation;
  END IF;
END;
$stage_date_seed$;
COMMIT;
