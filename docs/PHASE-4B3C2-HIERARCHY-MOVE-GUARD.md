# Phase 4B.3c.2 — Hierarchy Move Dependency Guard

## Scope and status

This checkpoint protects the existing hierarchy move operation. Migration `0042_guard_hierarchy_move_dependencies.sql` and the Worker response mapping are prepared; no migration was applied and dependency routes remain disabled.

The existing `POST /api/workspaces/:workspaceId/products/:productId/hierarchy/moves` endpoint delegates the complete operation to `public.move_schedule_item`. The database function authenticates an active editor or administrator, locks the workspace and product, checks the item version and source/destination order snapshots, and performs movement plus hierarchy audit in one transaction. The Worker still uses this path and returns structured HTTP 409 `dependency_conflict` details when PostgreSQL blocks a reparent.

## Guard behavior

Only an activity move to a different parent is checked. Same-parent reordering, discipline reordering, and stage reordering or reparenting do not change dependency endpoint dates and retain their existing behavior. The guard runs after authorization, product locking, stale-token checks, and ordering validation, but before hierarchy writes or audit context is established.

For a reparent, the private database guard projects source-child removal and destination-child addition together, then checks every stage-to-stage edge incident to either stage in stable edge-ID order. This makes the comparison use the intended final state even when both endpoints are affected. Activity-to-activity dependency dates do not change when an activity changes parent.

Fully derived stages use the projected min/max of their remaining or added children. Under D065, a stage with either explicit boundary, including a partial interval, keeps its stored effective dates. Moving an activity to or from the product root affects only the stage side. The shared no-worsening rule permits a preserved or improved existing violation and rejects a new or worsened conflict, including a newly missing boundary. No activity or stage dates are written by a move.

The helper is owned by `jlproject_date_executor`, has no Worker or public execute grant, and is called only from the executor-owned existing movement function. Migration preflight checks the prior dependency guards, the expected movement-function anchors and owner, and the Worker’s lack of direct hierarchy-column writes. It restores temporary owner capabilities and checks least privilege at postflight.

## Verification fixture

`db/verification/phase4b3c2-hierarchy-move.sql` is a rollback-only Development Worker fixture. It requires owner-provisioned products for: a derived-stage conflict with multiple affected edges; a valid derived move; explicit and partial fixed stages; a root/stage boundary case; and an empty graph. The fixture also checks pure reorder, stale versions, viewer rejection, unchanged schedule cursor and activity row after a blocked move, and rejection/rollback of a second operation for one product in one transaction. It has not been run because migrations `0036`–`0042` remain unapplied.

The psql variables are `test_workspace`, `test_actor`, `test_viewer`; `test_conflict_product`, `test_conflict_activity`, `test_conflict_source_discipline`, `test_conflict_source_stage`, `test_conflict_destination_discipline`, `test_conflict_destination_stage`, `test_conflict_dependency`; `test_valid_product`, `test_valid_activity`, `test_valid_source_discipline`, `test_valid_source_stage`, `test_valid_destination_discipline`, `test_valid_destination_stage`; `test_fixed_product`, `test_fixed_activity`, `test_fixed_source_discipline`, `test_explicit_stage`, `test_fixed_destination_discipline`, `test_partial_stage`; `test_root_product`, `test_root_activity`, `test_root_stage`, `test_root_discipline`; and `test_empty_product`, `test_empty_activity`, `test_empty_source_discipline`, `test_empty_source_stage`, `test_empty_destination_discipline`, `test_empty_destination_stage`. The fixture generates a fresh, distinct second operation ID; no audit-history seed is required.

All fixture entities must be active and belong to the supplied workspace. The conflict source must have at least two activities with the target first in display order; its linked stage edges must make the projected move worsen a dependency. The valid and fixed-boundary scenarios must permit the move; the fixed scenario uses one complete explicit stage and one partially explicit stage. The root scenario must allow root-to-stage and block moving the sole derived boundary back to root. The empty product must have no dependency rows. `test_actor` must be an active editor or administrator and `test_viewer` an active viewer. The operation-invariant negative assertion expects SQLSTATE `23514` and the exact one-operation-per-product transaction message; a nested exception block rolls back the attempted move before row and cursor comparisons.

Local tests cover migration contract anchors, final-state projection structure, repository conflict decoding, and the existing authenticated Worker route. They do not replace the rollback-only PostgreSQL fixture.

## Remaining compatibility work

Deletion and clone/R00 integration remain unguarded. They must be protected and verified before dependency routes can be activated. Migration execution, database fixture execution, and live compatibility verification require separate approval.
