-- Commit isolated source schedules and audited dependency links for the 0043 deletion fixture.
-- Run as neondb_owner on the verified disposable child; the collision delete is a separate Worker step.
\i db/verification/phase4b5-seed-safety-owner.sql
\i db/verification/phase4b5-seed-auth-identities-owner.sql

SELECT md5('jlproject.phase4b3c3.workspace')::uuid AS test_workspace,
  md5('jlproject.phase4b3c3.linked_product')::uuid AS test_linked_product,
  md5('jlproject.phase4b3c3.descendant_product')::uuid AS test_descendant_product,
  md5('jlproject.phase4b3c3.missing_product')::uuid AS test_missing_product,
  md5('jlproject.phase4b3c3.valid_product')::uuid AS test_valid_product,
  md5('jlproject.phase4b3c3.fixed_product')::uuid AS test_fixed_product,
  md5('jlproject.phase4b3c3.partial_product')::uuid AS test_partial_product,
  md5('jlproject.phase4b3c3.empty_product')::uuid AS test_empty_product,
  md5('jlproject.phase4b3c3.linked_discipline')::uuid AS linked_discipline,
  md5('jlproject.phase4b3c3.descendant_discipline')::uuid AS test_descendant_discipline,
  md5('jlproject.phase4b3c3.descendant_successor_discipline')::uuid AS descendant_successor_discipline,
  md5('jlproject.phase4b3c3.missing_discipline')::uuid AS missing_discipline,
  md5('jlproject.phase4b3c3.missing_successor_discipline')::uuid AS missing_successor_discipline,
  md5('jlproject.phase4b3c3.valid_discipline')::uuid AS valid_discipline,
  md5('jlproject.phase4b3c3.valid_successor_discipline')::uuid AS valid_successor_discipline,
  md5('jlproject.phase4b3c3.fixed_discipline')::uuid AS fixed_discipline,
  md5('jlproject.phase4b3c3.partial_discipline')::uuid AS partial_discipline,
  md5('jlproject.phase4b3c3.linked_stage')::uuid AS test_linked_stage,
  md5('jlproject.phase4b3c3.linked_successor_stage')::uuid AS linked_successor_stage,
  md5('jlproject.phase4b3c3.descendant_stage')::uuid AS test_descendant_stage,
  md5('jlproject.phase4b3c3.descendant_successor_stage')::uuid AS descendant_successor_stage,
  md5('jlproject.phase4b3c3.missing_stage')::uuid AS test_missing_stage,
  md5('jlproject.phase4b3c3.missing_successor_stage')::uuid AS missing_successor_stage,
  md5('jlproject.phase4b3c3.valid_stage')::uuid AS test_valid_stage,
  md5('jlproject.phase4b3c3.valid_successor_stage')::uuid AS valid_successor_stage,
  md5('jlproject.phase4b3c3.explicit_stage')::uuid AS test_explicit_stage,
  md5('jlproject.phase4b3c3.partial_stage')::uuid AS test_partial_stage,
  md5('jlproject.phase4b3c3.empty_discipline')::uuid AS empty_discipline,
  md5('jlproject.phase4b3c3.setup_operation')::uuid AS setup_operation,
  md5('jlproject.phase4b3c3.linked_activity')::uuid AS test_linked_activity,
  md5('jlproject.phase4b3c3.linked_successor_activity')::uuid AS linked_successor_activity,
  md5('jlproject.phase4b3c3.descendant_activity')::uuid AS descendant_activity,
  md5('jlproject.phase4b3c3.descendant_successor_activity')::uuid AS descendant_successor_activity,
  md5('jlproject.phase4b3c3.missing_activity')::uuid AS test_missing_activity,
  md5('jlproject.phase4b3c3.missing_successor_activity')::uuid AS missing_successor_activity,
  md5('jlproject.phase4b3c3.valid_activity')::uuid AS test_valid_activity,
  md5('jlproject.phase4b3c3.valid_other_activity')::uuid AS valid_other_activity,
  md5('jlproject.phase4b3c3.valid_successor_activity')::uuid AS valid_successor_activity,
  md5('jlproject.phase4b3c3.explicit_activity')::uuid AS test_explicit_activity,
  md5('jlproject.phase4b3c3.partial_activity')::uuid AS test_partial_activity,
  md5('jlproject.phase4b3c3.empty_activity')::uuid AS test_empty_activity,
  md5('jlproject.phase4b3c3.collision_activity')::uuid AS test_collision_activity,
  '4b430000-0000-4000-8000-000000000101'::uuid AS test_linked_activity_dependency,
  '4b430000-0000-4000-8000-000000000102'::uuid AS test_linked_stage_dependency,
  '4b430000-0000-4000-8000-000000000103'::uuid AS test_descendant_dependency,
  '4b430000-0000-4000-8000-000000000104'::uuid AS test_missing_dependency,
  '4b430000-0000-4000-8000-000000000105'::uuid AS test_valid_dependency,
  '4b430000-0000-4000-8000-000000000501'::uuid AS test_late_colliding_operation,
  md5('jlproject.phase4b3c3.linked_definition')::uuid AS linked_definition,
  md5('jlproject.phase4b3c3.linked_successor_definition')::uuid AS linked_successor_definition,
  md5('jlproject.phase4b3c3.descendant_definition')::uuid AS descendant_definition,
  md5('jlproject.phase4b3c3.descendant_successor_definition')::uuid AS descendant_successor_definition,
  md5('jlproject.phase4b3c3.missing_definition')::uuid AS missing_definition,
  md5('jlproject.phase4b3c3.missing_successor_definition')::uuid AS missing_successor_definition,
  md5('jlproject.phase4b3c3.valid_definition')::uuid AS valid_definition,
  md5('jlproject.phase4b3c3.valid_successor_definition')::uuid AS valid_successor_definition,
  md5('jlproject.phase4b3c3.explicit_definition')::uuid AS explicit_definition,
  md5('jlproject.phase4b3c3.partial_definition')::uuid AS partial_definition,
  md5('jlproject.phase4b3c3.empty_definition')::uuid AS empty_definition
\gset
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b5_seed_workspace', :'test_workspace', true);
DO $no_duplicate$
BEGIN
  IF EXISTS (SELECT 1 FROM public.workspaces WHERE id = current_setting('jlproject.phase4b5_seed_workspace')::uuid
       OR name = 'Synthetic Phase 4B.3c.3 schedule deletion workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3c.3 seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;

INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3c.3 schedule deletion workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true), (:'test_workspace', :'test_viewer', 'viewer', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial deletion schedules', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_linked_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 linked endpoints', :'test_actor', :'test_actor'),
  (:'test_descendant_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 linked descendant', :'test_actor', :'test_actor'),
  (:'test_missing_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 missing boundary', :'test_actor', :'test_actor'),
  (:'test_valid_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 valid derived deletion', :'test_actor', :'test_actor'),
  (:'test_fixed_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 complete explicit deletion', :'test_actor', :'test_actor'),
  (:'test_partial_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 partial explicit deletion', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3c.3 empty graph deletion', :'test_actor', :'test_actor');

INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color,
  display_order, created_by, updated_by)
VALUES (:'linked_discipline', :'test_workspace', :'test_linked_product', 'Linked endpoints', 'LE', '#336699', 0, :'test_actor', :'test_actor'),
  (:'test_descendant_discipline', :'test_workspace', :'test_descendant_product', 'Linked descendant', 'DD', '#336699', 0, :'test_actor', :'test_actor'),
  (:'descendant_successor_discipline', :'test_workspace', :'test_descendant_product', 'Descendant successor', 'DS', '#336699', 1, :'test_actor', :'test_actor'),
  (:'missing_discipline', :'test_workspace', :'test_missing_product', 'Missing boundary', 'MB', '#336699', 0, :'test_actor', :'test_actor'),
  (:'missing_successor_discipline', :'test_workspace', :'test_missing_product', 'Missing successor', 'MS', '#336699', 1, :'test_actor', :'test_actor'),
  (:'valid_discipline', :'test_workspace', :'test_valid_product', 'Valid derived', 'VD', '#336699', 0, :'test_actor', :'test_actor'),
  (:'valid_successor_discipline', :'test_workspace', :'test_valid_product', 'Valid successor', 'VS', '#336699', 1, :'test_actor', :'test_actor'),
  (:'fixed_discipline', :'test_workspace', :'test_fixed_product', 'Complete explicit', 'FE', '#336699', 0, :'test_actor', :'test_actor'),
  (:'partial_discipline', :'test_workspace', :'test_partial_product', 'Partial explicit', 'PE', '#336699', 0, :'test_actor', :'test_actor'),
  (:'empty_discipline', :'test_workspace', :'test_empty_product', 'Empty graph', 'EG', '#336699', 0, :'test_actor', :'test_actor');

INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'linked_definition', :'test_workspace', 'DEL-LINKED', '#336699'),
  (:'linked_successor_definition', :'test_workspace', 'DEL-LINKED-SUCC', '#336699'),
  (:'descendant_definition', :'test_workspace', 'DEL-DESC', '#336699'),
  (:'descendant_successor_definition', :'test_workspace', 'DEL-DESC-SUCC', '#336699'),
  (:'missing_definition', :'test_workspace', 'DEL-MISSING', '#336699'),
  (:'missing_successor_definition', :'test_workspace', 'DEL-MISSING-SUCC', '#336699'),
  (:'valid_definition', :'test_workspace', 'DEL-VALID', '#336699'),
  (:'valid_successor_definition', :'test_workspace', 'DEL-VALID-SUCC', '#336699'),
  (:'explicit_definition', :'test_workspace', 'DEL-EXPLICIT', '#336699'),
  (:'partial_definition', :'test_workspace', 'DEL-PARTIAL', '#336699'),
  (:'empty_definition', :'test_workspace', 'DEL-EMPTY', '#336699');

INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id,
  display_name, display_order, created_by, updated_by, planned_start, planned_end)
VALUES (:'test_linked_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_definition', 'Linked predecessor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'linked_successor_stage', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_successor_definition', 'Linked successor stage', 1, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_descendant_stage', :'test_workspace', :'test_descendant_product', :'test_descendant_discipline', :'descendant_definition', 'Linked descendant stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'descendant_successor_stage', :'test_workspace', :'test_descendant_product', :'descendant_successor_discipline', :'descendant_successor_definition', 'Descendant successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_missing_stage', :'test_workspace', :'test_missing_product', :'missing_discipline', :'missing_definition', 'Missing boundary stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'missing_successor_stage', :'test_workspace', :'test_missing_product', :'missing_successor_discipline', :'missing_successor_definition', 'Missing boundary successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_valid_stage', :'test_workspace', :'test_valid_product', :'valid_discipline', :'valid_definition', 'Valid derived stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'valid_successor_stage', :'test_workspace', :'test_valid_product', :'valid_successor_discipline', :'valid_successor_definition', 'Valid successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_explicit_stage', :'test_workspace', :'test_fixed_product', :'fixed_discipline', :'explicit_definition', 'Complete explicit stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_partial_stage', :'test_workspace', :'test_partial_product', :'partial_discipline', :'partial_definition', 'Partial explicit stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (md5('jlproject.phase4b3c3.empty_stage')::uuid, :'test_workspace', :'test_empty_product', :'empty_discipline', :'empty_definition', 'Empty graph stage', 0, :'test_actor', :'test_actor', NULL, NULL);

INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, display_order, created_by, updated_by)
VALUES (:'test_linked_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'test_linked_stage', 'Linked predecessor activity', DATE '2026-11-03', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'linked_successor_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'linked_successor_stage', 'Linked successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'descendant_activity', :'test_workspace', :'test_descendant_product', :'test_descendant_discipline', :'test_descendant_stage', 'Linked descendant activity', DATE '2026-11-03', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'descendant_successor_activity', :'test_workspace', :'test_descendant_product', :'descendant_successor_discipline', :'descendant_successor_stage', 'Descendant successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_missing_activity', :'test_workspace', :'test_missing_product', :'missing_discipline', :'test_missing_stage', 'Sole derived boundary activity', DATE '2026-11-03', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'missing_successor_activity', :'test_workspace', :'test_missing_product', :'missing_successor_discipline', :'missing_successor_stage', 'Missing boundary successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_valid_activity', :'test_workspace', :'test_valid_product', :'valid_discipline', :'test_valid_stage', 'Valid deletion target', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor'),
  (:'valid_other_activity', :'test_workspace', :'test_valid_product', :'valid_discipline', :'test_valid_stage', 'Remaining derived boundary activity', DATE '2026-11-03', DATE '2026-11-05', 1, :'test_actor', :'test_actor'),
  (:'valid_successor_activity', :'test_workspace', :'test_valid_product', :'valid_successor_discipline', :'valid_successor_stage', 'Valid successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_explicit_activity', :'test_workspace', :'test_fixed_product', :'fixed_discipline', :'test_explicit_stage', 'Complete explicit child', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor'),
  (:'test_partial_activity', :'test_workspace', :'test_partial_product', :'partial_discipline', :'test_partial_stage', 'Partial explicit child', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor'),
  (:'test_empty_activity', :'test_workspace', :'test_empty_product', NULL, NULL, 'Empty graph deletion target', DATE '2026-11-03', DATE '2026-11-04', 900000, :'test_actor', :'test_actor'),
  (:'test_collision_activity', :'test_workspace', :'test_empty_product', NULL, NULL, 'Committed collision history target', DATE '2026-11-03', DATE '2026-11-04', 900001, :'test_actor', :'test_actor');
COMMIT;

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
SELECT row_count::text AS test_r00_count, fingerprint AS test_r00_fingerprint
FROM pg_temp.phase4b5_seed_r00_baseline \gset
\echo Owner edge variables: linked_successor_activity=:linked_successor_activity linked_successor_stage=:linked_successor_stage descendant_successor_stage=:descendant_successor_stage missing_successor_stage=:missing_successor_stage valid_successor_stage=:valid_successor_stage test_valid_dependency=:test_valid_dependency
\echo Run phase4b3c3-schedule-deletion-seed-worker-stage-dates.sql as a direct Worker session, then phase4b3c3-schedule-deletion-seed-owner-dependencies.sql as a separate owner session before the deletion collision and runtime fixtures.
\echo Worker fixture IDs: workspace :test_workspace actor :test_actor viewer :test_viewer linked_product :test_linked_product linked_activity :test_linked_activity linked_activity_dependency :test_linked_activity_dependency linked_stage :test_linked_stage linked_stage_dependency :test_linked_stage_dependency descendant_product :test_descendant_product descendant_discipline :test_descendant_discipline descendant_stage :test_descendant_stage descendant_dependency :test_descendant_dependency missing_product :test_missing_product missing_activity :test_missing_activity missing_stage :test_missing_stage missing_dependency :test_missing_dependency valid_product :test_valid_product valid_activity :test_valid_activity valid_stage :test_valid_stage fixed_product :test_fixed_product explicit_activity :test_explicit_activity explicit_stage :test_explicit_stage partial_product :test_partial_product partial_activity :test_partial_activity partial_stage :test_partial_stage empty_product :test_empty_product empty_activity :test_empty_activity collision_activity :test_collision_activity late_colliding_operation :test_late_colliding_operation
\echo Worker psql variables A: test_workspace=:test_workspace test_actor=:test_actor test_viewer=:test_viewer test_linked_product=:test_linked_product test_linked_activity=:test_linked_activity test_linked_activity_dependency=:test_linked_activity_dependency test_linked_stage=:test_linked_stage test_linked_stage_dependency=:test_linked_stage_dependency test_descendant_product=:test_descendant_product test_descendant_discipline=:test_descendant_discipline test_descendant_stage=:test_descendant_stage test_descendant_dependency=:test_descendant_dependency
\echo Worker psql variables B: test_missing_product=:test_missing_product test_missing_activity=:test_missing_activity test_missing_stage=:test_missing_stage test_missing_dependency=:test_missing_dependency test_valid_product=:test_valid_product test_valid_activity=:test_valid_activity test_valid_stage=:test_valid_stage test_fixed_product=:test_fixed_product test_explicit_activity=:test_explicit_activity test_explicit_stage=:test_explicit_stage test_partial_activity=:test_partial_activity test_partial_product=:test_partial_product test_partial_stage=:test_partial_stage test_empty_product=:test_empty_product test_empty_activity=:test_empty_activity test_collision_activity=:test_collision_activity test_late_colliding_operation=:test_late_colliding_operation test_r00_count=:test_r00_count test_r00_fingerprint=:test_r00_fingerprint
