# Phase 4B.3a — Individual date writer guards

**Status** — Backend and forward SQL prepared. Dependency routes and Worker dependency functions remain closed. The migrations require separate execution approval.

## Writers and enforcement

| Existing operation | Database enforcement |
| --- | --- |
| Root or stage activity `PATCH …/dates` | `change_activity_dates` delegates to the guarded `change_activity_planning` function. |
| Root or stage activity `PATCH …/working-plan` | The Worker still calculates the requested end using the authoritative working calendar. `change_activity_planning` checks the calendar token, membership, product and row version, then checks the actual proposed boundaries before writing. |
| Stage `PATCH …/dates` | `change_discipline_stage_dates` acquires the workspace and product locks in confirmation order and checks the staged date overlay before writing. |

Migration `0038` preserves the installed audited signatures and places the dependency guard after existing validation and before any date write or audit event. It evaluates active incident activity links and, for a child, incident links on its parent stage. Stage instances use their own explicit dates when either boundary is set. With both fields null they derive the interval from active children, including the proposed child edit. Changes that preserve the relevant boundaries, improve a standing violation, or stay within slack are allowed. With no incident edges the guard returns immediately. Plan-only activity edits skip the date guard.

The database computes old and proposed first working dates using the workspace exceptions under the workspace lock. The checked-in SQL built-in date literals match the Phase 4A calendar across 2026–2100. The parity test is a maintenance gate whenever the built-in calendar is updated. The Worker uses Phase 4A boundary assessment to validate rejection details and returns `409 dependency_preview_required` for an outbound Finish-to-Start violation. It returns `409 dependency_conflict` for an inbound violation, a removed required boundary, or an unevaluable calendar bound. Neither path writes another entity or initiates a cascade. The full Phase 4A preview retains its approved stricter inbound behavior.

The Worker removes the pre-lock on the product from activity date calls. Guarded database operations and confirmation lock workspace, active editor/admin membership, then active product before the target row. The existing audited primitive implementations are kept private for confirmed multi-row writes and the pending calendar batch path. Application roles cannot execute those primitives or directly update planned dates or planning fields. The existing invoker for dated stage creation still uses the guarded stage entry point. Its new stage has no incident links.

## Verification and deployment prerequisites

The forward SQL assumes migrations through `0037`, including the edge table and the date executor's calendar read grant. It checks the installed function anchors, preserves the existing audit ledgers and audit contexts, and rejects an open Worker privilege boundary. The Worker change can precede the migration because the installed activity writer already holds its own product lock. Rehearse that ordering to avoid retaining the former product-first Worker lock while validating the new SQL. The migration has not been executed and live SQL behavior remains unverified.

The [limited-Worker rollback test](../db/verification/phase4b3a-guard-date-writers.sql) requires a verified disposable Development child and a separately seeded synthetic fixture. Seed a fresh workspace named `Synthetic Phase 4B.3a date guard workspace` with an active editor or administrator and an untouched calendar. Create `Synthetic Phase 4B.3a linked product` with two derived stages linked predecessor to successor. Give the first stage a single unlinked child dated `2026-11-05` and the second a child dated `2026-11-09`. In the same product create a separate root-to-root link with the same dates. Create `Synthetic Phase 4B.3a empty product` with one manual root activity at version one and no edges. Supply the fixture IDs to the script via its `test_*` variables. The fixture must be committed separately so verification can exercise the once-per-transaction Living Schedule grouping. The test transaction itself rolls back. Rehearse competing graph/date calls against the same lock on the disposable child before activation.

## Remaining activation blockers

- **Phase 4B.3b.** Calendar apply and reversal can still change linked dates and derived stages. Apply deliberately uses the private audited activity primitive to preserve batch behavior until the complete final batch can be validated. The reversal continues through its existing writer. A row-by-row guard would incorrectly reject some valid complete batches and would miss final-state interactions.
- **Phase 4B.3c.** Child creation, activity reparenting, and activity, stage or discipline deletion can still alter linked derived boundaries or remove endpoints. Guard those paths before enabling dependencies. Cloning still needs link remapping and populated R00 compatibility. Rehearse dated stage creation, linked-stage deletion, lock order, clone behavior, and exact history with the limited Worker before granting dependency execution or wiring the routes.
