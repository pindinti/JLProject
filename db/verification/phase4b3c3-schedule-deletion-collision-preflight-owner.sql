-- Run after dependency setup and before the direct Worker collision seed.
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
\i db/verification/phase4b3c3-schedule-deletion-collision-state-owner.sql

DO $collision_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_collision_check')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_activity uuid := (v_scope->>'activity')::uuid;
  v_operation uuid := (v_scope->>'operation')::uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND id = v_product AND active AND name = 'Synthetic Phase 4B.3c.3 empty graph deletion')
     OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role = 'admin')
     OR NOT EXISTS (SELECT 1 FROM public.stage_activities WHERE workspace_id = v_workspace
       AND product_id = v_product AND id = v_activity AND name = 'Committed collision history target'
       AND stage_id IS NULL AND discipline_id IS NULL AND deleted_at IS NULL AND deletion_operation_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace AND product_id = v_product)
     OR EXISTS (SELECT 1 FROM public.schedule_deletion_events WHERE operation_id = v_operation)
     OR EXISTS (SELECT 1 FROM public.product_schedule_operations WHERE workspace_id = v_workspace
       AND product_id = v_product AND operation_id = v_operation) THEN
    RAISE EXCEPTION '0043 collision setup requires a live synthetic root activity, active admin, empty graph and unused operation ID.';
  END IF;
END;
$collision_preflight$;

SELECT s.schedule_version AS test_collision_cursor_before, a.version AS test_collision_version_before
FROM public.product_schedule_state s JOIN public.stage_activities a USING (workspace_id, product_id)
WHERE s.workspace_id = :'test_workspace'::uuid AND s.product_id = :'test_empty_product'::uuid
  AND a.id = :'test_collision_activity'::uuid \gset
\set test_collision_state_fingerprint :collision_state_fingerprint
ROLLBACK;
\echo Collision preflight variables: test_collision_cursor_before=:test_collision_cursor_before test_collision_version_before=:test_collision_version_before test_collision_state_fingerprint=:test_collision_state_fingerprint
