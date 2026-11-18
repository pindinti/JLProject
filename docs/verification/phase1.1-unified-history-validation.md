# Phase 1.1 Unified History Validation

## Status

Migration 0033 corrected the source-ledger constraint in Development. The migration 0032 failure below remains as historical evidence; the 0033 correction and verification results at the end of this record supersede its blocked status. Phase 1.1 is ready for authenticated user acceptance. No Production resource was accessed, no deployment occurred, and no Phase 2 work began.

Migration file: db/migrations/0032_unified_living_schedule_change_history.sql
SHA-256: 96FB133943AF62636830919ABF2BB4FF076F9FE0856AD6CB3755F71CDB3D2E67
Target: Neon project rapid-mud-63974868, branch development (br-delicate-glitter-b6mj0051), database neondb
Migration role: neondb_owner, with ON_ERROR_STOP=1
Execution result: the migration transaction returned COMMIT.
Execution timestamp: 2026-11-18 UTC; the exact clock time was not retained. The Neon CLI output did not include a timestamp, and PostgreSQL has track_commit_timestamp disabled.

## Preflight and recovery checkpoint

- Verified the Development project, branch, branch ID, database, and role before execution.
- Confirmed that no migration ledger exists in the repository or Development database. The checked-in migration history and live catalog were used instead.
- Verified that the 0029, 0030, and 0031 objects and privilege contracts were present and that no 0032 objects were partially applied.
- Reviewed the complete history function definition and the migration's replacement anchors. The migration changed only the approved feed CTE, event source, JSON fields, provenance links, and index while preserving the six-argument signature, jsonb return type, authorization predicates, executor owner, and fixed search path.
- Before migration, created Development checkpoint dev-pre-0032-20261118 (br-soft-darkness-b6sss8qb), with Development as its parent. It was ready and non-default; Neon showed no expiry. The project history-retention window was six hours. No branch was restored or reset.

## Migration and read-only postflight

The authorized Neon CLI command applied only migration 0032 to the Development branch as neondb_owner with ON_ERROR_STOP=1. The SQL completed its BEGIN/COMMIT transaction.

Read-only postflight passed:

- The existing list_product_change_history signature and jsonb contract remain.
- The function is owned by jlproject_date_executor, is SECURITY DEFINER with search_path=pg_catalog, pg_temp, is executable by jlproject_worker, and is not executable by PUBLIC.
- The provenance helper has the same executor owner and fixed search path; the Worker and PUBLIC cannot execute it.
- Both deferred provenance triggers and the history ordering index exist.
- The executor's schema CREATE privilege and neondb_owner membership in the executor role are revoked.
- The Worker has no direct SELECT on generic operation, detail, or source-link tables.
- The installed function definition exactly matched the complete reviewed replacement.

The Development state summary after migration and failed synthetic tests matched the pre-migration checkpoint summary. It contained 5 products, 29 disciplines, 74 stages, 143 activities, 16 targets, and 4 R00 snapshots. The R00 fingerprint remained 561afb1d7965f7b9e9bc57b8d70313c2. The final owner check found zero synthetic products and zero synthetic import batches.

## Worker integration results

The read-only legacy-history pass succeeded for existing Development products. It exercised bounded cursor pagination, stable event ordering, legacy specialized event IDs and event types, actor attribution, stored deletion identity, reversal references, and confirmed that history reads do not advance schedule cursors. It found no missing required legacy event categories.

The rollback-only synthetic import pass exposed a blocking incompatibility before it could read the synthetic history. Migration 0032's deferred provenance function inserts source_ledger values products and import_batches into product_schedule_operation_source_events. The live check constraint product_schedule_operation_source_events_source_ledger_check, created in migration 0030, allows only:

- activity_date_changes
- stage_date_changes
- business_target_date_changes
- calendar_reschedule_changes
- calendar_reschedule_reversals
- hierarchy_movement_events
- schedule_deletion_events

When SET CONSTRAINTS ALL IMMEDIATE fired the new deferred trigger, PostgreSQL rejected the products source link with a check-constraint violation. The connection ended with ON_ERROR_STOP=1, so the transaction rolled back. A follow-up read-only query confirmed zero synthetic products and imports. The earlier test-fixture attempt also used 32-character MD5 strings where the import contract requires 64-character hashes; that fixture was corrected before the constraint failure was reproduced.

Until the constraint accepts products and import_batches, product-creation and import transactions that queue the 0032 deferred trigger can fail at commit. Clone transactions that insert a product may be affected as well. Do not rely on product creation, import, or cloning in Development until a separately authorized forward correction is applied and verified.

The minimal correction is a new forward migration that replaces the source_ledger check constraint with the existing seven values plus products and import_batches. Do not edit or rerun already-applied migration 0032. No correction migration was prepared or applied in this validation. Separate authorization is required before applying any additional migration.

## Local automated checks

- Focused migration, repository, Worker, and dialog tests: passed, 4 files and 85 tests.
- Full automated test suite: passed, 55 files and 454 tests.
- Lint: passed after removing four temporary local preview files.
- Typecheck: passed.
- Build: passed. Vite reported the existing client chunk-size advisory for the 626.68 kB minified main client bundle.
- git diff --check: passed. Git emitted CRLF/LF normalization notices for two Markdown files; there were no whitespace errors.

These local tests do not override the failed database integration. Product/import provenance behavior, complete synthetic grouped-history behavior, post-correction write-path verification, and authenticated browser acceptance remain unverified.

## Remaining acceptance checks

After separate authorization and a reviewed forward correction:

1. Re-run read-only preflight and postflight against the same Development target.
2. Re-run rollback-only Worker tests for product creation, import, and cloning; verify provenance links, source-specific details, actor and operation identity, and complete-group pagination.
3. Verify workspace denial, Worker execute-only access, no history-read cursor movement, and no persistent synthetic rows.
4. Compare schedule and R00 fingerprints with the saved Development checkpoint.
5. Re-run relevant database, repository, Worker, full-suite, lint, typecheck, build, and diff checks.
6. Perform authenticated browser acceptance of the product-history dialog and pagination. No authenticated visual acceptance is claimed here.

No commit was created because the live database acceptance check failed. The unrelated untracked production-baseline SQL file remains untouched.

## Migration 0033 correction and Development verification

The root cause was the migration 0030 check constraint allowing seven specialized ledgers while migration 0032's deferred provenance function emitted products and import_batches. These are stable source row identities scoped by workspace, product, and operation. A product row is mutable, so its link is a provenance reference rather than an immutable copy of product fields. The source-link record itself remains append-only. The history resolver joins the exact row ID and scope; one-to-one operation/entity counts continue to guard date and hierarchy deduplication.

Migration: db/migrations/0033_product_import_provenance_compatibility.sql
SHA-256: 9A313419A67E66023FB3BC6B884A2CF518D1EEAF9C8FC7E6DB3B330E8BC6D175
Target: rapid-mud-63974868 / development / br-delicate-glitter-b6mj0051 / neondb
Execution: neondb_owner, ON_ERROR_STOP=1, successful COMMIT on 2026-11-18 UTC. The CLI did not provide a precise execution timestamp.

Preflight reconfirmed the 0032 function definition, deferred triggers, executor ownership, original seven-value check, absent 0033 change, and Worker denial of direct source-link writes. Checkpoint dev-pre-0032-20261118 (br-soft-darkness-b6sss8qb) was ready with Development as parent. The Neon history-retention window was six hours. No restore or reset was performed.

The 0033 transaction changed only the source_ledger check on the executor-owned source-link table. It preserved the seven values and added products and import_batches. Temporary neondb_owner membership in the executor role was revoked before COMMIT. Read-only catalog inspection confirmed the nine values, table owner, append-only triggers, fixed security-definer functions, denied Worker SELECT/INSERT, revoked executor schema CREATE, and revoked owner role membership.

Rollback-only Worker integration passed:

- The previously failing synthetic import completed, fired deferred provenance triggers, and returned one complete logical history group containing product creation, import, and generic discipline/stage details.
- The product creation, clone, and import block passed, including explicit stage dates in cloned working data and its new R00, unchanged existing R00 snapshots, and one operation/version per synthetic product.
- The audit block passed stage, activity, target, movement, deletion, atomic rollback, workspace, exact stage-event identity, actor/reason, grouped history, and exactly-once version assertions.
- The calendar block passed reschedule and reversal audit links, exactly-once version assertions, and history access.
- Existing legacy specialized history, stable cursor pagination, deletion context, reversal references, and no history-read cursor advance passed the read-only Worker check.

The original 0030 script stopped at an obsolete assertion expecting three stage-date events as separate top-level history rows. Its adapted Phase 1.1 audit block checks the same three exact source-event IDs inside one operation group and passed. All synthetic transactions rolled back. The read-only integrity summary matched the pre-migration values: 5 products, 29 disciplines, 74 stages, 143 activities, 16 targets, 4 R00 snapshots, zero generic operation headers/details/source links, and unchanged schedule/R00 fingerprints. No synthetic products remained.

The new migration-0033 contract test compares every provenance source emitted by migration 0032 with the allowed check values, preserves all prior sources, and requires history resolution for both added identities. Focused correction tests passed (1 file, 2 tests). Full suite passed (56 files, 456 tests); lint, typecheck, and build passed. Build retained the 626.68 kB client chunk advisory.

Database tests cannot retain two different operation IDs for one product inside a single rollback-only transaction because of the existing unique transaction constraint. Same-timestamp group ordering and multi-page boundaries are covered by repository and dialog contract tests; live rollback integration verified complete grouping and legacy cursor continuation. Invalid source types are rejected by the nine-value check; Worker direct insertion is denied. No authenticated browser acceptance was performed. Manually open the product history dialog in Development, inspect grouped details and filters, follow a page cursor, and confirm pt-BR dates and reversal context before user acceptance.
