\set ON_ERROR_STOP on

-- Run only on a disposable Development-derived branch; this script commits synthetic fixtures.

CREATE TEMP TABLE phase2_fixture (
  kind text PRIMARY KEY, workspace_id uuid NOT NULL, actor_id uuid NOT NULL,
  product_id uuid NOT NULL, original_version bigint NOT NULL
) ON COMMIT PRESERVE ROWS;

BEGIN;
SET LOCAL lock_timeout = '5s';
DO $seed$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_product uuid;
  v_kind text;
BEGIN
  SELECT workspace_id, auth_user_id INTO v_workspace, v_actor
    FROM public.workspace_memberships WHERE active AND role = 'admin'
    ORDER BY workspace_id, auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN RAISE EXCEPTION 'No Development administrator is available.'; END IF;
  FOREACH v_kind IN ARRAY ARRAY['vigente', 'em_estudo', 'arquivado'] LOOP
    INSERT INTO public.products
      (workspace_id, name, active, planning_classification, created_by, updated_by)
      VALUES (v_workspace, 'P2 isolated status ' || v_kind || ' ' || gen_random_uuid()::text,
        v_kind <> 'arquivado', CASE WHEN v_kind = 'arquivado' THEN 'vigente' ELSE v_kind END,
        v_actor, v_actor) RETURNING id INTO v_product;
    INSERT INTO phase2_fixture VALUES (v_kind, v_workspace, v_actor, v_product, 1);
  END LOOP;
END;
$seed$;
COMMIT;

BEGIN;
DO $transitions$
DECLARE
  v_row record;
  v_target text;
  v_result jsonb;
  v_before bigint;
  v_after bigint;
BEGIN
  FOR v_row IN SELECT * FROM phase2_fixture ORDER BY kind LOOP
    v_target := CASE v_row.kind WHEN 'vigente' THEN 'em_estudo'
      WHEN 'em_estudo' THEN 'vigente' ELSE 'em_estudo' END;
    SELECT schedule_version INTO v_before FROM public.read_product_schedule_cursor(
      v_row.workspace_id, v_row.product_id, v_row.actor_id);
    SELECT public.change_product_status(v_row.workspace_id, v_row.product_id,
      v_row.actor_id, v_target, 1, 'P2 isolated authorized status change') INTO v_result;
    IF v_result->>'status' <> 'updated' OR v_result->'product'->>'version' <> '2' THEN
      RAISE EXCEPTION 'Status transition failed for %: %', v_row.kind, v_result;
    END IF;
    SELECT schedule_version INTO v_after FROM public.read_product_schedule_cursor(
      v_row.workspace_id, v_row.product_id, v_row.actor_id);
    IF v_after <> v_before + 1 OR NOT EXISTS (
      SELECT 1 FROM public.list_product_schedule_operations(
        v_row.workspace_id, v_row.product_id, v_row.actor_id, v_after + 1, 10) op
      WHERE op.schedule_version = v_after
        AND op.operation_type = 'product_status_changed'
        AND op.actor_id = v_row.actor_id
        AND op.justification = 'P2 isolated authorized status change'
        AND jsonb_array_length(op.events) = 1) THEN
      RAISE EXCEPTION 'Audit/version verification failed for %.', v_row.kind;
    END IF;
    SELECT public.change_product_status(v_row.workspace_id, v_row.product_id,
      v_row.actor_id, v_target, 1, 'P2 isolated stale status change') INTO v_result;
    IF v_result->>'status' <> 'stale' OR
       (SELECT schedule_version FROM public.read_product_schedule_cursor(
          v_row.workspace_id, v_row.product_id, v_row.actor_id)) <> v_after THEN
      RAISE EXCEPTION 'Stale status operation changed the schedule.';
    END IF;
    SELECT public.change_product_status(v_row.workspace_id, v_row.product_id,
      gen_random_uuid(), 'arquivado', 2, 'P2 isolated denied status change') INTO v_result;
    IF v_result->>'status' <> 'denied' THEN RAISE EXCEPTION 'Unauthorized status change succeeded.'; END IF;
    SELECT public.change_product_status(gen_random_uuid(), v_row.product_id,
      v_row.actor_id, 'arquivado', 2, 'P2 isolated foreign workspace') INTO v_result;
    IF v_result->>'status' <> 'denied' THEN RAISE EXCEPTION 'Cross-workspace status change succeeded.'; END IF;
  END LOOP;
END;
$transitions$;
COMMIT;

BEGIN;
DO $archive_restore$
DECLARE
  v_row record;
  v_result jsonb;
BEGIN
  SELECT * INTO v_row FROM phase2_fixture WHERE kind = 'vigente';
  SELECT public.change_product_status(v_row.workspace_id, v_row.product_id,
    v_row.actor_id, 'arquivado', 2, 'P2 isolated archive transition') INTO v_result;
  IF v_result->>'status' <> 'updated' OR v_result->'product'->>'active' <> 'false' THEN
    RAISE EXCEPTION 'Archive transition failed.';
  END IF;
  IF (SELECT count(*) FROM public.list_product_schedule_operations(
    v_row.workspace_id, v_row.product_id, v_row.actor_id, 1000000, 10)) <> 3 THEN
    RAISE EXCEPTION 'Archive version advanced more than once.';
  END IF;
END;
$archive_restore$;
COMMIT;

BEGIN;
DO $restore$
DECLARE
  v_row record;
  v_result jsonb;
BEGIN
  SELECT * INTO v_row FROM phase2_fixture WHERE kind = 'vigente';
  SELECT public.change_product_status(v_row.workspace_id, v_row.product_id,
    v_row.actor_id, 'em_estudo', 3, 'P2 isolated explicit restoration') INTO v_result;
  IF v_result->>'status' <> 'updated' OR v_result->'product'->>'planningClassification' <> 'em_estudo' OR
     v_result->'product'->>'active' <> 'true' THEN
    RAISE EXCEPTION 'Explicit archived restoration failed.';
  END IF;
END;
$restore$;
COMMIT;

BEGIN;
DO $gantt$
DECLARE
  v_row record;
  v_activity uuid;
  v_target date;
BEGIN
  FOR v_row IN SELECT * FROM phase2_fixture WHERE kind IN ('vigente', 'em_estudo') LOOP
    v_target := CASE WHEN v_row.kind = 'vigente' THEN DATE '2040-01-01' ELSE DATE '2030-01-01' END;
    PERFORM set_config('jlproject.schedule_actor_id', v_row.actor_id::text, true);
    PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true);
    PERFORM set_config('jlproject.schedule_justification', 'P2 isolated Gantt source verification', true);
    INSERT INTO public.stage_activities
      (workspace_id, product_id, discipline_id, stage_id, name,
       planned_start, planned_end, display_order, created_by, updated_by)
      VALUES (v_row.workspace_id, v_row.product_id, NULL, NULL, 'P2 isolated root activity',
        v_target, v_target + 1, 0, v_row.actor_id, v_row.actor_id)
      RETURNING id INTO v_activity;
    IF v_activity IS NULL THEN RAISE EXCEPTION 'Synthetic root activity was not created.'; END IF;
  END LOOP;
END;
$gantt$;
COMMIT;

DO $projection$
DECLARE
  v_study uuid;
  v_current uuid;
BEGIN
  SELECT product_id INTO v_study FROM phase2_fixture WHERE kind = 'vigente';
  SELECT product_id INTO v_current FROM phase2_fixture WHERE kind = 'em_estudo';
  IF EXISTS (SELECT 1 FROM public.products WHERE id = v_study
      AND active AND planning_classification = 'vigente') OR
     NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_current
      AND active AND planning_classification = 'vigente') OR
     EXISTS (SELECT 1 FROM public.stage_activities a JOIN public.products p
       ON p.id = a.product_id AND p.workspace_id = a.workspace_id
       WHERE a.product_id = v_study AND p.active AND p.planning_classification = 'vigente') OR
     (SELECT min(a.planned_start) FROM public.stage_activities a JOIN public.products p
       ON p.id = a.product_id AND p.workspace_id = a.workspace_id
       WHERE a.product_id IN (v_study, v_current) AND p.active
         AND p.planning_classification = 'vigente') <> DATE '2030-01-01' THEN
    RAISE EXCEPTION 'Executive status or date-bound projection failed.';
  END IF;
END;
$projection$;

SELECT kind, active, planning_classification, version
FROM phase2_fixture f JOIN public.products p ON p.id = f.product_id ORDER BY kind;
