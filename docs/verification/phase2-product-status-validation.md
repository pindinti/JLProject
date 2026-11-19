# Phase 2 product status: Development verification

## Target and migration

- Project: `rapid-mud-63974868`; official branch: `development` (`br-delicate-glitter-b6mj0051`); database: `neondb`.
- Migration: `0034_product_status_study_workflow.sql`; SHA-256: `35CC637C78FB57B5005FC085E1641B2845F59B22E5A7FC0E088B71C10AC9BB2D`.
- Applied once on 2026-11-19 UTC using `neondb_owner`, `ON_ERROR_STOP=1`; the SQL emitted `COMMIT`. The CLI output did not retain an exact wall-clock timestamp.
- The script uses one `BEGIN`/`COMMIT`, checks prerequisites, installs a constrained active classification and controlled status function, changes the clone function, and revokes direct Worker `active` updates. It does not update existing product rows, schedules, audit records, or R00 snapshots.

## Isolated validation branch

Temporary branch `p2-0034-validation-20261119` (`br-muddy-base-b6ivrmbv`) was created from official Development with automatic expiration. Migration 0034 committed there before official execution. As `jlproject_worker`, rollback-only clone checks passed for `vigente`, `em_estudo`, and `arquivado` sources. Separate committed synthetic transactions passed study promotion, study demotion, archiving, explicit restoration, stale-version rejection, nonmember and foreign-workspace denial, one schedule-version increment per successful status operation, audit event/actor/reason checks, and exclusion of study activity dates from the vigente projection. Owner read-only inspection found ten distinct status operation IDs, no missing reasons, and no empty before/after differences across repeated synthetic runs. An initial test script attempted direct Worker audit-table reads and received the expected permission denial; the corrected script used the authorized cursor/operation read functions and passed. Synthetic fixtures were confined to this disposable branch.

The temporary branch was deleted after these results were recorded. Official Development was not restored, reset, or promoted from it.

## Official Development postflight

The new column is `NOT NULL`, defaults to `vigente`, and permits only `vigente`/`em_estudo`. `change_product_status` is owned by `neondb_owner`, is `SECURITY DEFINER`, and is executable by `jlproject_worker`; `clone_product` remains owner-owned, `SECURITY INVOKER`, and Worker-executable. The Worker has no direct `UPDATE` privilege on `products.active` or `products.planning_classification`, no `CREATE` on `public`, and no owner-role membership. All five existing products resolve to `vigente`; no archived product existed in the official preflight snapshot.

Identical read-only queries before migration, immediately after migration, and after rollback-only Worker tests returned:

| Item | Count | Unchanged fingerprint |
| --- | ---: | --- |
| Products | 5 (5 active, 0 archived) | `7379ea4444ea402db5b09978eb1d2ece` |
| R00 snapshots | 4 | `561afb1d7965f7b9e9bc57b8d70313c2` |
| Living Schedule cursors | 5 | `a6d577d52cadbfef702798dabf081553` |
| Disciplines | 29 | `9289a1d13229c3991086f4035ec03192` |
| Stages | 74 | `3b1938ffb6a7c000f4af949e58be7899` |
| Activities | 143 | `5415ebf7dbd8e85b4cfe27a587f5a1dd` |
| Business targets | 16 | `8be2933e1b5fa1ce20588ae85cc296c6` |

The operation count remained 3, with no official status operation; therefore no synthetic test record persisted. The official `jlproject_worker` rollback-only script passed ordinary creation defaults, three source clone statuses, clone R00, source preservation, and direct-write privilege checks. Local `.dev.vars` still names `jlproject_worker`; its connection string was not changed or reported.

The existing Phase 1.1 rollback-only Worker clone/import regression also passed after 0034. It verified copied planned stage dates in both working rows and the clone's new R00, import compatibility, grouped history, and unchanged pre-existing R00 snapshots.

## Automated checks and acceptance

- Focused product, Gantt, UI, and history tests: 6 files, 83 tests passed.
- Full suite: 56 files, 465 tests passed. Lint, typecheck, build, and `git diff --check` passed.
- The build reported a non-blocking client chunk-size advisory. No browser acceptance was performed.

Manual acceptance remains: verify status badges and study/archived banners, product search and status filters, the promotion visibility warning, archive and explicit restoration controls, archived read-only schedule access, clones from each source status, both vigente-only Executive Gantts, and status history text with actor, reason, and before/after values in an authenticated session.
