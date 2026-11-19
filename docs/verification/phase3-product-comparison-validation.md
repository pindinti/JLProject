# Phase 3 product comparison verification

## Acceptance and contract

The user reported 8/8 manual browser acceptance scenarios passed on 2026-11-19. Automated verification covered the authenticated read route, workspace and viewer access, all three statuses, distinct product selection, and the 2,000-entity limit. Oversized requests return `422` without a partial comparison. The Executive Gantt still reads only Vigente products.

The route reads both Living Schedules in seven scoped `SELECT` statements in one Neon transaction and returns `Cache-Control: no-store`. The comparison engine treats eligible matches as suggestions and preserves unmatched and ambiguous items. The pt-BR view compares A and B values, retains ancestor context under filters, and keeps targets separate. It preserves ISO civil dates and D065 stage-date semantics. Pairing and unlinking run locally in memory. Changing either product or refreshing clears decisions. A stale or unverified snapshot suspends pairing until refreshed.

## Live Neon evidence

Isolation branch `br-quiet-truth-b6spuzw5` (`p3-snapshot-validation-20261119`) was created from Development `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`, database `neondb`. Synthetic workspaces, memberships, products, and dated root activities were confined to the child branch. The runner invoked the real Worker route and membership repository with a supplied viewer identity, connecting to Neon as `jlproject_worker`. It verified all three statuses, rejected a foreign-workspace product, rejected a nonmember and `POST`, and confirmed the Worker could not read the audit state directly or update or delete R00.

The runner inserted an advisory lock probe between the actual product/cursor query and the six schedule reads in the Neon HTTP batch. It observed the waiting lock in PostgreSQL, then committed audited civil date changes for both synthetic products through a separate Worker connection. The real reader transaction reported `repeatable read` and `read_only=on`, returned both original cursors and leap-day end dates, and exposed both new dates and advanced cursors only on a fresh request. A `READ COMMITTED` negative control produced old cursors with new dates. The probe and negative control exist only in the verification runner.

For a rerun, create and verify an expiring Development child and its compute in Neon. Run `node db/verification/phase3-comparison-snapshot.mjs` with the verified `PHASE3_ISOLATED_BRANCH`, `PHASE3_ISOLATED_PARENT`, and `PHASE3_ISOLATED_ENDPOINT`. Supply `PHASE3_ISOLATED_OWNER_URL` and `PHASE3_ISOLATED_WORKER_URL` from the Neon CLI in the process environment. The runner requires the two database roles to use the same explicitly selected child compute. Delete the child after recording the result. This fixture commits synthetic records and must run on a disposable branch.

## Regressions and integrity

- Neon confirmed deletion of the disposable child, including its committed synthetic fixtures.
- Official Development was inspected read-only. Pre/post counts and fingerprints matched for products, the schedule hierarchy and targets, the six R00 snapshots, the seven Living Schedule cursors, and the nine audit operation headers. Worker role and schema privilege checks also matched. The checkpoint introduces no migration or persistent comparison storage.
- Focused comparison, cloning, status, and Executive Gantt regressions passed (10 files, 67 tests).
- The full automated suite passed (60 files, 504 tests). Lint, typecheck, local build, and whitespace checks passed.
- The build kept the comparison in its own lazy chunk (17.33 kB minified, 5.86 kB gzip). The existing advisory for the main client chunk remains. The generated local credentials copy was removed by the build cleanup script.

Pairing persistence, dual Gantt, merging, revisions, and product families remain outside Phase 3. The live runner exercises transaction consistency and database membership enforcement with a supplied viewer identity. Browser authentication was covered by the reported manual acceptance and the existing automated authentication tests.
