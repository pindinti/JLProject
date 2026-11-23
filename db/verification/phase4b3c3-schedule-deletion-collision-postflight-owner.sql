-- Run after the committed Worker collision and again after the rollback-only Worker runtime.
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
\i db/verification/phase4b3c3-schedule-deletion-collision-state-owner.sql
SELECT set_config('jlproject.phase4b3c3_collision_baseline', jsonb_build_object(
  'cursor', :'test_collision_cursor_before'::bigint, 'version', :'test_collision_version_before'::bigint,
  'before', :'test_collision_state_fingerprint', 'current', :'collision_state_fingerprint')::text, true) AS baseline \gset

DO $collision_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_collision_check')::jsonb;
  v_baseline jsonb := current_setting('jlproject.phase4b3c3_collision_baseline')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_activity uuid := (v_scope->>'activity')::uuid;
  v_operation uuid := (v_scope->>'operation')::uuid;
  v_version bigint := (v_baseline->>'version')::bigint;
  v_cursor bigint := (v_baseline->>'cursor')::bigint + 1;
  v_reason constant text := 'Synthetic committed deletion collision history';
  v_items jsonb := jsonb_build_array(jsonb_build_object('kind', 'activity', 'id', v_activity, 'version', v_version));
BEGIN
  IF (v_baseline->>'current') IS DISTINCT FROM (v_baseline->>'before') THEN
    RAISE EXCEPTION '0043 committed schedule, graph, cursor or audit rows outside the expected collision writes changed.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace AND product_id = v_product
       AND id = v_activity AND deleted_at IS NOT NULL AND deletion_operation_id = v_operation
       AND version = v_version + 1 AND updated_by = v_actor)
     OR NOT EXISTS (SELECT 1 FROM public.schedule_deletion_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND target_kind = 'activity'
       AND target_id = v_activity AND actor_id = v_actor AND reason = v_reason AND affected_items = v_items)
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operations WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND schedule_version = v_cursor
       AND actor_id = v_actor AND operation_type = 'schedule_deleted' AND justification = v_reason) THEN
    RAISE EXCEPTION '0043 expected exactly one committed deletion of the collision target with the audited actor and reason.';
  END IF;

  IF (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation) <> 2
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND schedule_version = v_cursor
       AND entity_type = 'activity' AND change_type = 'schedule_deleted' AND entity_id = v_activity)
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND schedule_version = v_cursor
       AND entity_type = 'stage_activities' AND change_type = 'stage_activities_deleted' AND entity_id = v_activity)
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_state WHERE workspace_id = v_workspace
       AND product_id = v_product AND schedule_version = v_cursor AND history_watermark = (
         SELECT max(event_id) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
           AND product_id = v_product AND operation_id = v_operation)) THEN
    RAISE EXCEPTION '0043 collision operation needs its two grouped events and one cursor advance.';
  END IF;

  IF (SELECT count(*) FROM public.product_schedule_operation_source_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_source_events WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND schedule_version = v_cursor
       AND source_ledger = 'schedule_deletion_events' AND source_operation_id = v_operation
       AND source_event_id = v_operation AND link_kind = 'audit_detail')
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_links WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation AND schedule_version = v_cursor
       AND source_ledger = 'schedule_deletion_events' AND source_operation_id = v_operation AND link_kind = 'audit_detail') THEN
    RAISE EXCEPTION '0043 committed deletion audit source event and legacy link do not match the collision operation.';
  END IF;
END;
$collision_postflight$;
ROLLBACK;
\echo PASS 0043 owner collision audit, cursor and unchanged workspace records
