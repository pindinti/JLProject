# Phase 4B.3b.2 — Calendar reversal dependency guard

**Status** — Backend and forward SQL prepared. Dependency routes remain closed. Migration execution requires separate approval.

## Enforcement

`POST …/calendar-reschedules/:batchId/reverse` continues to call the existing `reverse_calendar_reschedule` database function. Migration `0040` adds the dependency check after locking the workspace, active editor/admin membership, active product, and selected activities and verifying the original append-only audit and live row state. The request still supplies the original batch ID and justification. Required versions come from the original apply audit, and the live row version must match that historical token. An absent original batch ID, inconsistent original audit, missing required token, deleted row, or stale row is rejected before reversal writes.

The shared calendar guard overlays every restored start and finish from the verified batch. It projects effective start and finish for each affected derived stage from its active children. Explicit D065 boundaries remain independent. It checks links where the predecessor finish or successor start changes, using the current workspace calendar for both the saved and projected state under the same calendar lock. Calendar apply continues to supply its existing finish-only input. A resulting violation blocks if it is new or the civil-day gap between the required start and saved successor start grows. Comparing the gap allows an improving reversal even when both endpoints move. Reversal still restores the original dates and saved planning calendar version. The current calendar is used only to evaluate dependencies.

The same guarded database entry point returns `dependency_conflict` with both typed endpoints, a reason, and before/after boundaries. The Worker verifies the evidence and responds with HTTP 409. The empty graph keeps the old write path. Successful reversals append distinct activity and reversal records to a single Living Schedule operation under the original authorization and justification checks. The original apply audit remains immutable. The private calendar guard is unavailable to the application role.

## Migration and verification

`0040` requires `0036`–`0039`, including the installed calendar apply guard, the private D065 interval resolver and working-date helper, and the existing reversal audit schema. The migration checks the existing audited reversal source, replaces the shared helper in place, and preserves the public reversal signature and its existing grants. It opens no dependency routes. The Worker accepts both the legacy and guarded reversal result contracts. The source and Worker tests do not establish live PostgreSQL behavior.

The [limited-Worker rollback fixture](../db/verification/phase4b3b2-calendar-reversal.sql) uses committed synthetic data on an authorized disposable Development child. Seed an active writer in `Synthetic Phase 4B.3b.2 workspace` and configure these products using separately committed setup transactions:

- `Synthetic Phase 4B.3b.2 blocked product` has a recorded, unreversed batch and a stage-to-stage dependency. After the batch, the derived predecessor finishes `2026-11-11` and its successor starts `2026-11-12`. Reversing restores a predecessor child finish of `2026-11-13` and worsens the bound under a calendar with no exception on these days. Supply one activity ID from this batch for the stale-row test.
- `Synthetic Phase 4B.3b.2 linked product` has two working-day activities in an unreversed batch. Their reversal improves a standing dependency violation, for example by restoring a derived predecessor finish from `2026-11-16` to `2026-11-12` for a successor starting `2026-11-10`. Before applying the selected two-row batch, create a distinct earlier apply/reversal cycle for only the lexicographically later activity. Its recorded reversal ID is the `test_colliding_reversal` value. A synthetic direct call reuses that ID with a fresh Living Schedule test operation ID so its second reversal audit insert collides after the first row. Add links after seeding history where needed to isolate the reversal cases.
- `Synthetic Phase 4B.3b.2 empty product` has an eligible original apply batch and no dependency links.

Use the named `psql` parameters in the fixture. The test transaction compares activity rows, the cursor and exact original activity event payloads. It checks structured rejection, stale-token precedence, late-failure rollback, linked restoration, original audit identity, and the empty-graph path. The migration and fixture have not been executed.

## Remaining activation blockers

Child creation, hierarchy changes, deletion, and clone/R00 integration remain open. A history entry can still display reversal eligibility based on row versions while the final dependency guard rejects the actual request. Presentation of that conflict is a later UI task. Before activation, rehearse concurrent reversal and date/graph changes, permissions, and exact audit grouping with the limited Worker on a disposable branch.
