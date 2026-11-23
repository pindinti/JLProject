-- Commit the minimal Phase 4B.3a date-guard schedule on a verified disposable child.
\i db/verification/phase4b5-seed-safety-owner.sql

SELECT md5('jlproject.phase4b3a.workspace')::uuid AS test_workspace,
  md5('jlproject.phase4b3a.linked_product')::uuid AS test_product,
  md5('jlproject.phase4b3a.empty_product')::uuid AS test_empty_product,
  md5('jlproject.phase4b3a.discipline')::uuid AS test_discipline,
  md5('jlproject.phase4b3a.predecessor_stage')::uuid AS test_parent,
  md5('jlproject.phase4b3a.predecessor_definition')::uuid AS predecessor_definition,
  md5('jlproject.phase4b3a.successor_stage')::uuid AS successor_stage,
  md5('jlproject.phase4b3a.successor_definition')::uuid AS successor_definition,
  md5('jlproject.phase4b3a.child')::uuid AS test_child,
  md5('jlproject.phase4b3a.successor_child')::uuid AS successor_child,
  md5('jlproject.phase4b3a.root_predecessor')::uuid AS root_predecessor,
  md5('jlproject.phase4b3a.linked_root')::uuid AS test_linked_root,
  md5('jlproject.phase4b3a.empty_root')::uuid AS test_empty_root,
  md5('jlproject.phase4b3a.empty_discipline')::uuid AS empty_discipline,
  md5('jlproject.phase4b3a.setup_operation')::uuid AS setup_operation
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
       OR name = 'Synthetic Phase 4B.3a date guard workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3a seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;

INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3a date guard workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial date guard schedule', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_product', :'test_workspace', 'Synthetic Phase 4B.3a linked product', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3a empty product', :'test_actor', :'test_actor');
INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color,
  display_order, created_by, updated_by)
VALUES (:'test_discipline', :'test_workspace', :'test_product', 'Synthetic discipline', 'SYN', '#336699', 0, :'test_actor', :'test_actor'),
  (:'empty_discipline', :'test_workspace', :'test_empty_product', 'Synthetic empty discipline', 'SYN', '#336699', 0, :'test_actor', :'test_actor');
INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'predecessor_definition', :'test_workspace', 'PRED', '#336699'),
  (:'successor_definition', :'test_workspace', 'SUCC', '#336699');
INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id,
  display_name, display_order, created_by, updated_by)
VALUES (:'test_parent', :'test_workspace', :'test_product', :'test_discipline', :'predecessor_definition', 'Synthetic predecessor', 0, :'test_actor', :'test_actor'),
  (:'successor_stage', :'test_workspace', :'test_product', :'test_discipline', :'successor_definition', 'Synthetic successor', 1, :'test_actor', :'test_actor');
INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, display_order, created_by, updated_by)
VALUES (:'test_child', :'test_workspace', :'test_product', :'test_discipline', :'test_parent', 'Synthetic predecessor child', DATE '2026-11-05', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'successor_child', :'test_workspace', :'test_product', :'test_discipline', :'successor_stage', 'Synthetic successor child', DATE '2026-11-09', DATE '2026-11-09', 0, :'test_actor', :'test_actor'),
  (:'root_predecessor', :'test_workspace', :'test_product', NULL, NULL, 'Synthetic root predecessor', DATE '2026-11-04', DATE '2026-11-05', 900000, :'test_actor', :'test_actor'),
  (:'test_linked_root', :'test_workspace', :'test_product', NULL, NULL, 'Synthetic linked root successor', DATE '2026-11-09', DATE '2026-11-10', 900001, :'test_actor', :'test_actor'),
  (:'test_empty_root', :'test_workspace', :'test_empty_product', NULL, NULL, 'Synthetic empty root activity', DATE '2026-11-05', DATE '2026-11-06', 0, :'test_actor', :'test_actor');
COMMIT;

\set test_product :test_product
\set test_edge_id 4b3a0000-0000-4000-8000-000000000001
\set test_endpoint_kind stage
\set test_predecessor_id :test_parent
\set test_successor_id :successor_stage
\set test_operation_id 4b3a0000-0000-4000-8000-000000000101
\i db/verification/phase4b5-seed-one-dependency.sql
\set test_edge_id 4b3a0000-0000-4000-8000-000000000002
\set test_endpoint_kind activity
\set test_predecessor_id :root_predecessor
\set test_successor_id :test_linked_root
\set test_operation_id 4b3a0000-0000-4000-8000-000000000102
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
\echo Seed IDs for phase4b3a-guard-date-writers.sql: workspace :test_workspace product :test_product actor :test_actor discipline :test_discipline parent :test_parent child :test_child linked_root :test_linked_root empty_product :test_empty_product empty_root :test_empty_root
\echo Worker psql variables: test_workspace=:test_workspace test_product=:test_product test_actor=:test_actor test_discipline=:test_discipline test_parent=:test_parent test_child=:test_child test_linked_root=:test_linked_root test_empty_product=:test_empty_product test_empty_root=:test_empty_root
