# Consolidated Backlog After REL-05

This list separates shipped behavior from verification work, unresolved investigations, planned functionality, and deferred operational improvements. An item in the last three groups is not automatically a defect.

## Implemented and verified

- Authentication and server-side workspace membership/role checks.
- Product, discipline, stage, activity, target, and calendar workflows.
- Manual and working-day planning, calendar rescheduling/reversal, hierarchy movement, and logical deletion.
- Activity and consolidated product history backed by protected audit ledgers.
- Activity color overrides, product cloning, independent initial R00, and schedule/Gantt rendering.
- Production migration chain `0011`–`0027`; REL-05 schema, privilege, data-preservation and audit verification passed.
- Production Worker deployment `6d5dc648-0764-46bc-bf6c-8dcfee6d9ea1`; release owner reported 4/4 production smoke cases passed.

## Implemented; additional E2E or regression evidence remains useful

- Excel import: parser preview passed, but the attempted import created no product or `import_batches` row. The investigation did not establish a cause; treat the E2E result as inconclusive, not a confirmed defect. Reproduce with a new synthetic workbook and capture the confirmation request/response and Worker logs without personal or workbook contents.
- Logical deletion: implementation and release smoke acceptance exist; retain dedicated negative-path and subtree integrity coverage in the isolated verification suite.
- Cross-workspace isolation: automated and database-level checks exist; continue exercising representative isolation cases when changing authorization or repository code.
- Calendar concurrency and stale-version handling: database contracts and focused tests exist; expand two-session race coverage where a safe isolated fixture and rollback/recovery method are available.
- Viewer role: deferred in manual E2E acceptance. Confirm read-only visibility and absence of all mutation controls/endpoints in an isolated workspace.
- Excel import and permission regression tests should remain part of release quality gates.

## Known limitations and unresolved investigations

- Previously issued JWTs can remain usable until expiration after logout; the bounded delay was accepted for the small internal MVP and should be revisited before broadening access.
- Import E2E-11 remains an unresolved investigation; no root cause or product defect has been confirmed.
- Color metadata edits do not create immutable audit entries under the accepted D052 contract.
- Existing product history intentionally excludes metadata changes without audit sources and is not a formal revision feed.

## Functionality not implemented

- Formal visual revision management and publication of revisions after R00 (R01+).
- Gantt timeline-bar drag-to-reschedule. Hierarchy drag-and-drop is implemented and is a separate operation.
- Dependency management between activities; imported `Predecessora` values are intentionally ignored during initial import.
- Excel export.

## Deferred security, quality, and operations work

- Complete viewer-role E2E acceptance.
- Broader production security hardening and continued review of JWT revocation, rate limiting, and operational controls.
- Expanded audit coverage for metadata mutations where product decisions require it.
- PDF/printing support.
- Additional concurrent calendar and schedule stress tests on isolated databases.

## Archived verification tooling

The `db/verification/rel03*` and `rel04*` SQL/PowerShell files preserve focused rehearsal and rollback-only test procedures. Their branch IDs and fixture IDs are historical. Do not run them against Production or assume their old branches still exist. `rel05g-production-operator.ps1` is a separate production execution tool and requires the exact pinned production identity, approved manifest, external evidence, and phase-specific authorization described in [the REL-05 runbook](verification/REL-05G-PRODUCTION-EXECUTION.md).
