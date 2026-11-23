-- Commit separate synthetic hierarchy shapes for reorder, reparent, D065, root, and empty-graph cases.
\i db/verification/phase4b5-seed-safety-owner.sql
\i db/verification/phase4b5-seed-auth-identities-owner.sql

SELECT md5('jlproject.phase4b3c2.workspace')::uuid AS test_workspace,
  md5('jlproject.phase4b3c2.conflict_product')::uuid AS test_conflict_product,
  md5('jlproject.phase4b3c2.valid_product')::uuid AS test_valid_product,
  md5('jlproject.phase4b3c2.fixed_product')::uuid AS test_fixed_product,
  md5('jlproject.phase4b3c2.root_product')::uuid AS test_root_product,
  md5('jlproject.phase4b3c2.empty_product')::uuid AS test_empty_product,
  md5('jlproject.phase4b3c2.conflict_source_discipline')::uuid AS test_conflict_source_discipline,
  md5('jlproject.phase4b3c2.conflict_destination_discipline')::uuid AS test_conflict_destination_discipline,
  md5('jlproject.phase4b3c2.valid_source_discipline')::uuid AS test_valid_source_discipline,
  md5('jlproject.phase4b3c2.valid_destination_discipline')::uuid AS test_valid_destination_discipline,
  md5('jlproject.phase4b3c2.fixed_source_discipline')::uuid AS test_fixed_source_discipline,
  md5('jlproject.phase4b3c2.fixed_destination_discipline')::uuid AS test_fixed_destination_discipline,
  md5('jlproject.phase4b3c2.root_discipline')::uuid AS test_root_discipline,
  md5('jlproject.phase4b3c2.empty_source_discipline')::uuid AS test_empty_source_discipline,
  md5('jlproject.phase4b3c2.empty_destination_discipline')::uuid AS test_empty_destination_discipline,
  md5('jlproject.phase4b3c2.conflict_source_stage')::uuid AS test_conflict_source_stage,
  md5('jlproject.phase4b3c2.conflict_destination_stage')::uuid AS test_conflict_destination_stage,
  md5('jlproject.phase4b3c2.conflict_source_successor')::uuid AS conflict_source_successor,
  md5('jlproject.phase4b3c2.conflict_destination_successor')::uuid AS conflict_destination_successor,
  md5('jlproject.phase4b3c2.valid_source_stage')::uuid AS test_valid_source_stage,
  md5('jlproject.phase4b3c2.valid_destination_stage')::uuid AS test_valid_destination_stage,
  md5('jlproject.phase4b3c2.valid_successor_stage')::uuid AS valid_successor_stage,
  md5('jlproject.phase4b3c2.explicit_stage')::uuid AS test_explicit_stage,
  md5('jlproject.phase4b3c2.partial_stage')::uuid AS test_partial_stage,
  md5('jlproject.phase4b3c2.fixed_successor_stage')::uuid AS fixed_successor_stage,
  md5('jlproject.phase4b3c2.root_stage')::uuid AS test_root_stage,
  md5('jlproject.phase4b3c2.root_successor_stage')::uuid AS root_successor_stage,
  md5('jlproject.phase4b3c2.empty_source_stage')::uuid AS test_empty_source_stage,
  md5('jlproject.phase4b3c2.empty_destination_stage')::uuid AS test_empty_destination_stage,
  md5('jlproject.phase4b3c2.setup_operation')::uuid AS setup_operation,
  '4b420000-0000-4000-8000-000000000101'::uuid AS test_conflict_dependency,
  md5('jlproject.phase4b3c2.conflict_source_definition')::uuid AS conflict_source_definition,
  md5('jlproject.phase4b3c2.conflict_destination_definition')::uuid AS conflict_destination_definition,
  md5('jlproject.phase4b3c2.conflict_source_successor_definition')::uuid AS conflict_source_successor_definition,
  md5('jlproject.phase4b3c2.conflict_destination_successor_definition')::uuid AS conflict_destination_successor_definition,
  md5('jlproject.phase4b3c2.valid_source_definition')::uuid AS valid_source_definition,
  md5('jlproject.phase4b3c2.valid_destination_definition')::uuid AS valid_destination_definition,
  md5('jlproject.phase4b3c2.valid_successor_definition')::uuid AS valid_successor_definition,
  md5('jlproject.phase4b3c2.explicit_definition')::uuid AS explicit_definition,
  md5('jlproject.phase4b3c2.partial_definition')::uuid AS partial_definition,
  md5('jlproject.phase4b3c2.fixed_successor_definition')::uuid AS fixed_successor_definition,
  md5('jlproject.phase4b3c2.root_definition')::uuid AS root_definition,
  md5('jlproject.phase4b3c2.root_successor_definition')::uuid AS root_successor_definition,
  md5('jlproject.phase4b3c2.empty_source_definition')::uuid AS empty_source_definition,
  md5('jlproject.phase4b3c2.empty_destination_definition')::uuid AS empty_destination_definition
\gset
SELECT md5('jlproject.phase4b3c2.conflict_activity')::uuid AS test_conflict_activity,
  md5('jlproject.phase4b3c2.conflict_other_activity')::uuid AS conflict_other_activity,
  md5('jlproject.phase4b3c2.conflict_destination_boundary_child')::uuid AS conflict_destination_boundary_child,
  md5('jlproject.phase4b3c2.conflict_source_successor_child')::uuid AS conflict_source_successor_child,
  md5('jlproject.phase4b3c2.conflict_destination_successor_child')::uuid AS conflict_destination_successor_child,
  md5('jlproject.phase4b3c2.valid_activity')::uuid AS test_valid_activity,
  md5('jlproject.phase4b3c2.valid_other_activity')::uuid AS valid_other_activity,
  md5('jlproject.phase4b3c2.valid_destination_boundary_child')::uuid AS valid_destination_boundary_child,
  md5('jlproject.phase4b3c2.valid_successor_child')::uuid AS valid_successor_child,
  md5('jlproject.phase4b3c2.fixed_activity')::uuid AS test_fixed_activity,
  md5('jlproject.phase4b3c2.fixed_successor_child')::uuid AS fixed_successor_child,
  md5('jlproject.phase4b3c2.root_activity')::uuid AS test_root_activity,
  md5('jlproject.phase4b3c2.root_successor_child')::uuid AS root_successor_child,
  md5('jlproject.phase4b3c2.root_boundary_child')::uuid AS root_boundary_child,
  md5('jlproject.phase4b3c2.empty_activity')::uuid AS test_empty_activity
\gset
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b5_seed_workspace', :'test_workspace', true);
DO $no_duplicate$
BEGIN
  IF EXISTS (SELECT 1 FROM public.workspaces WHERE id = current_setting('jlproject.phase4b5_seed_workspace')::uuid
       OR name = 'Synthetic Phase 4B.3c.2 hierarchy move workspace') THEN
    RAISE EXCEPTION 'Phase 4B.3c.2 seed was already applied to this child.';
  END IF;
END;
$no_duplicate$;
INSERT INTO public.workspaces (id, name)
VALUES (:'test_workspace', 'Synthetic Phase 4B.3c.2 hierarchy move workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'test_workspace', :'test_actor', 'admin', true), (:'test_workspace', :'test_viewer', 'viewer', true);
SELECT set_config('jlproject.schedule_actor_id', :'test_actor', true),
  set_config('jlproject.schedule_operation_id', :'setup_operation', true),
  set_config('jlproject.schedule_operation_type', 'product_created', true),
  set_config('jlproject.schedule_justification', 'Synthetic initial hierarchy schedule', true);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
VALUES (:'test_conflict_product', :'test_workspace', 'Synthetic Phase 4B.3c.2 conflict product', :'test_actor', :'test_actor'),
  (:'test_valid_product', :'test_workspace', 'Synthetic Phase 4B.3c.2 valid product', :'test_actor', :'test_actor'),
  (:'test_fixed_product', :'test_workspace', 'Synthetic Phase 4B.3c.2 fixed boundary product', :'test_actor', :'test_actor'),
  (:'test_root_product', :'test_workspace', 'Synthetic Phase 4B.3c.2 root product', :'test_actor', :'test_actor'),
  (:'test_empty_product', :'test_workspace', 'Synthetic Phase 4B.3c.2 empty graph product', :'test_actor', :'test_actor');
INSERT INTO public.product_disciplines (id, workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
VALUES (:'test_conflict_source_discipline', :'test_workspace', :'test_conflict_product', 'Conflict source', 'CS', '#336699', 0, :'test_actor', :'test_actor'),
  (:'test_conflict_destination_discipline', :'test_workspace', :'test_conflict_product', 'Conflict destination', 'CD', '#336699', 1, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c2.conflict_source_successor_discipline')::uuid, :'test_workspace', :'test_conflict_product', 'Conflict source successor', 'CSS', '#336699', 2, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c2.conflict_destination_successor_discipline')::uuid, :'test_workspace', :'test_conflict_product', 'Conflict destination successor', 'CDS', '#336699', 3, :'test_actor', :'test_actor'),
  (:'test_valid_source_discipline', :'test_workspace', :'test_valid_product', 'Valid source', 'VS', '#336699', 0, :'test_actor', :'test_actor'),
  (:'test_valid_destination_discipline', :'test_workspace', :'test_valid_product', 'Valid destination', 'VD', '#336699', 1, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c2.valid_successor_discipline')::uuid, :'test_workspace', :'test_valid_product', 'Valid successor', 'VSS', '#336699', 2, :'test_actor', :'test_actor'),
  (:'test_fixed_source_discipline', :'test_workspace', :'test_fixed_product', 'Fixed source', 'FS', '#336699', 0, :'test_actor', :'test_actor'),
  (:'test_fixed_destination_discipline', :'test_workspace', :'test_fixed_product', 'Fixed destination', 'FD', '#336699', 1, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c2.fixed_successor_discipline')::uuid, :'test_workspace', :'test_fixed_product', 'Fixed successor', 'FSS', '#336699', 2, :'test_actor', :'test_actor'),
  (:'test_root_discipline', :'test_workspace', :'test_root_product', 'Root stage discipline', 'RS', '#336699', 0, :'test_actor', :'test_actor'),
  (md5('jlproject.phase4b3c2.root_successor_discipline')::uuid, :'test_workspace', :'test_root_product', 'Root successor', 'RSS', '#336699', 1, :'test_actor', :'test_actor'),
  (:'test_empty_source_discipline', :'test_workspace', :'test_empty_product', 'Empty source', 'ES', '#336699', 0, :'test_actor', :'test_actor'),
  (:'test_empty_destination_discipline', :'test_workspace', :'test_empty_product', 'Empty destination', 'ED', '#336699', 1, :'test_actor', :'test_actor');
INSERT INTO public.stage_definitions (id, workspace_id, code, color)
VALUES (:'conflict_source_definition', :'test_workspace', 'MOVE-CS', '#336699'),
  (:'conflict_destination_definition', :'test_workspace', 'MOVE-CD', '#336699'),
  (:'conflict_source_successor_definition', :'test_workspace', 'MOVE-CSS', '#336699'),
  (:'conflict_destination_successor_definition', :'test_workspace', 'MOVE-CDS', '#336699'),
  (:'valid_source_definition', :'test_workspace', 'MOVE-VS', '#336699'),
  (:'valid_destination_definition', :'test_workspace', 'MOVE-VD', '#336699'),
  (:'valid_successor_definition', :'test_workspace', 'MOVE-VSS', '#336699'),
  (:'explicit_definition', :'test_workspace', 'MOVE-EXPLICIT', '#336699'),
  (:'partial_definition', :'test_workspace', 'MOVE-PARTIAL', '#336699'),
  (:'fixed_successor_definition', :'test_workspace', 'MOVE-FIXED-SUCC', '#336699'),
  (:'root_definition', :'test_workspace', 'MOVE-ROOT', '#336699'),
  (:'root_successor_definition', :'test_workspace', 'MOVE-ROOT-SUCC', '#336699'),
  (:'empty_source_definition', :'test_workspace', 'MOVE-EMPTY-SOURCE', '#336699'),
  (:'empty_destination_definition', :'test_workspace', 'MOVE-EMPTY-DEST', '#336699');
-- Leave stage dates null. Dated children below establish the derived predecessors' initial boundaries.
INSERT INTO public.discipline_stages (id, workspace_id, product_id, discipline_id, definition_id, display_name, display_order,
  created_by, updated_by, planned_start, planned_end)
VALUES (:'test_conflict_source_stage', :'test_workspace', :'test_conflict_product', :'test_conflict_source_discipline', :'conflict_source_definition', 'Conflict source stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_conflict_destination_stage', :'test_workspace', :'test_conflict_product', :'test_conflict_destination_discipline', :'conflict_destination_definition', 'Conflict destination stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'conflict_source_successor', :'test_workspace', :'test_conflict_product', md5('jlproject.phase4b3c2.conflict_source_successor_discipline')::uuid, :'conflict_source_successor_definition', 'Conflict source successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'conflict_destination_successor', :'test_workspace', :'test_conflict_product', md5('jlproject.phase4b3c2.conflict_destination_successor_discipline')::uuid, :'conflict_destination_successor_definition', 'Conflict destination successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_valid_source_stage', :'test_workspace', :'test_valid_product', :'test_valid_source_discipline', :'valid_source_definition', 'Valid source stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_valid_destination_stage', :'test_workspace', :'test_valid_product', :'test_valid_destination_discipline', :'valid_destination_definition', 'Valid destination stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'valid_successor_stage', :'test_workspace', :'test_valid_product', md5('jlproject.phase4b3c2.valid_successor_discipline')::uuid, :'valid_successor_definition', 'Valid successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_explicit_stage', :'test_workspace', :'test_fixed_product', :'test_fixed_source_discipline', :'explicit_definition', 'Complete explicit stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_partial_stage', :'test_workspace', :'test_fixed_product', :'test_fixed_destination_discipline', :'partial_definition', 'Partial explicit stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'fixed_successor_stage', :'test_workspace', :'test_fixed_product', md5('jlproject.phase4b3c2.fixed_successor_discipline')::uuid, :'fixed_successor_definition', 'Fixed successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_root_stage', :'test_workspace', :'test_root_product', :'test_root_discipline', :'root_definition', 'Root dependency stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'root_successor_stage', :'test_workspace', :'test_root_product', md5('jlproject.phase4b3c2.root_successor_discipline')::uuid, :'root_successor_definition', 'Root successor stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_empty_source_stage', :'test_workspace', :'test_empty_product', :'test_empty_source_discipline', :'empty_source_definition', 'Empty source stage', 0, :'test_actor', :'test_actor', NULL, NULL),
  (:'test_empty_destination_stage', :'test_workspace', :'test_empty_product', :'test_empty_destination_discipline', :'empty_destination_definition', 'Empty destination stage', 0, :'test_actor', :'test_actor', NULL, NULL);
INSERT INTO public.stage_activities (id, workspace_id, product_id, discipline_id, stage_id, name,
  planned_start, planned_end, display_order, created_by, updated_by)
VALUES (:'test_conflict_activity', :'test_workspace', :'test_conflict_product', :'test_conflict_source_discipline', :'test_conflict_source_stage', 'Synthetic conflict activity target', DATE '2026-11-09', DATE '2026-11-10', 0, :'test_actor', :'test_actor'),
  (:'conflict_other_activity', :'test_workspace', :'test_conflict_product', :'test_conflict_source_discipline', :'test_conflict_source_stage', 'Synthetic conflict source remaining activity', DATE '2026-11-03', DATE '2026-11-05', 1, :'test_actor', :'test_actor'),
  (:'conflict_destination_boundary_child', :'test_workspace', :'test_conflict_product', :'test_conflict_destination_discipline', :'test_conflict_destination_stage', 'Synthetic conflict destination boundary child', DATE '2026-11-03', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'conflict_source_successor_child', :'test_workspace', :'test_conflict_product', md5('jlproject.phase4b3c2.conflict_source_successor_discipline')::uuid, :'conflict_source_successor', 'Synthetic conflict source successor activity', DATE '2026-11-11', DATE '2026-11-12', 0, :'test_actor', :'test_actor'),
  (:'conflict_destination_successor_child', :'test_workspace', :'test_conflict_product', md5('jlproject.phase4b3c2.conflict_destination_successor_discipline')::uuid, :'conflict_destination_successor', 'Synthetic conflict destination successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_valid_activity', :'test_workspace', :'test_valid_product', :'test_valid_source_discipline', :'test_valid_source_stage', 'Synthetic valid reparent target', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor'),
  (:'valid_other_activity', :'test_workspace', :'test_valid_product', :'test_valid_source_discipline', :'test_valid_source_stage', 'Synthetic valid source remaining activity', DATE '2026-11-05', DATE '2026-11-05', 1, :'test_actor', :'test_actor'),
  (:'valid_destination_boundary_child', :'test_workspace', :'test_valid_product', :'test_valid_destination_discipline', :'test_valid_destination_stage', 'Synthetic valid destination boundary child', DATE '2026-11-05', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'valid_successor_child', :'test_workspace', :'test_valid_product', md5('jlproject.phase4b3c2.valid_successor_discipline')::uuid, :'valid_successor_stage', 'Synthetic valid successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_fixed_activity', :'test_workspace', :'test_fixed_product', :'test_fixed_source_discipline', :'test_explicit_stage', 'Synthetic fixed stage reparent target', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor'),
  (:'fixed_successor_child', :'test_workspace', :'test_fixed_product', md5('jlproject.phase4b3c2.fixed_successor_discipline')::uuid, :'fixed_successor_stage', 'Synthetic fixed successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_root_activity', :'test_workspace', :'test_root_product', NULL, NULL, 'Synthetic product-root move target', DATE '2026-11-03', DATE '2026-11-04', 900000, :'test_actor', :'test_actor'),
  (:'root_boundary_child', :'test_workspace', :'test_root_product', :'test_root_discipline', :'test_root_stage', 'Synthetic sole root scenario boundary child', DATE '2026-11-05', DATE '2026-11-05', 0, :'test_actor', :'test_actor'),
  (:'root_successor_child', :'test_workspace', :'test_root_product', md5('jlproject.phase4b3c2.root_successor_discipline')::uuid, :'root_successor_stage', 'Synthetic root successor activity', DATE '2026-11-06', DATE '2026-11-07', 0, :'test_actor', :'test_actor'),
  (:'test_empty_activity', :'test_workspace', :'test_empty_product', :'test_empty_source_discipline', :'test_empty_source_stage', 'Synthetic empty graph move target', DATE '2026-11-03', DATE '2026-11-04', 0, :'test_actor', :'test_actor');
COMMIT;

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
SELECT row_count::text AS test_r00_count, fingerprint AS test_r00_fingerprint
FROM pg_temp.phase4b5_seed_r00_baseline \gset
\echo Owner edge variables: conflict_destination_successor=:conflict_destination_successor conflict_source_successor=:conflict_source_successor valid_successor_stage=:valid_successor_stage root_successor_stage=:root_successor_stage
\set empty_destination_discipline :test_empty_destination_discipline
\echo Run phase4b3c2-hierarchy-move-seed-worker-stage-dates.sql as a direct Worker session, then phase4b3c2-hierarchy-move-seed-owner-dependencies.sql as a separate owner session before the runtime fixture.
\echo Hierarchy fixture IDs: workspace :test_workspace actor :test_actor viewer :test_viewer conflict_product :test_conflict_product conflict_activity :test_conflict_activity conflict_source_discipline :test_conflict_source_discipline conflict_source_stage :test_conflict_source_stage conflict_destination_discipline :test_conflict_destination_discipline conflict_destination_stage :test_conflict_destination_stage conflict_dependency :test_conflict_dependency valid_product :test_valid_product valid_activity :test_valid_activity valid_source_discipline :test_valid_source_discipline valid_source_stage :test_valid_source_stage valid_destination_discipline :test_valid_destination_discipline valid_destination_stage :test_valid_destination_stage fixed_product :test_fixed_product fixed_activity :test_fixed_activity fixed_source_discipline :test_fixed_source_discipline explicit_stage :test_explicit_stage fixed_destination_discipline :test_fixed_destination_discipline partial_stage :test_partial_stage fixed_successor_stage :fixed_successor_stage root_product :test_root_product root_activity :test_root_activity root_stage :test_root_stage root_discipline :test_root_discipline empty_product :test_empty_product empty_activity :test_empty_activity empty_source_discipline :test_empty_source_discipline empty_source_stage :test_empty_source_stage empty_destination_discipline :empty_destination_discipline empty_destination_stage :test_empty_destination_stage
\echo Worker psql variables A: test_workspace=:test_workspace test_actor=:test_actor test_viewer=:test_viewer test_conflict_product=:test_conflict_product test_conflict_activity=:test_conflict_activity test_conflict_source_discipline=:test_conflict_source_discipline test_conflict_source_stage=:test_conflict_source_stage test_conflict_destination_discipline=:test_conflict_destination_discipline test_conflict_destination_stage=:test_conflict_destination_stage test_conflict_dependency=:test_conflict_dependency test_valid_product=:test_valid_product test_valid_activity=:test_valid_activity test_valid_source_discipline=:test_valid_source_discipline test_valid_source_stage=:test_valid_source_stage
\echo Worker psql variables B: test_valid_destination_discipline=:test_valid_destination_discipline test_valid_destination_stage=:test_valid_destination_stage test_fixed_product=:test_fixed_product test_fixed_activity=:test_fixed_activity test_fixed_source_discipline=:test_fixed_source_discipline test_explicit_stage=:test_explicit_stage test_fixed_destination_discipline=:test_fixed_destination_discipline test_partial_stage=:test_partial_stage fixed_successor_stage=:fixed_successor_stage test_root_product=:test_root_product test_root_activity=:test_root_activity test_root_stage=:test_root_stage test_root_discipline=:test_root_discipline
\echo Worker psql variables C: test_empty_product=:test_empty_product test_empty_activity=:test_empty_activity test_empty_source_discipline=:test_empty_source_discipline test_empty_source_stage=:test_empty_source_stage test_empty_destination_discipline=:empty_destination_discipline test_empty_destination_stage=:test_empty_destination_stage test_r00_count=:test_r00_count test_r00_fingerprint=:test_r00_fingerprint
