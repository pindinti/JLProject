-- Commit deterministic D065 and dependency boundaries for the activity-creation Worker fixture.
\i db/verification/phase4b5-seed-safety-owner.sql
\i db/verification/phase4b5-seed-auth-identities-owner.sql

SELECT md5('jlproject.phase4b3c1.workspace')::uuid AS test_workspace,
  md5('jlproject.phase4b3c1.linked_product')::uuid AS test_linked_product,
  md5('jlproject.phase4b3c1.violation_product')::uuid AS test_violation_product,
  md5('jlproject.phase4b3c1.empty_product')::uuid AS test_empty_product,
  md5('jlproject.phase4b3c1.linked_discipline')::uuid AS linked_discipline,
  md5('jlproject.phase4b3c1.violation_discipline')::uuid AS violation_discipline,
  md5('jlproject.phase4b3c1.empty_discipline')::uuid AS empty_discipline,
  md5('jlproject.phase4b3c1.derived_predecessor')::uuid AS test_derived_predecessor_stage,
  md5('jlproject.phase4b3c1.derived_predecessor_definition')::uuid AS derived_predecessor_definition,
  md5('jlproject.phase4b3c1.derived_successor')::uuid AS test_derived_successor_stage,
  md5('jlproject.phase4b3c1.derived_successor_definition')::uuid AS derived_successor_definition,
  md5('jlproject.phase4b3c1.explicit_stage')::uuid AS test_explicit_stage,
  md5('jlproject.phase4b3c1.explicit_definition')::uuid AS explicit_definition,
  md5('jlproject.phase4b3c1.partial_stage')::uuid AS test_partial_stage,
  md5('jlproject.phase4b3c1.partial_definition')::uuid AS partial_definition,
  md5('jlproject.phase4b3c1.fixed_successor')::uuid AS fixed_successor_stage,
  md5('jlproject.phase4b3c1.fixed_successor_definition')::uuid AS fixed_successor_definition,
  md5('jlproject.phase4b3c1.violation_stage')::uuid AS test_violation_stage,
  md5('jlproject.phase4b3c1.violation_definition')::uuid AS violation_definition,
  md5('jlproject.phase4b3c1.violation_successor')::uuid AS violation_successor_stage,
  md5('jlproject.phase4b3c1.violation_successor_definition')::uuid AS violation_successor_definition,
  md5('jlproject.phase4b3c1.empty_stage')::uuid AS test_empty_stage,
  md5('jlproject.phase4b3c1.empty_definition')::uuid AS empty_definition,
  md5('jlproject.phase4b3c1.setup_operation')::uuid AS setup_operation
\gset
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b5_seed_workspace', :'test_workspace', true);
DO $no_duplicate$
BEGIN
  IF EXISTS (SELECT 1 FROM public.workspaces WHERE id = current_setting('jlproject.phase4b5_seed_workspace')::uuid
       OR name = 'Synthetic Phase 4B.3c.1 activity creation workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3c.1 seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;
INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3c.1 activity creation workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true),
  (:'test_workspace', :'test_viewer', 'viewer', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial activity creation schedule', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_linked_product', :'test_workspace', 'Synthetic Phase 4B.3c.1 linked product', :'test_actor', :'test_actor'),
  (:'test_violation_product', :'test_workspace', 'Synthetic Phase 4B.3c.1 existing violation product', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3c.1 empty product', :'test_actor', :'test_actor');
INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
VALUES (:'linked_discipline', :'test_workspace', :'test_linked_product', 'Synthetic creation discipline', 'CRE', '#336699', 0, :'test_actor', :'test_actor'),
  (:'violation_discipline', :'test_workspace', :'test_violation_product', 'Synthetic violation discipline', 'VIO', '#336699', 0, :'test_actor', :'test_actor'),
  (:'empty_discipline', :'test_workspace', :'test_empty_product', 'Synthetic empty discipline', 'EMP', '#336699', 0, :'test_actor', :'test_actor');
INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'derived_predecessor_definition', :'test_workspace', 'CREATE-PRED', '#336699'),
  (:'derived_successor_definition', :'test_workspace', 'CREATE-SUCC', '#336699'),
  (:'explicit_definition', :'test_workspace', 'CREATE-EXPLICIT', '#336699'),
  (:'partial_definition', :'test_workspace', 'CREATE-PARTIAL', '#336699'),
  (:'fixed_successor_definition', :'test_workspace', 'CREATE-FIXED-SUCC', '#336699'),
  (:'violation_definition', :'test_workspace', 'CREATE-VIOLATION', '#336699'),
  (:'violation_successor_definition', :'test_workspace', 'CREATE-VIOLATION-SUCC', '#336699'),
  (:'empty_definition', :'test_workspace', 'CREATE-EMPTY', '#336699');
INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id,
  display_name, display_order, created_by, updated_by, planned_start, planned_end)
VALUES (:'test_derived_predecessor_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'derived_predecessor_definition', 'Derived predecessor', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_derived_successor_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'derived_successor_definition', 'Derived successor', 1, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_explicit_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'explicit_definition', 'Complete explicit predecessor', 2, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_partial_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'partial_definition', 'Partial explicit predecessor', 3, :'test_actor', :'test_actor', NULL, NULL),
  (:'fixed_successor_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'fixed_successor_definition', 'Fixed successor', 4, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_violation_stage', :'test_workspace', :'test_violation_product', :'violation_discipline', :'violation_definition', 'Existing violation predecessor', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'violation_successor_stage', :'test_workspace', :'test_violation_product', :'violation_discipline', :'violation_successor_definition', 'Existing violation successor', 1, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_empty_stage', :'test_workspace', :'test_empty_product', :'empty_discipline', :'empty_definition', 'Empty graph stage', 0, :'test_actor', :'test_actor', NULL, NULL);
INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, display_order, created_by, updated_by)
VALUES (md5('jlproject.phase4b3c1.derived_predecessor_child')::uuid, :'test_workspace', :'test_linked_product', :'linked_discipline', :'test_derived_predecessor_stage', 'Initial derived predecessor child', DATE '2026-11-03', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c1.derived_successor_child')::uuid, :'test_workspace', :'test_linked_product', :'linked_discipline', :'test_derived_successor_stage', 'Initial derived successor child', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c1.violation_child')::uuid, :'test_workspace', :'test_violation_product', :'violation_discipline', :'test_violation_stage', 'Initial violation predecessor child', DATE '2026-11-03', DATE '2026-11-10', 0, :'test_actor', :'test_actor');
COMMIT;

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
SELECT row_count::text AS test_r00_count, fingerprint AS test_r00_fingerprint
FROM pg_temp.phase4b5_seed_r00_baseline \gset
\echo Owner structural setup committed. Run phase4b3c1-activity-creation-seed-worker-stage-dates.sql as a direct Worker session before phase4b3c1-activity-creation-seed-owner-dependencies.sql.
\echo Seed IDs: workspace :test_workspace actor :test_actor viewer :test_viewer linked_product :test_linked_product violation_product :test_violation_product
\echo Worker psql variables: test_workspace=:test_workspace test_actor=:test_actor test_viewer=:test_viewer test_linked_product=:test_linked_product test_violation_product=:test_violation_product test_derived_predecessor_stage=:test_derived_predecessor_stage test_derived_successor_stage=:test_derived_successor_stage test_explicit_stage=:test_explicit_stage test_partial_stage=:test_partial_stage fixed_successor_stage=:fixed_successor_stage test_violation_stage=:test_violation_stage violation_successor_stage=:violation_successor_stage test_empty_product=:test_empty_product test_empty_stage=:test_empty_stage test_r00_count=:test_r00_count test_r00_fingerprint=:test_r00_fingerprint
