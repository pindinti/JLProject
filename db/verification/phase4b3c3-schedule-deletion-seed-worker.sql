-- Commit the expected operation-ID collision using the authorized deletion writer.
-- Run directly as jlproject_worker after the read-only collision owner preflight passes.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b3c3_collision_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_empty_product',
  'activity', :'test_collision_activity', 'operation', :'test_late_colliding_operation',
  'cursorBefore', :'test_collision_cursor_before', 'versionBefore', :'test_collision_version_before')::text, true);

DO $collision_seed$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_collision_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
  v_activity uuid := (v_scope->>'activity')::uuid;
  v_operation uuid := (v_scope->>'operation')::uuid;
  v_preview jsonb;
  v_result jsonb;
  v_before bigint;
  v_after bigint;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR session_user <> 'jlproject_worker'
     OR has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT')
     OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships
       WHERE workspace_id = v_workspace AND auth_user_id = v_actor AND active AND role = 'admin')
     OR NOT EXISTS (SELECT 1 FROM public.products
       WHERE workspace_id = v_workspace AND id = v_product AND active)
     OR NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE workspace_id = v_workspace AND product_id = v_product AND id = v_activity
         AND deleted_at IS NULL AND stage_id IS NULL AND discipline_id IS NULL
         AND version = (v_scope->>'versionBefore')::bigint) THEN
    RAISE EXCEPTION 'Expected a direct Worker admin, active product, and live root activity at the preflight version.';
  END IF;

  SELECT schedule_version INTO STRICT v_before
  FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_before IS DISTINCT FROM (v_scope->>'cursorBefore')::bigint THEN
    RAISE EXCEPTION 'Collision seed cursor changed since the owner preflight.';
  END IF;
  v_preview := public.preview_schedule_deletion(v_workspace, v_product, v_actor, 'activity', v_activity);
  IF v_preview->>'status' IS DISTINCT FROM 'ok' OR NOT COALESCE(v_preview->>'fingerprint' ~ '^[0-9a-f]{32}$', false) THEN
    RAISE EXCEPTION 'Expected a fresh deletion preview for collision history setup: %', v_preview;
  END IF;

  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_operation::text, true),
    set_config('jlproject.schedule_operation_type', 'schedule_deleted', true),
    set_config('jlproject.schedule_justification', 'Synthetic committed deletion collision history', true);
  v_result := public.delete_schedule_subtree(v_workspace, v_product, v_actor, v_operation,
    'activity', v_activity, v_preview->>'fingerprint', 'Synthetic committed deletion collision history');
  IF v_result->>'status' IS DISTINCT FROM 'deleted'
     OR v_result->>'operationId' IS DISTINCT FROM v_operation::text
     OR v_result#>>'{counts,activities}' IS DISTINCT FROM '1'
     OR NOT EXISTS (SELECT 1 FROM public.stage_activities
       WHERE workspace_id = v_workspace AND product_id = v_product AND id = v_activity
         AND deleted_at IS NOT NULL AND deletion_operation_id = v_operation
         AND version = (v_scope->>'versionBefore')::bigint + 1 AND updated_by = v_actor) THEN
    RAISE EXCEPTION 'Could not commit the expected collision activity deletion: %', v_result;
  END IF;
  SELECT schedule_version INTO STRICT v_after
  FROM public.read_product_schedule_cursor(v_workspace, v_product, v_actor);
  IF v_after IS DISTINCT FROM v_before + 1 THEN
    RAISE EXCEPTION 'Collision history did not advance the schedule cursor exactly once.';
  END IF;
END;
$collision_seed$;
COMMIT;
