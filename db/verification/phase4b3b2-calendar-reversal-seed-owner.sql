-- Commit reversal-fixture source rows; the Worker lifecycle history is seeded separately.
\i db/verification/phase4b5-seed-safety-owner.sql

SELECT md5('jlproject.phase4b3b2.workspace')::uuid AS test_workspace,
  '4b400000-0000-4000-8000-000000000001'::uuid AS test_blocked_product,
  '4b400000-0000-4000-8000-000000000002'::uuid AS test_linked_product,
  '4b400000-0000-4000-8000-000000000003'::uuid AS test_empty_product,
  md5('jlproject.phase4b3b2.blocked_discipline')::uuid AS blocked_discipline,
  '4b400000-0000-4000-8000-000000000001'::uuid AS blocked_pred_stage,
  md5('jlproject.phase4b3b2.blocked_pred_definition')::uuid AS blocked_pred_definition,
  '4b400000-0000-4000-8000-000000000002'::uuid AS blocked_succ_stage,
  md5('jlproject.phase4b3b2.blocked_succ_definition')::uuid AS blocked_succ_definition,
  md5('jlproject.phase4b3b2.linked_discipline')::uuid AS linked_discipline,
  '4b400000-0000-4000-8000-000000000011'::uuid AS linked_pred_stage,
  md5('jlproject.phase4b3b2.linked_pred_definition')::uuid AS linked_pred_definition,
  '4b400000-0000-4000-8000-000000000012'::uuid AS linked_succ_stage,
  md5('jlproject.phase4b3b2.linked_succ_definition')::uuid AS linked_succ_definition,
  md5('jlproject.phase4b3b2.empty_discipline')::uuid AS empty_discipline,
  md5('jlproject.phase4b3b2.setup_operation')::uuid AS setup_operation,
  '4b400000-0000-4000-8000-000000000001'::uuid AS test_stale_activity,
  '4b400000-0000-4000-8000-000000000011'::uuid AS blocked_successor_activity,
  '4b400000-0000-4000-8000-000000000021'::uuid AS linked_early_activity,
  '4b400000-0000-4000-8000-000000000022'::uuid AS linked_late_activity,
  '4b400000-0000-4000-8000-000000000023'::uuid AS linked_successor_activity,
  '4b400000-0000-4000-8000-000000000031'::uuid AS empty_activity,
  '4b400000-0000-4000-8000-000000000101'::uuid AS test_blocked_batch,
  '4b400000-0000-4000-8000-000000000102'::uuid AS test_linked_batch,
  '4b400000-0000-4000-8000-000000000103'::uuid AS test_empty_batch,
  '4b400000-0000-4000-8000-000000000104'::uuid AS test_colliding_reversal
\gset
SELECT auth_user_id::text AS test_actor FROM public.workspace_memberships
WHERE active AND role = 'admin' ORDER BY auth_user_id LIMIT 1
\gset

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b5_seed_workspace', :'test_workspace', true);
DO $no_duplicate$
BEGIN
  IF EXISTS (SELECT 1 FROM public.workspaces WHERE id = current_setting('jlproject.phase4b5_seed_workspace')::uuid
       OR name = 'Synthetic Phase 4B.3b.2 workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3b.2 seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;
INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3b.2 workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial calendar reversal schedule', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_blocked_product', :'test_workspace', 'Synthetic Phase 4B.3b.2 blocked product', :'test_actor', :'test_actor'),
  (:'test_linked_product', :'test_workspace', 'Synthetic Phase 4B.3b.2 linked product', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3b.2 empty product', :'test_actor', :'test_actor');
INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
VALUES (:'blocked_discipline', :'test_workspace', :'test_blocked_product', 'Synthetic blocked reversal discipline', 'BLK', '#336699', 0, :'test_actor', :'test_actor'),
  (:'linked_discipline', :'test_workspace', :'test_linked_product', 'Synthetic linked reversal discipline', 'LNK', '#336699', 0, :'test_actor', :'test_actor'),
  (:'empty_discipline', :'test_workspace', :'test_empty_product', 'Synthetic empty reversal discipline', 'EMP', '#336699', 0, :'test_actor', :'test_actor');
INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'blocked_pred_definition', :'test_workspace', 'REV-BP', '#336699'),
  (:'blocked_succ_definition', :'test_workspace', 'REV-BS', '#336699'),
  (:'linked_pred_definition', :'test_workspace', 'REV-LP', '#336699'),
  (:'linked_succ_definition', :'test_workspace', 'REV-LS', '#336699');
INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
VALUES (:'blocked_pred_stage', :'test_workspace', :'test_blocked_product', :'blocked_discipline', :'blocked_pred_definition', 'Synthetic blocked predecessor', 0, :'test_actor', :'test_actor'),
  (:'blocked_succ_stage', :'test_workspace', :'test_blocked_product', :'blocked_discipline', :'blocked_succ_definition', 'Synthetic blocked successor', 1, :'test_actor', :'test_actor'),
  (:'linked_pred_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_pred_definition', 'Synthetic linked predecessor', 0, :'test_actor', :'test_actor'),
  (:'linked_succ_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_succ_definition', 'Synthetic linked successor', 1, :'test_actor', :'test_actor');
INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, planning_mode, working_day_duration, planning_calendar_version, display_order, created_by, updated_by)
VALUES (:'test_stale_activity', :'test_workspace', :'test_blocked_product', :'blocked_discipline', :'blocked_pred_stage', 'Synthetic blocked activity', DATE '2026-11-09', DATE '2026-11-13', 'working_days', 3, 0, 0, :'test_actor', :'test_actor'),
  (:'blocked_successor_activity', :'test_workspace', :'test_blocked_product', :'blocked_discipline', :'blocked_succ_stage', 'Synthetic blocked successor activity', DATE '2026-11-12', DATE '2026-11-12', 'manual', NULL, NULL, 0, :'test_actor', :'test_actor'),
  (:'linked_early_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_pred_stage', 'Synthetic linked early activity', DATE '2026-11-11', DATE '2026-11-12', 'working_days', 2, 0, 0, :'test_actor', :'test_actor'),
  (:'linked_late_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_pred_stage', 'Synthetic linked late activity', DATE '2026-11-11', DATE '2026-11-12', 'working_days', 2, 0, 1, :'test_actor', :'test_actor'),
  (:'linked_successor_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_succ_stage', 'Synthetic linked successor activity', DATE '2026-11-10', DATE '2026-11-10', 'manual', NULL, NULL, 0, :'test_actor', :'test_actor'),
  (:'empty_activity', :'test_workspace', :'test_empty_product', NULL, NULL, 'Synthetic empty reversal activity', DATE '2026-11-11', DATE '2026-11-12', 'working_days', 2, 0, 0, :'test_actor', :'test_actor');
COMMIT;

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Run phase4b3b2-calendar-reversal-seed-worker.sql directly as jlproject_worker with workspace :test_workspace and actor :test_actor.
\echo Batch IDs: blocked :test_blocked_batch linked :test_linked_batch empty :test_empty_batch collision :test_colliding_reversal
\echo After Worker history setup, run phase4b3b2-calendar-reversal-dependencies-owner.sql, then the Worker rollback fixture.
\echo Worker psql variables: test_workspace=:test_workspace test_actor=:test_actor test_blocked_product=:test_blocked_product test_blocked_batch=:test_blocked_batch test_stale_activity=:test_stale_activity test_linked_product=:test_linked_product test_linked_batch=:test_linked_batch test_colliding_reversal=:test_colliding_reversal test_empty_product=:test_empty_product test_empty_batch=:test_empty_batch
