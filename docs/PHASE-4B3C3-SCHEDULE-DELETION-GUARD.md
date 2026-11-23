# Phase 4B.3c.3 — Schedule Deletion Dependency Guard

## Scope and status

This checkpoint prepares dependency safeguards for the existing activity, stage, and discipline-subtree deletion operation. Migration `0043_guard_schedule_deletion_dependencies.sql` and the Worker conflict mapping are prepared only. No migration was applied, dependency routes remain disabled, and the rollback-only database fixture has not been run.

The Worker exposes deletion preview and confirmation routes. Both use the existing `preview_schedule_deletion` and `delete_schedule_subtree` PostgreSQL routines. PostgreSQL already rejects physical schedule deletes and does not grant the Worker permission to update `deleted_at` or `deletion_operation_id`; the controlled subtree routine is the only authorized deletion writer.

## Guard behavior

The guard first checks the complete preview item set against all active product dependency edges. A linked activity, stage, or descendant returns a typed `linked_endpoint` conflict. Deletion never removes dependency rows. The conflict includes the dependency, both typed endpoints, and one endpoint in the requested deletion set.

For an otherwise eligible deletion, the guard projects every activity in the deletion set out of its parent stage's child aggregate before checking any affected stage-to-stage edge. This evaluates the final schedule even when both dependency boundaries are affected. Fully derived stages use the remaining active children. Any explicit D065 boundary, including a partial interval, remains fixed. A resulting missing boundary, unavailable working-calendar boundary, or new/worsened finish-to-start violation returns structured details; unchanged or improved violations remain eligible.

The existing deletion operation now takes a workspace `FOR SHARE` lock before its product `FOR UPDATE` lock, preserving calendar/graph serialization without serializing deletions in different products. It retains membership and subtree row locks, recomputes the preview under those locks, and checks its fingerprint before returning a dependency conflict. The guard runs before `schedule_deletion_events` insertion or hierarchy updates. All activity, stage, and discipline updates and audit records remain in the original transaction. No dependency link is changed by this operation.

The preview endpoint reports the same conflict shape for early feedback. Confirmation always recomputes under lock, so a preview is not treated as authorization to delete. Existing database deletion triggers continue to reject physical deletes and direct Worker soft-delete writes.

## Verification fixture

`db/verification/phase4b3c3-schedule-deletion.sql` is a rollback-only Development Worker fixture. Its psql variables are `test_workspace`, `test_actor`, `test_viewer`; `test_linked_product`, `test_linked_activity`, `test_linked_activity_dependency`, `test_linked_stage`, `test_linked_stage_dependency`; `test_descendant_product`, `test_descendant_discipline`, `test_descendant_stage`, `test_descendant_dependency`; `test_missing_product`, `test_missing_activity`, `test_missing_stage`, `test_missing_dependency`; `test_valid_product`, `test_valid_activity`, `test_valid_stage`; `test_fixed_product`, `test_explicit_activity`, `test_explicit_stage`; `test_partial_product`, `test_partial_activity`, `test_partial_stage`; `test_empty_product`, `test_empty_activity`; and `test_late_colliding_operation`.

All entities must be active and belong to the supplied workspace. The actor must be an active editor or administrator and the viewer an active viewer. The linked product has direct activity and stage links. The descendant product has a stage dependency within the discipline subtree. In the missing-boundary product, the selected activity is the sole child of a derived stage endpoint. The valid deletion must preserve or improve an incident derived-stage constraint. The complete-explicit case uses `test_fixed_product`; the partial-explicit case uses a separate `test_partial_product`. Each product receives at most one successful operation in this fixture transaction, preserving the Living Schedule one-operation-per-product invariant. The empty product has no dependency edges. The collision operation ID must already exist in that empty product's deletion audit.

The local tests cover migration anchors, projected final-state logic, repository conflict validation, API authorization and conflict responses. They do not replace execution of the rollback-only PostgreSQL fixture. Migrations `0036`–`0043` and database fixture execution require separate approval.

## Deterministic PostgreSQL setup

On an authorized disposable child after migration `0043`, run `db/verification/phase4b3c3-schedule-deletion-seed-owner.sql` as `neondb_owner` with `phase4b5_disposable_child_verified=true`. Keep that owner session open through its R00 postflight. It commits one isolated workspace with seven products: direct activity and stage endpoints, a linked descendant discipline subtree, a sole-child derived boundary, a safe derived deletion whose remaining child preserves the end date, separate complete-explicit and partial-explicit stages, and an empty graph with two root activities. It adds the five required dependency edges through separate audited confirmation transactions. It does not write R00 rows.

Use the printed workspace, actor, product, activity, stage, dependency, and operation IDs with `db/verification/phase4b3c3-schedule-deletion-seed-worker.sql` in a direct Worker session. That script commits the expected operation-ID collision by calling `preview_schedule_deletion` and `delete_schedule_subtree`, verifies the deletion audit row and one cursor advance, then commits. Run `phase4b3c3-schedule-deletion.sql` in a new direct Worker transaction afterward; that test rolls back and expects its later collision probe to raise `unique_violation`. Never seed the collision by direct audit-table writes.

## Remaining activation risks

Clone/R00 dependency remapping remains unguarded. After that work, activation still requires applying the approved migration sequence in a disposable Development branch and executing the full compatibility matrix. No Production access or deployment occurred in this checkpoint.
