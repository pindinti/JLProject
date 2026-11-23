# Phase 4B.3c.1 — Activity Creation Dependency Guard

## Scope

This checkpoint protects activity creation only. The dependency routes remain unregistered, and no migration was executed. Migration `0041_guard_activity_creation_dependencies.sql` is additive and depends on migrations 0036–0040 being applied in order.

## Protected paths

- Manual date activity creation uses the existing Worker insert. Its query now locks the workspace before the active product. A private PostgreSQL `BEFORE INSERT` trigger validates all permitted inserts, including this path.
- Working-day activity creation calls the existing controlled database function. The function checks the same guard after authorization, calendar-version validation, hierarchy validation, and product locking, then returns structured `dependency_conflict` details before inserting.
- Product-root activities keep both parent IDs null. They do not alter a stage endpoint and pass through the database trigger unchanged.
- Existing import and clone inserts also encounter the database trigger. They construct new products with no dependency rows; their behavior and R00 contents are unchanged by this checkpoint.

The trigger is the integrity boundary for direct Worker `INSERT` permission retained by existing import and clone paths. It acquires workspace `FOR SHARE`, then product `FOR UPDATE`, matching the schedule/calendar lock order. It makes no date, dependency, or audit writes.

## D065 and conflict semantics

An activity insertion can affect a stage endpoint only when both stage planned boundaries are null. If either boundary is explicit, including a partial interval, D065 keeps the effective interval fixed and the guard does not project child dates into it.

For fully derived stages, the guard compares the current child min/max against the same aggregate including the proposed activity. It checks both inbound and outbound stage-to-stage edges, using the existing first-working-day helper and active workspace calendar exceptions. Activity-to-activity edges cannot refer to a not-yet-created activity, and root creation has no stage boundary to change.

The shared no-worsening comparison allows an existing violation when the dependency slack is unchanged or improved. Under D065, adding a child can only leave a fully derived stage interval unchanged or expand it: minimum start cannot move later and maximum finish cannot move earlier. Therefore strict improvement of a dependency violation is impossible from activity creation itself; the test fixture verifies that an unchanged pre-existing violation remains allowed.

## Atomicity, audit, and API behavior

A working-day conflict returns before the activity insert. A manual-path trigger rejection uses SQLSTATE `P4D01` with JSON detail; the repository validates its endpoint types and before/after evidence, then returns the same structured result. PostgreSQL statement rollback removes the attempted insert and any trigger effects. The API returns HTTP 409 with `code: dependency_conflict` and the verified conflict details in Brazilian Portuguese. Existing authorization remains at the authenticated Worker boundary and in the controlled working-day function. There is no activity row-version token for creation; working-day creation retains its existing calendar-version check.

## Verification status

`db/verification/phase4b3c1-activity-creation.sql` is a rollback-only Worker fixture for a disposable Development child. It requires owner-provisioned linked products/stages and has not been executed because migrations 0036–0041 remain unapplied. Focused local checks passed: 3 files / 75 tests, typecheck, lint, build, and `git diff --check`. Vite reported the existing nonblocking 636.96 kB client chunk advisory. Tests cover guard structure, conflict translation, authorization, root creation, and empty-graph API behavior.

## Remaining compatibility work

Activity hierarchy moves, stage/discipline hierarchy changes, deletion, and clone/R00 dependency remapping remain unguarded and block route activation. Migration 0041 must be reviewed with migrations 0036–0040 as one forward sequence; then run its rollback-only database fixture and the complete compatibility matrix before granting dependency writes or registering routes.
