# Phase 1 — Living Schedule Audit and Concurrency Foundation

## Scope and decision

The existing product-scoped operational tables remain the canonical Living Schedule. R00 remains immutable. Phase 1 prepares transaction-grouped audit records and a per-product concurrency cursor without adding scenario storage, formal revisions, three-way merging, dependencies, or schedule propagation.

Decision D066 in `docs/08-TESTS-AND-DECISIONS.md` approves this foundation. Migration `0029_living_schedule_audit_concurrency.sql` was applied to Development after the privilege correction documented below. The repository's latest checked-in migration is 0028; the Development database and repository do not have a migration ledger.

## Mutation path inventory

| Schedule mutation | Current application/database path | Phase 1 capture |
| --- | --- | --- |
| Product create, metadata update, archive | `worker/products.ts` direct row insert/update | Product row trigger records changed values and actor; metadata needs no reason. |
| Product clone | `clone_product` controlled database operation | Row triggers record the new product's working rows as one provenance operation. Existing/source R00 rows are not updated. |
| Discipline create/update | Direct repository DML in `worker/schedule-repository.ts` | Product-discipline row trigger captures the entity change and product parent. |
| Stage create, metadata update, planned dates | `create_discipline_stage`, `create_discipline_stage_with_dates`, `update_discipline_stage`, and `change_discipline_stage_dates` | Stage row trigger captures the change; explicit planned dates are separate from derived stage dates; specialized stage-date records are linked. |
| Activity create, metadata update, manual/working date edit | Direct create/update SQL and controlled `create_activity_with_working_plan`, `change_activity_dates`, and `change_activity_planning` calls | Activity trigger captures entity changes; date/working-plan ledgers are linked. Date-bearing manual creation requires a reason. |
| Target create/update/delete | Direct target insert, `update_business_target`, and the reason-bearing `delete_business_target_with_reason` wrapper | Target trigger captures changes and links target-date history. Date-bearing creation/update/deletion requires the applicable reason. The Worker cannot execute the legacy delete function directly after migration. |
| Hierarchy movement and subtree deletion | `move_schedule_item` and `delete_schedule_subtree` controlled operations | Row triggers group changed hierarchy rows; movement/deletion ledgers are linked with operation and reversal references. Reasons are required. |
| Workspace-shared stage-definition color | Direct update in `worker/schedule-repository.ts` | Stage-definition trigger emits detail for affected product schedules; no reason is required for this cosmetic change. |
| Initial Excel import | `import_initial_schedule` from `worker/import-repository.ts` | A single provenance operation groups inserted schedule rows without inventing a manual-change reason. |
| Calendar reschedule/reversal | `apply_calendar_reschedule` and `reverse_calendar_reschedule` controlled operations | Changed activity rows and specialized batch/date/reversal records share an operation; reasons and reversal links are retained. |
| Workspace calendar configuration | `change_workspace_calendar` in `worker/calendar-repository.ts` | Remains in the existing workspace-scoped calendar version and event history. It does not itself mutate stored product schedule rows; applying/reversing a reschedule does advance product schedule versions. |

Member administration, read-only projection/Gantt queries, previews, and reads do not mutate the Living Schedule and are outside this product schedule cursor.

## Prepared persistence model

Migration 0029 adds:

- `product_schedule_state`, with one `(workspace_id, product_id)` row, monotonic `schedule_version`, and `history_watermark`.
- `product_schedule_operations`, with one actor/time/operation header per product and PostgreSQL transaction.
- `product_schedule_operation_events`, with append-only entity-level change type, hierarchy before/after, and changed values.
- `product_schedule_operation_links`, which connects new operation groups to existing specialized audit ledgers and reversal sources.
- Row triggers on products, product disciplines, stages, activities, business targets, and shared stage definitions.
- Authorized security-definer cursor/history reads and a reason-bearing target-delete wrapper.

The first audit detail for a product in a transaction locks and advances that product's cursor exactly once. More detail rows in that same transaction reuse the operation header and version. The unique `(workspace_id, product_id, transaction_id)` constraint rejects a second logical operation for that product in one database transaction. Multi-entity operations therefore have one operation ID/version and multiple details. Each product touched by a cross-product change advances its own cursor once.

Current row-version tokens remain the write-time stale-edit checks. The global schedule version is a consistent source-state cursor for future snapshot capture, not a replacement client-side compare-and-swap token. A future scenario capture must read source schedule rows and the version/watermark pair in one consistent transaction snapshot.

The audit trigger and detail write share the schedule DML transaction. If a required actor, reason, operation context, audit insert, or later database step fails, the schedule mutation and cursor/audit changes roll back together. Audit tables reject update/delete/truncate and are owned by the no-login `jlproject_date_executor`; the Worker has no direct audit-table or internal-writer privilege. Migration postconditions check Worker function/table boundaries and temporary schema/role privilege revocation. The reason-bearing target delete wrapper is the only Worker delete operation after migration.

For controlled operations that already append specialized date ledgers, new operation details link those ledgers rather than repeating the detailed date values. Direct date updates outside those known controlled operation types retain their before/after date values in the generic operation detail. This preserves capture for direct repository DML paths.

## History compatibility and known gaps

Existing specialized product-history records are preserved and not backfilled into the new operation ledger. No pre-cutover history is fabricated. Existing R00 snapshots are not read for mutation or changed by this migration.

The current `/change-history` API/UI continues to use its specialized event feed and pagination. The Worker is granted access to the new security-definer `list_product_schedule_operations` function, but Phase 1 does not merge the grouped generic operation records into that UI feed. This avoids duplicating existing date, hierarchy, deletion, and reversal entries and avoids introducing a new history workflow. A separately approved presentation change is needed before generic metadata/entity detail is visible through the existing history dialog.

Workspace-calendar changes remain in the separate workspace-scoped calendar audit. Existing legacy history gaps documented by D050 remain explicit. The new cursor begins at zero for each preexisting product; it is not a claim that earlier operations were captured.

## Migration state and safety

- Target verified read-only: Neon project `rapid-mud-63974868`, branch `development` (`br-delicate-glitter-b6mj0051`), database `neondb`.
- Checked-in predecessor: `0028_stage_date_planning_audit.sql`; no live or repository migration ledger exists.
- Next available migration filename: `0029_living_schedule_audit_concurrency.sql`.
- Migration 0029 is wrapped in `BEGIN`/`COMMIT`, performs a precondition check, takes write-blocking locks on schedule tables while seeding cursor rows and installing triggers, and includes no intentional changes to existing schedule/R00 rows. PostgreSQL transactional DDL means a statement failure before `COMMIT` rolls back the migration.
- Migration 0029 completed with `COMMIT` on the verified Development target. Corrected SHA-256: `C26D9E4DF65946C5B4D72A1B482E93A99F076EF837EB856CECC3D90288CB0626`.
- Neon CLI output did not include an execution time, and PostgreSQL reports `track_commit_timestamp=off`; only the execution date, 2026-11-18 UTC, can be recorded reliably.
- The Development recovery branch `dev-pre-0029-20261118` (`br-small-bird-b6ubv4r2`) remains ready and expires at `2026-11-25T02:00:00Z`. No restore/reset was performed.
- No Production access or deployment occurred.

### Applied migration privilege matrix

The privilege audit was checked against the Development catalogs before execution and against role/ownership catalogs after `COMMIT`.

| Statements | Object scope | Active role and required evidence | Result |
| --- | --- | --- | --- |
| Lines 1–39 | Preconditions and locks on existing schedule tables | `neondb_owner`; owns or can lock the verified tables; 0028 contract and role state checked | Transaction begins and locks the schedule tables before trigger installation. |
| Lines 40–117 | Four internal schedule tables, indexes, and seed rows | `neondb_owner`; verified `public` schema `CREATE`; new relations initially owned by migration role | Tables and indexes are created additively; no existing schedule or R00 rows are updated. |
| Lines 120–143 | Append-only guard function and triggers on new audit tables | `neondb_owner`; owns the new tables/function at creation | Update/delete/truncate are rejected; the guard function is later transferred to executor ownership. |
| Lines 147–667 | Capture, source-link, cursor/history, and target-delete functions | `neondb_owner`; verified `public` schema `CREATE`; security-definer functions use fixed `pg_catalog, pg_temp` search paths and qualified public objects | Functions are created without granting the Worker direct writer access; ownership transfers are limited to the executor-owned operation set. |
| Lines 669–684 | Six capture triggers on products, disciplines, stages, activities, targets, and stage definitions | `neondb_owner`; owns each trigger target and trigger function at creation | Core row capture triggers are installed once on the expected tables. |
| Lines 688–704 | Seven source-ledger link triggers | Temporary `SET` membership for `jlproject_date_executor`; catalog inspection confirmed executor ownership/trigger rights on the seven ledgers; temporary grant is revoked later | Triggers are created as executor-owned triggers, then role is reset. |
| Lines 706–724 | Worker revocations and executor read/write/function grants | `neondb_owner`; table/function ownership and role grants verified | Worker receives no direct internal-table or writer permission; executor receives only selected reads, internal inserts/state updates, and writer execution. |
| Lines 727–741 | Internal table/function ownership transfers | `neondb_owner` temporarily grants schema `CREATE` and verified `SET` membership | Internal objects transfer to `jlproject_date_executor`; executor is the owner of the audit path. |
| Lines 742–750 | Legacy target-delete revocation, authorized Worker wrapper grants, temporary privilege cleanup | `SET ROLE jlproject_date_executor` for executor-owned function ACL changes, then reset; migration role revokes its temporary schema and membership grants | Worker can call the reason-bearing delete wrapper, not the legacy bypass; temporary elevated access is absent before commit. |
| Lines 752–782 | Final assertions and commit | `neondb_owner`; checks Worker ACLs, no executor membership, no executor schema `CREATE`, and six core triggers | Assertions passed and the transaction committed. |

### Execution and verification outcome

Read-only post-commit checks confirmed the 0029 tables, functions, and triggers exist with the expected executor ownership; fixed security-definer search paths; no Worker direct access to audit/internal tables or writer/link functions; and no temporary executor membership or schema `CREATE`. The Worker retains execute access to the cursor/history readers and reason-bearing target-delete wrapper, but not the legacy target-delete function. No seed operation/event/link rows were created, and all five preexisting product cursors remain at version zero.

The rollback-only Worker integration run stopped during its first transaction. Creating a second explicit-date stage under the same operation ID raised `duplicate key value violates unique constraint "stage_date_changes_pkey"`. The column is the specialized stage-date ledger's primary key, so this schema does not currently represent multiple stage-date entities under one grouped operation. The connection ended and rolled back the transaction. Read-only verification found no synthetic product, no generic operation/event/link rows, and unchanged core counts (5 products, 74 stages, 143 activities, 4 R00) and R00 fingerprint (`d3d2f3794ad3a9aa0c540b0dd20b397b`). The remaining rollback-only blocks for import/clone and calendar reschedule/reversal did not run. Do not claim end-to-end database integration coverage complete until this compatibility issue is resolved and the approved checks pass.

The minimum follow-up is an approved additive schema/function correction that allows multiple stage-date audit details in one logical operation while preserving append-only history, per-stage/version uniqueness, and source-link identity. No corrective migration has been prepared or applied in this phase.

Static and local verification: focused migration/repository tests, 3 files / 16 tests passed; full suite, 52 files / 433 tests passed; lint, typecheck, build, and `git diff --check` passed. The migration integration blocker above remains open.

The no-ledger workflow requires a human-reviewed migration record outside new database infrastructure: filename, SHA-256, exact project/branch/database, execution time in UTC, execution result, and post-migration verification outcome.

## Validation boundary

Unit/API/repository tests and static migration-contract tests can run before application. They can verify request validation, justifications, identity/version inputs, repository SQL shape, migration guards, append-only design, operation uniqueness, and permission assertions. They cannot prove the live PostgreSQL trigger order, ownership, transaction rollback, executor membership, or runtime function behavior before migration application.

The approved migration is applied, but the full rollback-only synthetic Development matrix is incomplete because the stage-date ledger rejects repeated operation IDs. Resolve the stage-date audit identity incompatibility under separate authorization, then rerun the complete rollback-only matrix for grouping/versioning, failure rollback, stale row tokens, all mutation paths, Worker permissions, clone/import behavior, rescheduling/reversal, and unchanged R00/schedule fingerprints. Do not leave synthetic rows or access Production.

### Migration 0030 multi-entity grouping correction preparation

The authorized correction follows the previous stage-date failure. The current Development target was read-only checked as Neon project `rapid-mud-63974868`, branch `development` (`br-delicate-glitter-b6mj0051`), database `neondb`; the 0029 operation/audit objects and expected owners are present. The applied 0029 SHA-256 is `C26D9E4DF65946C5B4D72A1B482E93A99F076EF837EB856CECC3D90288CB0626`. No migration was executed during this correction.

The complete ledger review found only one current-key collision that blocks an existing multi-entity operation: `stage_date_changes.operation_id` is both the logical group ID and the primary key. The reviewed catalog showed no inbound foreign key to that key; its independent `UNIQUE (stage_id, version_after)` constraint carries per-stage concurrency. Migration 0030 adds `event_id`, backfills historical IDs as `event_id = operation_id` (preserving existing `stage-date:<id>` keys), changes the stage ledger primary key to `event_id`, and retains the now nonunique group `operation_id` plus the stage/version unique constraint.

| Ledger | Current semantics and references | Correction decision |
| --- | --- | --- |
| `stage_date_changes` | One stage date event; current primary key is `operation_id`; unique stage/version protects stale-write history. History function formats IDs as `stage-date:<operation_id>`. | Separate immutable event ID from group ID. No inbound FK was found. Replace the history function's key expression with `event_id` while keeping old IDs stable; include the group ID in the item metadata. |
| `activity_date_changes` | One activity date event per unique operation ID; unique activity/version. Calendar apply/reversal use distinct per-activity date-operation IDs and separate batch IDs. | Preserve ledger keys; link calendar events to exact activity events. |
| `business_target_date_changes` | One target date event per operation ID; unique target/version. Current controlled writer changes one target at a time. | Preserve current semantics. There is no multi-target batch writer; if added later, define event/group identity before implementing it. |
| `hierarchy_movement_events` | One summary event per controlled move; generic operation details capture affected hierarchy rows. | Preserve both layers; no collision found. |
| `schedule_deletion_events` | One summary event per subtree deletion; deleted rows reference its operation ID. | Preserve its summary semantics and references. |
| `calendar_reschedule_changes` | One row per activity keyed by date operation ID, plus a distinct batch operation ID and batch/activity uniqueness. | Preserve; exact date event IDs are used in new source links. |
| `calendar_reschedule_reversals` | One row per reversed activity keyed by reversal date operation ID, with exact original event and original/reversal batch IDs. | Preserve; expand legacy batch links to every exact reversal and exact original event. |
| `product_schedule_operation_links` | Migration 0029 generic-to-specialized references are unique by operation group and source operation, so reversal batch links cannot distinguish all activity events. | Keep every legacy row unchanged; add exact event-level links in `product_schedule_operation_source_events`. |

The new source table records schedule scope, generic operation/version, source ledger, source operation/group ID, exact source event ID, and link kind. Its primary key prevents duplicate exact source links in one grouped operation. The new generic-detail trigger links stage rows already written under that operation ID. The replaced specialized-ledger source trigger preserves old compatibility links and writes exact links for later source-ledger inserts; for calendar reversals it writes both the reversal event and its original date event. It does not write generic events, so the trigger path does not recurse.

The application repository contract now keeps optional `item.operationId` in product-history responses so two stage events keep distinct event IDs and expose their shared group ID. No history UI was changed. Existing specialized history rows retain their IDs because of the backfill. Generic Living Schedule details are still not surfaced in the existing history interface and remain a required follow-up before completing the revision/scenario feature.

The rollback-only integration script is prepared at `db/verification/phase1-0030-rollback.sql`; the original 0029 script is preserved. After separate migration authorization, it tests two stage-date events under one operation, exact stage history/source identity, per-stage versions, audit/version rollback after a forced post-write failure, workspace scoping, no direct Worker bypass, existing clone/import/R00 checks, and exact activity/calendar/reversal links with one product version advance. It has not been executed because migration 0030 is not applied.

Migration 0030 is `db/migrations/0030_multi_entity_audit_grouping.sql` (prepared SHA-256: `0591E6960F419F8B29FE17FD8C21D178EB64084EBF393437DBA83A3AB82DCDF1`). It starts `BEGIN` and commits only after final checks. The preflight requires `neondb_owner`, `neondb`, the applied 0029 schema, the expected stage primary key and unique version constraint, no inbound stage-ledger FKs, no preexisting 0030 objects/indexes, public schema `CREATE`, and ability to grant temporary executor membership. DDL and audit backfill run as the existing `jlproject_date_executor`; temporary schema `CREATE` and role membership are revoked before commit. The migration adds no Worker table privileges, keeps the history reader's existing Worker execute permission, and asserts that Worker cannot execute internal link functions or directly read/write the new table. Security-definer functions use `search_path=pg_catalog, pg_temp`.

Local verification for the prepared correction passed: focused migration/repository tests, 2 files / 11 tests; full suite, 53 files / 439 tests; lint; typecheck; build; and `git diff --check`. The build completed without a bundle-size advisory. No live PostgreSQL write-path test was run.

Migration execution and database integration checks remain pending separate approval. Migration 0030 has not been applied; no Development write, schedule modification, role/grant change, R00 modification, Production access, deployment, Phase 2 work, or commit occurred in this preparation. Phase 1 database verification is therefore not complete.

### Migration 0030 execution and verification addendum

This addendum supersedes the migration-pending statements above; the preparation record remains historical. Migration `0030_multi_entity_audit_grouping.sql`, SHA-256 `0591E6960F419F8B29FE17FD8C21D178EB64084EBF393437DBA83A3AB82DCDF1`, completed with `COMMIT` on 2026-11-18 UTC against Neon project `rapid-mud-63974868`, Development branch `development` (`br-delicate-glitter-b6mj0051`), database `neondb`, using `neondb_owner` and `ON_ERROR_STOP=1`. The CLI did not return a commit timestamp, and `track_commit_timestamp` is off; only the execution date is known. No migration ledger was created and migration 0030 was not rerun.

The project uses PostgreSQL 18 and a six-hour history-retention window. The available `dev-pre-0029-20261118` branch (`br-small-bird-b6ubv4r2`) is ready through `2026-11-25T02:00:00Z`, but it predates migrations 0029 and 0030; it is not a direct recovery point for the current schema. No restore/reset was performed.

Read-only catalogs verified the new stage `event_id` primary key, retained stage/version uniqueness, append-only exact source-event table and triggers, executor ownership/fixed search paths, expected Worker readers and controlled operations, no Worker direct access to internal audit tables or internal writers, and revocation of temporary executor membership/schema `CREATE`. Pre/post counts and fingerprints matched: 5 products, 29 disciplines, 74 stages, 143 activities, 16 targets, 4 R00 snapshots, 5 cursors, and unchanged specialized ledger payloads. The R00 fingerprint remained `561afb1d7965f7b9e9bc57b8d70313c2`.

Rollback-only Worker checks passed for grouped stage/activity/target/hierarchy/deletion operations, stage-date source/history identity, stale versions, failure rollback, actor/reason attribution, workspace isolation, and one version advance for the grouped synthetic operation. A single-stage event identity check also passed. Clone assertions verified explicit stage dates in cloned working data and the clone's new R00 before the combined clone/import transaction failed at `import_initial_schedule`. That function is `SECURITY INVOKER` and inserts `stage_activities.source_external_id`; the existing migration 0014 Worker column-level insert grant omits this column. The Worker received `permission denied for table stage_activities`. This import authorization gap is outside migration 0030 and requires a separately reviewed least-privilege correction. The failed transaction rolled back; post-run counts and fingerprints show no synthetic residue or changes to existing R00. The calendar reschedule/reversal block was not reached in the full `ON_ERROR_STOP` run; it passed in an isolated rollback-only Worker run after adding its missing test variable declarations.

Focused migration tests passed (6 tests), the full local suite passed (53 files / 439 tests), lint and typecheck passed, and build passed with the existing client chunk-size advisory. `git diff --check` passed. The generated `dist/worker/.dev.vars` was removed by build cleanup; `.dev.vars` and the local Worker connection were not changed. The complete database integration matrix is not yet verified, so no checkpoint commit was created. Generic operation details remain absent from the existing product-history UI and must be integrated without duplicating specialized audit events before the revisions/scenarios feature is complete. No Production access, deployment, or Phase 2 work occurred.

## Import authorization compatibility preparation

Read-only catalog inspection reconfirmed Neon project rapid-mud-63974868, Development branch development (br-delicate-glitter-b6mj0051), and database neondb. Migrations 0029 and 0030 objects and audit permissions are present. Migration 0014 revokes table-level INSERT on stage_activities and grants column-level inserts without source_external_id. The existing migration-0005 import_initial_schedule function is SECURITY INVOKER and inserts source_external_id. This is a preexisting omitted column privilege, not a Phase 1 regression.

The Worker API requires an active editor/admin membership, validates imports, sets the authenticated schedule actor and operation context, and calls the importer. The database function independently checks active membership. Catalog review found the remaining import-path table, column, function, row-lock and sequence requirements available; no import-path sequence dependency was found. Worker R00 INSERT remains available for initial creation while UPDATE/DELETE are denied and the immutable trigger is enabled. The stage activity schedule-audit trigger and the 0029/0030 generic audit path remain enabled.

The prepared migration is db/migrations/0031_import_authorization_compatibility.sql, SHA-256 80F7595DE74E4D7C2E206B7E537241952A950FF7ABB74BD43F0FF2FE297BD884. It adds only INSERT on stage_activities.source_external_id for jlproject_worker, retaining SECURITY INVOKER execution and all other Worker restrictions. Its transaction guards check expected ownership, function configuration, import-path privileges, audit triggers, R00 protections, executor separation, and post-grant least privilege. It has not been applied. The read-only report is db/verification/phase1-import-authorization-preflight.sql. The prepared Worker script db/verification/phase1-import-authorization-rollback.sql checks authorized creation, T001 provenance, grouped audit/cursor state, replay/conflict/duplicate handling, unauthorized actors, R00 immutability, and rollback after duplicate-source failure; it uses two explicit ROLLBACK statements and has not been run.

Both R00 fingerprints were computed from the same four current records but use different serialization inputs: whole-row JSON produces d3d2f3794ad3a9aa0c540b0dd20b397b, while id|snapshot produces 561afb1d7965f7b9e9bc57b8d70313c2. The fingerprints therefore are not directly comparable. Same-method pre/post values matched, and no R00 data was changed.

Static migration tests passed (4 tests), the full suite passed (54 files, 443 tests), lint/typecheck/build passed, and git diff --check passed. Build emitted the existing client chunk-size advisory. The live import integration block and remaining Phase 1 matrix must be rerun after the separately authorized migration. No application code, database records, roles, grants, or Production resources were modified during this preparation.
## Migration 0031 execution and final Phase 1 integration

Migration 0031, db/migrations/0031_import_authorization_compatibility.sql, SHA-256 80F7595DE74E4D7C2E206B7E537241952A950FF7ABB74BD43F0FF2FE297BD884, completed with COMMIT on 2026-11-18 UTC against Neon project rapid-mud-63974868, Development branch development (br-delicate-glitter-b6mj0051), database neondb, as neondb_owner with ON_ERROR_STOP=1. The Neon CLI did not return a database commit timestamp; exact execution time is unavailable. No migration ledger was added and no previous migration was rerun.

Read-only preflight confirmed the 0029/0030 schema and audit objects, Worker import-path permissions, importer ownership and SECURITY INVOKER mode, fixed search_path, active schedule and R00 triggers, and the absence of the one source_external_id INSERT privilege. Read-only postflight verified that the grant is column-only. Worker has source_external_id INSERT but no UPDATE; no table-level stage_activities INSERT/UPDATE/DELETE; no planned-date UPDATE or planning-field INSERT; no executor membership or public schema CREATE; no audit writer or internal operation-table access; and no R00 UPDATE/DELETE. The importer workspace authorization and audit trigger remain active.

The Worker import rollback script initially had a missing closing parenthesis in its JSON test fixture; PostgreSQL stopped before executing the test block. The verification script alone was corrected, no migration was rerun, and the failed parse left no data changes. The corrected import integration passed as jlproject_worker, including authorized import, source identity, hierarchy and date preservation, R00 creation/immutability, grouped event and version state, replay/conflict/duplicate handling, authorization denials, and duplicate-source failure rollback. Both test transactions explicitly rolled back.

The complete four-block rollback-only matrix in db/verification/phase1-0030-rollback.sql passed as jlproject_worker. It covered stage/activity and target changes, hierarchy movement and deletion, multi-entity grouping, event IDs and source links, reasons and actor attribution, stale versions, atomic rollback, workspace authorization, clone and clone R00, initial import, calendar rescheduling and reversal, audit append-only protections, and history compatibility. All four blocks ended in ROLLBACK.

The same read-only state-summary file was run before migration, after migration, and after both integration suites. Counts and fingerprints were identical: 5 products, 29 disciplines, 74 stages, 143 activities, 16 targets, 4 R00 snapshots, and 5 schedule cursors. No schedule, audit, or cursor changes remained. The id|snapshot R00 fingerprint was unchanged at 561afb1d7965f7b9e9bc57b8d70313c2.

Recovery review found Neon history retention of six hours and an existing ready branch dev-pre-0029-20261118 (br-small-bird-b6ubv4r2), expiring 2026-11-25T02:00:00Z. That branch predates 0029/0030 and is not a recovery point for the current schema. No branch was created, restored, or reset.

Targeted checks passed (7 files, 94 tests); the full test suite passed (54 files, 443 tests); lint, typecheck, build, and git diff --check passed. Build produced no bundle-size advisory. Generic Living Schedule event presentation in the product-history UI remains an explicit follow-up before revisions/scenarios work is considered complete. No Production access, deployment, or Phase 2 work occurred.

### Final import-target coverage and regression refinement

The standalone import fixture now includes synthetic source target T901. It asserts the stored target and operational dates, status, notes, the Cronograma Produto and Metas e Premissas source-row references, the clone-independent import R00 target payload, and five grouped schedule detail events. The Worker import script and complete Phase 1 matrix were rerun after this addition; both passed as jlproject_worker with all transactions rolled back. The same before/after state-summary query still matches. Migration 0031 was not rerun.

A full-suite run exposed a test timing race because the Gantt calendar-highlight test asserted a holiday before the asynchronous calendar response arrived. The test now waits for the holiday band. This is test-only and does not change application behavior. The isolated check and final full suite passed.

Final local checks: targeted tests 7 files/94 tests, full suite 54 files/443 tests, lint, typecheck, build, and git diff --check all passed. The build emitted the non-blocking large-client-chunk advisory. Final read-only privilege verification remains in db/verification/phase1-import-authorization-postflight.sql. No Production access, deployment, branch changes, or Phase 2 work occurred.


### Final import API provenance validation

A Worker API test now submits both source_external_id and sourceExternalId in an untrusted import request, then separately submits T999 against an inconsistent source row. Both requests are rejected with 400 before repository invocation, proving the API does not accept arbitrary extra provenance fields and validates imported IDs against source rows.

Final focused import/migration checks passed (3 files, 15 tests); the full suite passed (54 files, 444 tests); lint, typecheck, build, and git diff --check passed. Build reports the non-blocking 618.71 kB client chunk advisory. This test-only change did not alter the database; migration 0031 and rollback-only integration were not rerun.

## Phase 1.1 unified product change history

Current Development status: migration 0033 corrected the source-link constraint exposed by the 0032 rollback-only import test. The revised Worker import, clone, grouped audit, and calendar/reversal checks passed, and read-only schedule/R00 fingerprints remained unchanged. Subsequent manual acceptance exposed a dialog contract mismatch: the Worker publishes grouped detail `id` while the dialog expected the database's `eventId`. The dialog now uses the Worker contract. The history presentation hides structured identifiers, uses recorded names or neutral labels, gives grouped entity renames specific pt-BR titles, and renders retained working-plan metadata. Manual review confirmed loading and the main history views before the final detail, hierarchy, and footer cleanup; the final results are in docs/verification/phase1.1-unified-history-validation.md.

Decision D067 extends the existing read-only `/change-history` feed and dialog. The Worker still calls the same `list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)` function and keeps the existing page/cursor API. Its `jsonb` response adds nullable operation metadata, related source event types, and per-operation detail arrays. The Worker validates those optional fields and continues to enrich only returned-page actors; the route still derives the actor from the verified identity and does not accept actor claims.

Prepared migration `0032_unified_living_schedule_change_history.sql` dynamically replaces the existing function only after checking its signature, owner, existing 0027/0028 changes, stable cursor ordering, and unique replacement anchors. It retains the `SECURITY DEFINER` owner, fixed `pg_catalog, pg_temp` search path, membership/product-scope checks, and Worker execute-only boundary. The function selects at most `page size + 1` operation headers using a deterministic `(occurred_at, operation:<uuid>)` ordering and a matching expression index. It fetches all details for those selected operations before paging, so a group is never split. Legacy specialized-only events keep their original event IDs and keyset ordering; a bounded lookahead is used for those rows as well. A single unusually large operation can still have a large detail array because the contract never splits an operation.

Specialized history rows are attached to a generic operation only through an exact source-ledger event link. Generic date or movement fields are removed only when the source link, same entity identity, and one-to-one operation/entity counts make the match unambiguous and the specialized record carries those same fields. Other metadata from a combined mutation remains as a generic detail. Ambiguous matches are kept. No timestamp, actor, or text comparison is used. The UI presents one operation card, preserves each detail's source event ID and before/after values, filters groups by their represented specialized types, and keeps reversal references informational; it does not add reversal actions.

The migration adds deferred source links for new product-creation and import-batch provenance and backfills only stable, exact identities: the product row ID used by `product_created`, and the import batch's unique product scope for `schedule_imported`. The trigger function is executor-owned, fixed-search-path, unavailable to `PUBLIC` and the Worker, and runs only as a deferred row trigger after the product/import operation header has been written. Ambiguous historical labels remain recorded as IDs or the localized unavailable-name label; current names are not substituted.

Migration 0032 was applied to Development using the approved owner role. Its read-only postflight passed, but rollback-only Worker integration found that the deferred provenance trigger writes `products` and `import_batches` into `product_schedule_operation_source_events` while the existing check constraint permits only the seven specialized ledgers from migration 0030. This can abort product creation, import, and clone transactions. The synthetic transaction rolled back, leaving no test product or import. A separately authorized forward correction and rerun of the database checks are required before Phase 1.1 is accepted or committed. The exact checksum, target, recovery checkpoint, catalog results, test outcomes, and correction requirement are in `docs/verification/phase1.1-unified-history-validation.md`. D050 and the Phase 1 history-gap notes remain historical records; no missing pre-cutover event was synthesized. No Production access, deployment, R00 mutation, Gantt change, or Phase 2 work occurred.
