-- Run with real psql only on a verified disposable Development child after separately approved migrations.
-- The setup commits a synthetic product so the audit transaction can be tested independently. Discard the child afterward.
\set ON_ERROR_STOP on
\if :{?phase4b2_disposable_branch_verified}
\else
\set phase4b2_disposable_branch_verified false
\endif
\if :phase4b2_disposable_branch_verified
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A verified disposable Development child is required.'; END; $$;
\endif

BEGIN;
CREATE TEMP TABLE dependency_test_ids (workspace_id uuid, product_id uuid, actor_id uuid,
  predecessor_id uuid, first_id uuid, second_id uuid) ON COMMIT PRESERVE ROWS;

DO $$
DECLARE
  v_workspace uuid := gen_random_uuid();
  v_product uuid := gen_random_uuid();
  v_actor uuid;
  v_predecessor uuid := gen_random_uuid();
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_first uuid := least(v_a, v_b);
  v_second uuid := greatest(v_a, v_b);
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner'
     OR has_function_privilege('jlproject_worker',
       'public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Expected dormant Phase 4B.2 routines and the isolated owner role.';
  END IF;
  SELECT auth_user_id INTO STRICT v_actor FROM public.workspace_memberships WHERE active LIMIT 1;
  INSERT INTO public.workspaces (id, name) VALUES (v_workspace, 'Synthetic Phase 4B.2 workspace');
  INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
    VALUES (v_workspace, v_actor, 'admin', true);
  INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
    VALUES (v_product, v_workspace, 'Synthetic Phase 4B.2 product', v_actor, v_actor);
  INSERT INTO public.stage_activities (id, workspace_id, product_id, name, planned_start, planned_end,
    display_order, created_by, updated_by) VALUES
    (v_predecessor, v_workspace, v_product, 'Predecessor', '2026-11-12', '2026-11-12', 0, v_actor, v_actor),
    (v_first, v_workspace, v_product, 'First successor', '2026-11-10', '2026-11-10', 1, v_actor, v_actor),
    (v_second, v_workspace, v_product, 'Second successor', '2026-11-11', '2026-11-11', 2, v_actor, v_actor);
  INSERT INTO public.product_schedule_dependencies (workspace_id, product_id, endpoint_kind,
    predecessor_activity_id, successor_activity_id) VALUES (v_workspace, v_product, 'activity', v_first, v_second);
  INSERT INTO dependency_test_ids VALUES (v_workspace, v_product, v_actor, v_predecessor, v_first, v_second);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT SELECT ON dependency_test_ids TO jlproject_date_executor;

CREATE FUNCTION pg_temp.reject_second_dependency_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id::text = current_setting('jlproject.test_dependency_failure_id', true) THEN
    IF NOT EXISTS (SELECT 1 FROM public.stage_activities
        WHERE id = current_setting('jlproject.test_dependency_first_id')::uuid AND planned_end = DATE '2026-11-13')
       OR NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies
        WHERE id = current_setting('jlproject.test_dependency_edge_id')::uuid) THEN
      RAISE EXCEPTION 'Failure injection was expected after the new edge and first date write.';
    END IF;
    RAISE EXCEPTION 'Synthetic late dependency write failure' USING ERRCODE = 'ZX042';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER dependency_test_late_failure BEFORE UPDATE ON public.stage_activities
  FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_second_dependency_update();

SET LOCAL ROLE jlproject_date_executor;
DO $$
DECLARE
  v_ids dependency_test_ids%ROWTYPE;
  v_read jsonb;
  v_result jsonb;
  v_changes jsonb;
  v_edge jsonb;
  v_cycle jsonb;
  v_version bigint;
  v_operation uuid := gen_random_uuid();
  v_reason constant text := 'Synthetic reviewed dependency change';
BEGIN
  SELECT * INTO STRICT v_ids FROM dependency_test_ids;
  v_read := public.read_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id, false);
  v_version := (v_read#>>'{snapshot,scheduleVersion}')::bigint;
  IF v_read->>'status' IS DISTINCT FROM 'ok' OR v_version IS NULL THEN RAISE EXCEPTION 'Missing dependency snapshot.'; END IF;
  v_edge := jsonb_build_object('kind', 'add', 'dependency', jsonb_build_object('id', gen_random_uuid(),
    'predecessor', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id, 'id', v_ids.predecessor_id),
    'successor', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id, 'id', v_ids.first_id)));
  v_cycle := jsonb_build_object('kind', 'add', 'dependency', jsonb_build_object('id', gen_random_uuid(),
    'predecessor', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id, 'id', v_ids.second_id),
    'successor', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id, 'id', v_ids.first_id)));
  SELECT jsonb_agg(jsonb_build_object('entity', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id,
      'id', item->'id'), 'expectedVersion', item->'version', 'source', 'cascade', 'before', item->'dates',
      'after', jsonb_build_object('start', next_date, 'end', next_date), 'planningBefore', item->'planning',
      'planningAfter', item->'planning')) INTO v_changes
  FROM jsonb_array_elements(v_read#>'{snapshot,entities}') AS item
  JOIN (VALUES (v_ids.first_id, '2026-11-13'), (v_ids.second_id, '2026-11-16')) AS proposed(id, next_date)
    ON proposed.id = (item->>'id')::uuid;
  IF jsonb_array_length(v_changes) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Missing synthetic changes.'; END IF;
  v_result := public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id,
    v_operation, v_version, 1, v_read->>'fingerprint', v_reason, v_changes, v_edge);
  IF v_result->>'status' IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'Calendar mismatch was accepted.'; END IF;
  v_result := public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id,
    v_operation, v_version, 0, v_read->>'fingerprint', v_reason, '[]', v_cycle);
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'Database accepted a cycle.'; END IF;

  PERFORM set_config('jlproject.test_dependency_failure_id', v_ids.second_id::text, true);
  PERFORM set_config('jlproject.test_dependency_first_id', v_ids.first_id::text, true);
  PERFORM set_config('jlproject.test_dependency_edge_id', v_edge#>>'{dependency,id}', true);
  BEGIN
    PERFORM public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id,
      v_operation, v_version, 0, v_read->>'fingerprint', v_reason, v_changes, v_edge);
    RAISE EXCEPTION 'Synthetic failure did not fire.';
  EXCEPTION WHEN SQLSTATE 'ZX042' THEN NULL;
  END;
  IF public.read_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id, false) IS DISTINCT FROM v_read
    OR EXISTS (SELECT 1 FROM public.activity_date_changes WHERE product_id = v_ids.product_id)
    OR EXISTS (SELECT 1 FROM public.product_schedule_operations WHERE product_id = v_ids.product_id AND operation_id = v_operation) THEN
    RAISE EXCEPTION 'A failed dependency confirmation left persistent changes.';
  END IF;

  PERFORM set_config('jlproject.test_dependency_failure_id', '', true);
  v_result := public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id,
    v_operation, v_version, 0, v_read->>'fingerprint', v_reason, v_changes, v_edge);
  IF v_result->>'status' IS DISTINCT FROM 'applied' OR (v_result->>'scheduleVersion')::bigint IS DISTINCT FROM v_version + 1
    OR (SELECT count(DISTINCT audit.operation_id) FROM public.activity_date_changes AS audit
      JOIN public.product_schedule_operation_source_events AS link ON link.workspace_id = audit.workspace_id
        AND link.product_id = audit.product_id AND link.source_ledger = 'activity_date_changes'
        AND link.source_operation_id = audit.operation_id AND link.source_event_id = audit.operation_id
      WHERE audit.product_id = v_ids.product_id AND audit.actor_id = v_ids.actor_id AND audit.reason = v_reason
        AND link.operation_id = v_operation AND link.schedule_version = v_version + 1) <> 2
    OR (SELECT count(*) FROM public.product_schedule_operations WHERE product_id = v_ids.product_id AND operation_id = v_operation) <> 1 THEN
    RAISE EXCEPTION 'Expected two exact activity events and one schedule advance.';
  END IF;
  v_result := public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id,
    v_operation, v_version, 0, v_read->>'fingerprint', v_reason, v_changes, v_edge);
  IF v_result->>'status' IS DISTINCT FROM 'replayed' THEN RAISE EXCEPTION 'Identical confirmation was not replayed.'; END IF;
END;
$$;

ROLLBACK;

BEGIN;
GRANT jlproject_date_executor TO neondb_owner WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT SELECT ON dependency_test_ids TO jlproject_date_executor;
SET LOCAL ROLE jlproject_date_executor;

DO $$
DECLARE
  v_ids dependency_test_ids%ROWTYPE;
  v_read jsonb;
  v_saved jsonb;
  v_result jsonb;
  v_operation uuid := gen_random_uuid();
BEGIN
  SELECT * INTO STRICT v_ids FROM dependency_test_ids;
  v_read := public.read_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id, false);
  SELECT item INTO STRICT v_saved FROM jsonb_array_elements(v_read#>'{snapshot,entities}') AS item
    WHERE item->>'id' = v_ids.predecessor_id::text;
  v_result := public.confirm_schedule_dependencies(v_ids.workspace_id, v_ids.product_id, v_ids.actor_id, v_operation,
    (v_read#>>'{snapshot,scheduleVersion}')::bigint, 0, v_read->>'fingerprint', 'Synthetic direct date confirmation',
    jsonb_build_array(jsonb_build_object('entity', jsonb_build_object('kind', 'activity', 'productId', v_ids.product_id,
      'id', v_ids.predecessor_id), 'expectedVersion', v_saved->'version', 'source', 'direct', 'before', v_saved->'dates',
      'after', jsonb_build_object('start', '2026-11-13', 'end', '2026-11-13'),
      'planningBefore', v_saved->'planning', 'planningAfter', v_saved->'planning')), 'null');
  IF v_result->>'status' IS DISTINCT FROM 'applied' OR NOT EXISTS (
    SELECT 1 FROM public.product_schedule_operation_source_events AS link
    JOIN public.activity_date_changes AS audit ON audit.workspace_id = link.workspace_id
      AND audit.product_id = link.product_id AND audit.operation_id = link.source_event_id
    WHERE link.workspace_id = v_ids.workspace_id AND link.product_id = v_ids.product_id
      AND link.operation_id = v_operation AND link.source_ledger = 'activity_date_changes'
      AND audit.activity_id = v_ids.predecessor_id AND audit.operation_id <> v_operation
  ) THEN RAISE EXCEPTION 'First date-only event was not linked to its Living Schedule group.'; END IF;
END;
$$;

ROLLBACK;
