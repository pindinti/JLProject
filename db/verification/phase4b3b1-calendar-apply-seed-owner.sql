-- Commit deterministic source rows for the Phase 4B.3b.1 Worker setup and rollback fixture.
\i db/verification/phase4b5-seed-safety-owner.sql

SELECT md5('jlproject.phase4b3b1.workspace')::uuid AS test_workspace,
  md5('jlproject.phase4b3b1.linked_product')::uuid AS test_product,
  md5('jlproject.phase4b3b1.empty_product')::uuid AS test_empty_product,
  md5('jlproject.phase4b3b1.discipline')::uuid AS test_discipline,
  md5('jlproject.phase4b3b1.predecessor_stage')::uuid AS test_parent,
  md5('jlproject.phase4b3b1.predecessor_definition')::uuid AS predecessor_definition,
  md5('jlproject.phase4b3b1.successor_stage')::uuid AS successor_stage,
  md5('jlproject.phase4b3b1.successor_definition')::uuid AS successor_definition,
  '4b390000-0000-4000-8000-000000000001'::uuid AS test_unlinked_activity,
  '4b390000-0000-4000-8000-000000000002'::uuid AS test_first_child,
  '4b390000-0000-4000-8000-000000000003'::uuid AS test_second_child,
  '4b390000-0000-4000-8000-000000000004'::uuid AS successor_child,
  '4b390000-0000-4000-8000-000000000005'::uuid AS test_empty_activity,
  md5('jlproject.phase4b3b1.empty_discipline')::uuid AS empty_discipline,
  md5('jlproject.phase4b3b1.setup_operation')::uuid AS setup_operation
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
       OR name = 'Synthetic Phase 4B.3b.1 workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3b.1 seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;

INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3b.1 workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial calendar apply schedule', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_product', :'test_workspace', 'Synthetic Phase 4B.3b.1 linked product', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3b.1 empty product', :'test_actor', :'test_actor');
INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
VALUES (:'test_discipline', :'test_workspace', :'test_product', 'Synthetic calendar discipline', 'SYN', '#336699', 0, :'test_actor', :'test_actor'),
  (:'empty_discipline', :'test_workspace', :'test_empty_product', 'Synthetic empty calendar discipline', 'SYN', '#336699', 0, :'test_actor', :'test_actor');
INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'predecessor_definition', :'test_workspace', 'CAL-PRED', '#336699'),
  (:'successor_definition', :'test_workspace', 'CAL-SUCC', '#336699');
INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id,
  display_name, display_order, created_by, updated_by)
VALUES (:'test_parent', :'test_workspace', :'test_product', :'test_discipline', :'predecessor_definition', 'Synthetic predecessor', 0, :'test_actor', :'test_actor'),
  (:'successor_stage', :'test_workspace', :'test_product', :'test_discipline', :'successor_definition', 'Synthetic successor', 1, :'test_actor', :'test_actor');
INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, planning_mode, working_day_duration, planning_calendar_version,
  display_order, created_by, updated_by)
VALUES (:'test_unlinked_activity', :'test_workspace', :'test_product', :'test_discipline', :'test_parent', 'Synthetic earlier unlinked activity', DATE '2026-11-09', DATE '2026-11-09', 'working_days', 1, 0, 0, :'test_actor', :'test_actor'),
  (:'test_first_child', :'test_workspace', :'test_product', :'test_discipline', :'test_parent', 'Synthetic first predecessor activity', DATE '2026-11-05', DATE '2026-11-18', 'working_days', 3, 0, 1, :'test_actor', :'test_actor'),
  (:'test_second_child', :'test_workspace', :'test_product', :'test_discipline', :'test_parent', 'Synthetic second predecessor activity', DATE '2026-11-09', DATE '2026-11-10', 'working_days', 2, 0, 2, :'test_actor', :'test_actor'),
  (:'successor_child', :'test_workspace', :'test_product', :'test_discipline', :'successor_stage', 'Synthetic successor activity', DATE '2026-11-12', DATE '2026-11-12', 'manual', NULL, NULL, 0, :'test_actor', :'test_actor'),
  (:'test_empty_activity', :'test_workspace', :'test_empty_product', NULL, NULL, 'Synthetic empty graph activity', DATE '2026-11-09', DATE '2026-11-10', 'working_days', 2, 0, 0, :'test_actor', :'test_actor');
COMMIT;

\set test_edge_id 4b390000-0000-4000-8000-000000000101
\set test_endpoint_kind stage
\set test_predecessor_id :test_parent
\set test_successor_id :successor_stage
\set test_operation_id 4b390000-0000-4000-8000-000000000201
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Run phase4b3b1-calendar-setup-worker.sql as Worker with test_workspace :test_workspace and test_actor :test_actor.
\echo Run phase4b3b1-calendar-apply.sql with calendar version 2 and the emitted test_* variables.
\echo Worker psql variables: test_workspace=:test_workspace test_product=:test_product test_actor=:test_actor test_parent=:test_parent test_first_child=:test_first_child test_second_child=:test_second_child test_unlinked_activity=:test_unlinked_activity test_empty_product=:test_empty_product test_empty_activity=:test_empty_activity test_calendar_version=2
