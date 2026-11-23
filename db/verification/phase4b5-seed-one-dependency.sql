-- Add one audited synthetic dependency using the private confirmation routine.
-- The owner SET grant, executor membership, and edge write share one transaction; the grant is revoked before commit.
\set ON_ERROR_STOP on
\if :{?phase4b5_disposable_child_verified}
\else
\set phase4b5_disposable_child_verified false
\endif
\if :phase4b5_disposable_child_verified
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A verified disposable Development child is required.'; END; $$;
\endif

SELECT set_config('jlproject.phase4b5_edge_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'product', :'test_product', 'actor', :'test_actor',
  'edge', :'test_edge_id', 'kind', :'test_endpoint_kind',
  'predecessor', :'test_predecessor_id', 'successor', :'test_successor_id',
  'operation', :'test_operation_id')::text, false);

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $owner_preflight$
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner'
     OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships
       WHERE workspace_id = (current_setting('jlproject.phase4b5_edge_seed')::jsonb->>'workspace')::uuid
         AND auth_user_id = (current_setting('jlproject.phase4b5_edge_seed')::jsonb->>'actor')::uuid
         AND active AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Expected a synthetic active editor and no preexisting owner executor grant.';
  END IF;
END;
$owner_preflight$;

GRANT jlproject_date_executor TO neondb_owner
  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
SET LOCAL ROLE jlproject_date_executor;

DO $edge_seed$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b5_edge_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_product uuid := (v_scope->>'product')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_edge_id uuid := (v_scope->>'edge')::uuid;
  v_operation uuid := (v_scope->>'operation')::uuid;
  v_kind text := v_scope->>'kind';
  v_predecessor uuid := (v_scope->>'predecessor')::uuid;
  v_successor uuid := (v_scope->>'successor')::uuid;
  v_read jsonb;
  v_edge jsonb;
  v_result jsonb;
BEGIN
  IF current_user <> 'jlproject_date_executor' OR session_user <> 'neondb_owner'
     OR v_kind IS NULL OR v_kind NOT IN ('activity', 'stage') OR v_predecessor = v_successor
     OR v_edge_id IS NULL OR v_operation IS NULL THEN
    RAISE EXCEPTION 'Invalid audited dependency fixture request.';
  END IF;
  v_read := public.read_schedule_dependencies(v_workspace, v_product, v_actor, false);
  IF v_read->>'status' IS DISTINCT FROM 'ok'
     OR v_read#>>'{snapshot,scheduleVersion}' IS NULL
     OR v_read#>>'{snapshot,calendar,version}' IS NULL
     OR EXISTS (SELECT 1 FROM public.product_schedule_dependencies
       WHERE workspace_id = v_workspace AND product_id = v_product AND id = v_edge_id) THEN
    RAISE EXCEPTION 'Could not read a fresh synthetic dependency graph.';
  END IF;
  v_edge := jsonb_build_object('id', v_edge_id, 'kind', v_kind,
    'predecessor', jsonb_build_object('productId', v_product, 'kind', v_kind, 'id', v_predecessor),
    'successor', jsonb_build_object('productId', v_product, 'kind', v_kind, 'id', v_successor));
  v_result := public.confirm_schedule_dependencies(v_workspace, v_product, v_actor, v_operation,
    (v_read#>>'{snapshot,scheduleVersion}')::bigint,
    (v_read#>>'{snapshot,calendar,version}')::bigint, v_read->>'fingerprint',
    'Synthetic audited dependency fixture setup', '[]'::jsonb,
    jsonb_build_object('kind', 'add', 'dependency', v_edge));
  IF v_result->>'status' IS DISTINCT FROM 'applied'
     OR v_result->>'scheduleVersion' IS NULL
     OR (v_result->>'scheduleVersion')::bigint < 1
     OR NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies AS edge
       WHERE edge.workspace_id = v_workspace AND edge.product_id = v_product AND edge.id = v_edge_id
         AND edge.endpoint_kind = v_kind
         AND ((v_kind = 'activity' AND edge.predecessor_activity_id = v_predecessor
             AND edge.successor_activity_id = v_successor)
           OR (v_kind = 'stage' AND edge.predecessor_stage_id = v_predecessor
             AND edge.successor_stage_id = v_successor)))
     OR (SELECT count(*) FROM public.product_schedule_operation_events
       WHERE workspace_id = v_workspace AND product_id = v_product
         AND operation_id = v_operation AND entity_id = v_edge_id
         AND change_type = 'dependency_added') <> 1 THEN
    RAISE EXCEPTION 'Audited dependency fixture setup did not create exactly one edge event: %', v_result;
  END IF;
END;
$edge_seed$;

RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;
DO $owner_postflight$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET')
     OR pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
     OR has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Temporary fixture executor access was not cleaned up.';
  END IF;
END;
$owner_postflight$;
COMMIT;

\echo Added audited synthetic dependency :test_edge_id
