-- Commit authorized calendar history required by the reversal rollback fixture.
\set ON_ERROR_STOP on
\if :{?phase4b5_disposable_child_verified}
\else
\set phase4b5_disposable_child_verified false
\endif
\if :phase4b5_disposable_child_verified
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A verified disposable Development child is required.'; END; $$;
\endif

SELECT set_config('jlproject.phase4b3b2_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'blockedProduct', '4b400000-0000-4000-8000-000000000001',
  'linkedProduct', '4b400000-0000-4000-8000-000000000002',
  'emptyProduct', '4b400000-0000-4000-8000-000000000003',
  'blockedActivity', '4b400000-0000-4000-8000-000000000001',
  'linkedEarly', '4b400000-0000-4000-8000-000000000021',
  'linkedLate', '4b400000-0000-4000-8000-000000000022',
  'emptyActivity', '4b400000-0000-4000-8000-000000000031',
  'blockedBatch', '4b400000-0000-4000-8000-000000000101',
  'linkedBatch', '4b400000-0000-4000-8000-000000000102',
  'emptyBatch', '4b400000-0000-4000-8000-000000000103',
  'collision', '4b400000-0000-4000-8000-000000000104')::text, false);

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $calendar_setup$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_result jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker'
     OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships
       WHERE workspace_id = (v_scope->>'workspace')::uuid
         AND auth_user_id = (v_scope->>'actor')::uuid AND active AND role = 'admin') THEN
    RAISE EXCEPTION 'Expected a direct Worker session and synthetic workspace administrator.';
  END IF;
  v_result := public.change_workspace_calendar((v_scope->>'workspace')::uuid,
    (v_scope->>'actor')::uuid, gen_random_uuid(), 0, 'create', NULL, 'company_shutdown', NULL, NULL,
    'Synthetic reversal calendar closure', DATE '2026-11-13', DATE '2026-11-13');
  IF v_result->>'status' IS DISTINCT FROM 'created'
     OR (v_result->>'version')::bigint IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Could not create the deterministic reversal calendar: %', v_result;
  END IF;
END;
$calendar_setup$;
COMMIT;

-- Current finish 11/11 permits 11/12; reversal restores 11/13, whose next working start is 11/16.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $blocked_batch$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_batch uuid := (v_scope->>'blockedBatch')::uuid;
  v_product uuid := (v_scope->>'blockedProduct')::uuid;
  v_activity uuid := (v_scope->>'blockedActivity')::uuid;
  v_proposals jsonb;
  v_result jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-11', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version)) INTO v_proposals
  FROM public.stage_activities WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND product_id = v_product AND id = v_activity;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_batch::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true),
    set_config('jlproject.schedule_justification', 'Synthetic reversal batch setup', true);
  v_result := public.apply_calendar_reschedule((v_scope->>'workspace')::uuid, v_product,
    v_actor, v_batch, 1, 'Synthetic reversal batch setup', v_proposals);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Blocked-product apply history setup failed: %', v_result;
  END IF;
END;
$blocked_batch$;
COMMIT;

-- Establish a prior reversal ID for the later-linked activity before its two-row target batch.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $prior_apply$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_product uuid := (v_scope->>'linkedProduct')::uuid;
  v_batch uuid := gen_random_uuid();
  v_proposals jsonb;
  v_result jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-16', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version)) INTO v_proposals
  FROM public.stage_activities WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND product_id = v_product AND id = (v_scope->>'linkedLate')::uuid;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_batch::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true),
    set_config('jlproject.schedule_justification', 'Synthetic prior reversal cycle setup', true);
  v_result := public.apply_calendar_reschedule((v_scope->>'workspace')::uuid, v_product,
    v_actor, v_batch, 1, 'Synthetic prior reversal cycle setup', v_proposals);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Prior linked apply history setup failed: %', v_result;
  END IF;
  PERFORM set_config('jlproject.phase4b3b2_prior_batch', v_batch::text, false);
END;
$prior_apply$;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $prior_reversal$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_product uuid := (v_scope->>'linkedProduct')::uuid;
  v_original uuid := current_setting('jlproject.phase4b3b2_prior_batch')::uuid;
  v_collision uuid := (v_scope->>'collision')::uuid;
  v_result jsonb;
BEGIN
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_collision::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_reschedule_reversed', true),
    set_config('jlproject.schedule_justification', 'Synthetic prior reversal cycle setup', true),
    set_config('jlproject.schedule_reversal_of', v_original::text, true);
  v_result := public.reverse_calendar_reschedule((v_scope->>'workspace')::uuid, v_product,
    v_actor, v_original, v_collision, 'Synthetic prior reversal cycle setup');
  IF v_result->>'status' IS DISTINCT FROM 'reversed' OR (v_result->>'count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Prior linked reversal setup failed: %', v_result;
  END IF;
END;
$prior_reversal$;
COMMIT;

-- Target two-row linked batch and the empty-graph batch each commit as one product operation.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $linked_batch$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_batch uuid := (v_scope->>'linkedBatch')::uuid;
  v_product uuid := (v_scope->>'linkedProduct')::uuid;
  v_proposals jsonb;
  v_result jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-16', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version) ORDER BY id) INTO v_proposals
  FROM public.stage_activities WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND product_id = v_product AND id IN ((v_scope->>'linkedEarly')::uuid, (v_scope->>'linkedLate')::uuid);
  IF jsonb_array_length(v_proposals) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Missing linked two-row proposals.'; END IF;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_batch::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true),
    set_config('jlproject.schedule_justification', 'Synthetic linked reversal batch setup', true);
  v_result := public.apply_calendar_reschedule((v_scope->>'workspace')::uuid, v_product,
    v_actor, v_batch, 1, 'Synthetic linked reversal batch setup', v_proposals);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Linked two-row apply history setup failed: %', v_result;
  END IF;
END;
$linked_batch$;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
DO $empty_batch$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3b2_seed')::jsonb;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_batch uuid := (v_scope->>'emptyBatch')::uuid;
  v_product uuid := (v_scope->>'emptyProduct')::uuid;
  v_proposals jsonb;
  v_result jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('activityId', id, 'disciplineId', discipline_id, 'stageId', stage_id,
    'expectedVersion', version, 'startDate', planned_start, 'currentEndDate', planned_end,
    'proposedEndDate', DATE '2026-11-16', 'workingDays', working_day_duration,
    'savedCalendarVersion', planning_calendar_version)) INTO v_proposals
  FROM public.stage_activities WHERE workspace_id = (v_scope->>'workspace')::uuid
    AND product_id = v_product AND id = (v_scope->>'emptyActivity')::uuid;
  PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true),
    set_config('jlproject.schedule_operation_id', v_batch::text, true),
    set_config('jlproject.schedule_operation_type', 'calendar_rescheduled', true),
    set_config('jlproject.schedule_justification', 'Synthetic empty reversal batch setup', true);
  v_result := public.apply_calendar_reschedule((v_scope->>'workspace')::uuid, v_product,
    v_actor, v_batch, 1, 'Synthetic empty reversal batch setup', v_proposals);
  IF v_result->>'status' IS DISTINCT FROM 'updated' OR (v_result->>'count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Empty-graph apply history setup failed: %', v_result;
  END IF;
END;
$empty_batch$;
COMMIT;

\echo Reversal history committed. Batch IDs: blocked 4b400000-0000-4000-8000-000000000101 linked 4b400000-0000-4000-8000-000000000102 empty 4b400000-0000-4000-8000-000000000103 collision 4b400000-0000-4000-8000-000000000104
