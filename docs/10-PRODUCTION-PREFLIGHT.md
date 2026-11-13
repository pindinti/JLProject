# Production Upgrade Runbook — Existing Environment

## Purpose and current status

This runbook covers an **incremental upgrade of the existing, populated JLProject Production environment**. It is not a fresh-install procedure. Preserve existing projects, schedules, users, identities, grants, and audit data. Do not create a replacement Production project or assume that migrations `0001`–`0027` are all pending.

The architecture team has confirmed that Production is live and contains real users and project data. No Production or Development database was accessed for this review. Therefore, the following environment facts are **UNKNOWN** until verified through approved read-only access and deployment records:

- Production database/project/branch identity and PostgreSQL version.
- The applied migration set and checksums; the repository does not define a migration-ledger table or migration runner.
- Actual schema, grants, row counts, deployed Worker/client versions, and backup/restore status.
- Development's current applied migration set. `docs/02-DATA-MODEL.md` says migration `0008` was not applied, while decision D035 says it was applied. Neither statement proves the current Development or Production state.

At repository revision `a12877d75476742934765d1e3dc9ea03cc9ef3b3`, the repository contains 27 numbered migration files (`0001`–`0027`). The current Production preflight previously listed only `0001`–`0009`; it must not be used to select Production migrations. Repository files and documented Development results are not evidence of the live Production schema.

### Status vocabulary

Track each migration as one of:

- **APPLIED_VERIFIED** — successful application is supported by an environment-specific deployment record with the exact file checksum, corroborated by compatible schema inspection.
- **PENDING_VERIFIED** — no successful application is recorded, and preconditions for this exact migration are satisfied on the reconciled schema.
- **UNKNOWN** — evidence is missing or insufficient. Do not apply or skip it.
- **CONFLICT** — records, checksum, preconditions, or live schema disagree. Stop for DBA review.

Object existence alone does not establish that a migration was applied. Never rerun an `UNKNOWN`, `CONFLICT`, or `APPLIED_VERIFIED` migration.

## 1. Read-only Production baseline

Obtain a change ticket and named database/release owners before baseline collection. Use a read-only database principal for inspection. Independently verify the Neon project and branch in the provider console; `current_database()` is not sufficient to identify a Neon branch. Do not place a connection string or secret in this runbook, shell history, ticket, or captured output.

For staged, timeout-bounded catalog, aggregate-count, and integrity queries with the operator sequence, use the [Production Read-Only Baseline Inspection Package](verification/production-baseline/README.md). The package is a preparation artifact only; its SQL has not been executed against Production or Development.

The following examples are read-only. Run them from an approved `psql` session after confirming the connection target. Keep outputs in the restricted change record and redact user-identifying values where counts suffice.

```sql
BEGIN TRANSACTION READ ONLY;

SELECT current_database() AS database_name,
       current_user AS connected_role,
       current_setting('server_version') AS postgres_version,
       current_schema() AS current_schema,
       current_setting('search_path') AS search_path;

-- Discover candidate ledgers without assuming one exists or assuming its columns.
SELECT n.nspname AS schema_name, c.relname AS relation_name, c.relkind
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm')
  AND c.relname ~* '(migration|schema.?version|flyway|liquibase|prisma|drizzle)'
ORDER BY n.nspname, c.relname;

-- Inventory relevant relations and owners. This is corroborating evidence, not migration history.
SELECT n.nspname AS schema_name, c.relname AS relation_name, c.relkind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public', 'neon_auth')
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
ORDER BY n.nspname, c.relname;

-- Review function identity, owner, SECURITY DEFINER status, and configured search_path.
SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef, p.proconfig
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY p.proname, arguments;

-- Check for unvalidated foreign-key/check constraints and disabled triggers.
SELECT conrelid::regclass AS relation_name, conname, contype, convalidated
FROM pg_constraint
WHERE contype IN ('f', 'c') AND NOT convalidated
ORDER BY relation_name, conname;

SELECT c.oid::regclass AS relation_name, t.tgname, t.tgenabled,
       pg_get_triggerdef(t.oid) AS trigger_definition
FROM pg_trigger AS t
JOIN pg_class AS c ON c.oid = t.tgrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname IN ('public', 'neon_auth')
ORDER BY relation_name, t.tgname;

SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit
FROM pg_roles
WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                  'jlproject_date_executor', 'jlproject_calendar_executor')
ORDER BY rolname;

ROLLBACK;
```

If a candidate migration ledger exists, inspect its definition first (`\d+ schema.relation` in `psql`), then query its actual columns. Reconcile every row to the exact repository migration checksum, Production project/branch, successful transaction result, timestamp, and operator. If no reliable ledger exists, use the reconciliation procedure below; do not invent a version number.

### Migration-state reconciliation when no reliable ledger exists

1. Collect signed/restricted change records, migration command logs, operator notes, release tickets, and provider/database audit evidence. Each record must identify the Production project/branch, migration filename, SHA-256 checksum, start/end result, and operator.
2. Compare recorded checksums with the repository files. A filename-only record is insufficient. To produce the repository-side manifest from the checked-out release, run locally:

   ```powershell
   Get-ChildItem db/migrations/*.sql | Sort-Object Name | Get-FileHash -Algorithm SHA256
   ```

3. Populate the 27-entry status ledger from those records. Use catalog inspection and migration preconditions as corroboration only; matching tables/functions/grants do not prove successful execution of a particular file.
4. Where records are absent, mark the migration **UNKNOWN**. Rehearse the candidate chain against an isolated representative restore and have the DBA compare the full schema/function/grant definitions with the reviewed migration state. Do not trial-run uncertain files on Production to learn their state.
5. If the evidence cannot distinguish “already applied” from “not applied,” stop. Resolve it with a DBA-approved reconciliation plan and separate change approval. Do not edit an already deployed migration or manually mark it applied without documented evidence.

### Existing application, Worker, and recovery baseline

Capture outside SQL, from the approved provider/control-plane records:

- Production Neon project and branch identifiers; database endpoint label; Auth project/branch and verified Auth endpoint. Never record credentials.
- Cloudflare Worker name/environment, deployed version/deployment IDs, timestamp, source commit/build provenance, routes, and current static asset release. If a deployment cannot be tied to a source commit, record the version as **UNKNOWN**.
- Current Worker secret/variable *names and presence* only; do not export values. Confirm the Production Worker uses the limited `jlproject_worker` database credential, not `neondb_owner` or a Neon management key.
- Current backup/PITR availability, latest successful backup time, retention window, restore owner, last successful restore-drill evidence, RPO/RTO, and the recovery destination. A backup status indicator is not proof of a successful restore.

## 2. Data and relationship baseline

Before taking the write window, record exact row counts for all present core and history tables, including workspaces, memberships, products, disciplines, stage instances, activities, targets, import batches/source rows, initial revisions, activity/target date histories, calendar versions/exceptions/events, reschedule/reversal histories, deletion events, and movement events. Do not treat an absent table as an empty table; compare its presence to the reconciled migration state.

For a `psql` session, this read-only generator emits `count(*)` queries only for listed relations that exist and emits `NOT PRESENT` for absent ones. First preserve the relation inventory above so absence is interpreted against the verified schema version:

```sql
WITH wanted(schema_name, relation_name) AS (
  VALUES ('public', 'workspaces'), ('public', 'workspace_memberships'),
         ('public', 'products'), ('public', 'product_disciplines'),
         ('public', 'stage_definitions'), ('public', 'discipline_stages'),
         ('public', 'stage_activities'), ('public', 'business_targets'),
         ('public', 'import_batches'), ('public', 'import_source_rows'),
         ('public', 'initial_schedule_revisions'),
         ('public', 'activity_date_changes'), ('public', 'business_target_date_changes'),
         ('public', 'workspace_calendar_versions'), ('public', 'workspace_calendar_exceptions'),
         ('public', 'workspace_calendar_events'), ('public', 'calendar_reschedule_changes'),
         ('public', 'calendar_reschedule_reversals'), ('public', 'schedule_deletion_events'),
         ('public', 'hierarchy_movement_events'), ('neon_auth', 'user')
), found AS (
  SELECT w.schema_name, w.relation_name, c.oid
  FROM wanted AS w
  LEFT JOIN pg_namespace AS n ON n.nspname = w.schema_name
  LEFT JOIN pg_class AS c ON c.relnamespace = n.oid
                         AND c.relname = w.relation_name
                         AND c.relkind IN ('r', 'p')
)
SELECT CASE WHEN oid IS NULL THEN
         format('SELECT %L AS relation, NULL::bigint AS row_count, %L AS status',
                schema_name || '.' || relation_name, 'NOT PRESENT')
       ELSE format('SELECT %L AS relation, count(*)::bigint AS row_count, %L AS status FROM %I.%I',
                   schema_name || '.' || relation_name, 'PRESENT', schema_name, relation_name)
       END
FROM found
ORDER BY schema_name, relation_name
\gexec
```

Record counts split by workspace and relevant state (active/archived/deleted, active/inactive membership and role, planning mode). Capture the before values and compare them after the change window. Counts must remain unchanged for existing data unless the rehearsal identifies and approves a documented, deterministic backfill. The reviewed migration source shows additions/defaults and constraint/function changes; it does not authorize removal or recalculation of existing schedule dates.

On the compatible schema, run and record these read-only integrity checks. A missing relation/column is a schema-state question, not a zero-result pass; stop and reconcile before interpreting it.

```sql
-- Existing workspaces without an active administrator.
SELECT w.id AS workspace_id
FROM public.workspaces AS w
LEFT JOIN public.workspace_memberships AS m
  ON m.workspace_id = w.id AND m.active = true AND m.role = 'admin'
GROUP BY w.id
HAVING count(m.auth_user_id) = 0;

-- Invalid activity civil-date pairs.
SELECT count(*) AS invalid_activity_date_pairs
FROM public.stage_activities
WHERE (planned_start IS NULL) <> (planned_end IS NULL)
   OR (planned_start IS NOT NULL AND planned_end IS NOT NULL AND planned_start > planned_end);

-- Missing product scope, mismatched root parent pair, or invalid stage ancestry.
SELECT count(*) AS invalid_activity_scope_or_parent
FROM public.stage_activities AS a
LEFT JOIN public.products AS p
  ON p.workspace_id = a.workspace_id AND p.id = a.product_id
LEFT JOIN public.discipline_stages AS s
  ON s.workspace_id = a.workspace_id AND s.product_id = a.product_id
 AND s.discipline_id = a.discipline_id AND s.id = a.stage_id
WHERE p.id IS NULL
   OR ((a.discipline_id IS NULL) <> (a.stage_id IS NULL))
   OR (a.stage_id IS NOT NULL AND s.id IS NULL);
```

Also record per-product counts and stable fingerprints for activity IDs, parent IDs, `display_order`, date/planning fields, target IDs/dates, each R00 snapshot, and all audit/movement ledgers. Use checksums in the restricted change record rather than exporting business rows. Confirm no unexpected disabled audit/deletion/movement triggers, invalid constraints, role-membership changes, or new Worker table/column grants. The rehearsal must establish the exact expected privilege set for `jlproject_worker` and both executor roles.

## 3. Migration compatibility and risk matrix

All 27 repository migration files were inspected statically. Each currently has an explicit `BEGIN`/`COMMIT`; this makes each file a transaction boundary, **not** the whole migration chain. No `TRUNCATE`, table/column drop, or top-level data-deletion statement was found. There are constraint/index drops and recreations, column defaults, role/grant changes, and `ALTER TABLE` operations that can acquire blocking locks. Function bodies also perform writes when later called by the application; they are not migration-time backfills. Execution, lock duration, and behavior against Production data remain unverified.

Apply only migrations with status `PENDING_VERIFIED`, in numeric order after all predecessor migrations are `APPLIED_VERIFIED`. The dependencies below are additional material prerequisites; all files are ordered and often assert a precise prior schema/role state.

| Migration | Dependency / required context | Change and incremental-upgrade risk |
|---|---|---|
| `0001_workspace_authorization.sql` | Neon Auth `neon_auth.user`; database owner | Creates workspace/membership tables and indexes. Initial schema; not safe to replay over existing objects. |
| `0002_membership_administration.sql` | `0001` | Adds serialized membership-update function; no intended row backfill. |
| `0003_products.sql` | `0001` | Adds product table/indexes. Existing names/constraints must match expected state. |
| `0004_schedule_hierarchy.sql` | `0003` | Alters products and creates discipline/stage/activity hierarchy and scoped FKs/triggers. Validate existing ancestry before FK validation. |
| `0005_initial_import.sql` | `0004` | Adds targets, import provenance, immutable R00, and import function. Function writes only when invoked; migration does not import a workbook. |
| `0006_activity_date_audit.sql` | `0004`, Auth tables, `neondb_owner` | Creates date executor, date-change ledger, guards, and controlled date operation. Role ownership/`SET ROLE` requirements are strict. |
| `0007_worker_least_privilege.sql` | `0006`; pre-provisioned limited `jlproject_worker` login | Establishes Worker grants and executor function access. Grants direct membership `UPDATE(role, active)`; `0009` later grants membership INSERT. Changes the authorization boundary; verify effective grants and explicitly review whether the direct writes are accepted. |
| `0008_target_management.sql` | `0005`–`0007` | Alters existing target nullability/checks, adds description/color/deletion/version defaults and date history, drops/recreates checks and a unique index. Validate exact existing target constraints and active-name uniqueness before running. |
| `0009_user_onboarding.sql` | `0001`, `0007` | Adds membership-add function and Worker INSERT privilege. Verify role grants and application compatibility. |
| `0010_shared_stage_definition_color.sql` | `0004`, `0007` | Grant-only: allows Worker update of shared stage color. No schema/data backfill. |
| `0011_product_cloning.sql` | `0005`, `0007` | Makes R00 `import_batch_id` nullable and adds clone function. Replaces schema behavior; preserve existing R00 and provenance. |
| `0012_product_clone_locking.sql` | `0011` | Replaces clone function to remove an owner-role table lock that failed under the limited Worker. Apply the exact approved replacement once. |
| `0013_working_calendar.sql` | Workspaces/memberships, `0007`; role `neondb_owner` | Creates calendar executor, exception/version/event tables and mutation function. New tables; locks workspace and membership rows when called. |
| `0014_working_day_planning.sql` | `0013`, activity/date executor schema | Adds planning columns with existing activities defaulted to `manual`, and narrows activity INSERT grants. Table alteration/validation can lock or scan existing activities. |
| `0015_date_executor_calendar_read.sql` | `0013`–`0014`, both executor roles | Grant-only read access for date executor; verifies temporary role membership is removed. |
| `0016_date_executor_stage_scope_read.sql` | `0004`, `0013`–`0015` | Grant-only scoped stage read. Verify narrow column privileges and executor membership state. |
| `0017_calendar_reschedule.sql` | `0013`–`0016` | Adds immutable reschedule batch history and controlled apply function. No automatic date rewrite during migration; operation writes occur only when called. |
| `0018_calendar_reschedule_reversal.sql` | `0017` | Adds immutable reversal history and compensating reversal function. Existing reschedule history must remain intact. |
| `0019_calendar_reschedule_history.sql` | `0017`–`0018` | Adds scoped history reader/grants. No intended data rewrite; verify owner/search path/EXECUTE grants. |
| `0020_schedule_logical_deletion.sql` | Hierarchy, R00, executor privileges | Adds nullable deletion fields/event table and controlled soft-delete/clone functions. Does not physically delete existing rows; check existing triggers and role boundaries. |
| `0021_schedule_deletion_trigger_scope.sql` | `0020` | Corrects deletion guard function. Required corrective migration after `0020`; preserve trigger attachment/enabled state. |
| `0022_product_change_history.sql` | Import, date/target/reschedule/deletion histories and executor | Adds a scoped read-only history function/grants. It is not a complete metadata audit backfill. |
| `0023_activity_color_overrides.sql` | Activity hierarchy and current clone function (`0020`+); Worker grants | Adds nullable color override and replaces clone function. Existing activities inherit color via NULL; verify clone/R00 behavior. |
| `0024_activity_color_insert_permission.sql` | `0023` | Grant-only narrow `INSERT(color_override)`; fails closed if table-wide or date grants differ. |
| `0025_root_activities.sql` | `0004`, `0006`, `0013`–`0024`; `neondb_owner`, `jlproject_worker`, executor roles, exact functions/constraints; `current_database()` must be `neondb` | Allows both activity parents to be NULL, adds product-scope constraints/indexes, and replaces planning, history, clone, deletion, and reschedule functions. Existing mixed parent pairs or cross-product ancestry can fail constraint validation. Database name is a precondition, not proof of Production identity. |
| `0026_hierarchy_movement.sql` | `0025`; exact executor membership, guards, FKs and Worker grants; `current_database()` must be `neondb` | Drops/recreates activity-parent FK as deferrable, replaces historical date-parent FK with direct product/activity scope, adds movement ledger/function, and revokes direct Worker `display_order` updates. Significant lock/constraint validation and old-Worker compatibility risk. Database name is a precondition, not proof of Production identity. |
| `0027_product_change_history_hierarchy_movement.sql` | `0022`, `0026`; exact history function definition/owner/grants; `current_database()` must be `neondb` | Rewrites the history function using a checked source anchor to include movements. Fails closed if its expected function definition differs; do not bypass the precondition. Database name is a precondition, not proof of Production identity. |

Before release, rehearse lock duration using representative data. `ALTER TABLE`, constraint validation, index replacement/creation, role changes, and function/trigger replacement may block application sessions. No `CREATE INDEX CONCURRENTLY` operation was found. The chain is not one atomic transaction: a failure rolls back the current file only; earlier committed files remain applied.

## 4. Rehearsal on an isolated representative database

The release rehearsal is mandatory and must not use Production or Development as the test target.

1. After separate approval, restore a consistent, access-restricted Production snapshot to a disposable isolated database/branch. Preserve schema, IDs, memberships, dates, R00, calendars, targets, and histories for compatibility checks. Mask personal data without changing keys/FKs where feasible; disable outbound email, provider-management calls, and Production credentials. If a representative restore cannot be created safely, stop and document the limitation.
2. Record the baseline queries, exact migration status ledger, repository SHA-256 manifest, current Worker version, exact counts/fingerprints, role attributes/grants, constraints, functions, and triggers.
3. Reconcile each migration individually. Select only `PENDING_VERIFIED` files; skip only `APPLIED_VERIFIED`; stop on `UNKNOWN`, `CONFLICT`, checksum mismatch, unexpected precondition, or schema drift. Do not apply the whole directory blindly.
4. Rehearse the same owner/role setup and permissions planned for Production. Use a protected `psql` service definition/passfile, not a credential in the command line. Apply one selected file per invocation and record its checksum/result:

   ```text
   psql "service=jlproject-production-migration-rehearsal" -v ON_ERROR_STOP=1 -f db/migrations/<verified-pending-file>.sql
   ```

   Use the real migration filename in the controlled rehearsal. Inspect the exit status and resulting schema before selecting the next file. Never continue after an error or manually mark a failed file applied.
5. Exercise the release Worker against the rehearsed schema with synthetic data: existing-project reads, role-denial and cross-workspace paths, date edit/audit, calendar apply/reversal, clone/R00, target preservation, import rollback/idempotency, movement/audit, and product history. Check both current and prior Worker behavior. Because `0026` revokes direct ordering updates, do not assume the prior Worker remains write-compatible.
6. Compare all before/after counts and fingerprints. Confirm existing dates, revisions, memberships/roles, target dates, calendar state, and audit histories are unchanged; inspect newly added defaults explicitly. Confirm all constraints are validated, required triggers enabled, expected functions/owners/search paths present, and Worker/executor grants match the approved matrix.
7. Measure locks and elapsed time under representative load. Test abort behavior at each migration boundary. Confirm a tested restore can recover the pre-upgrade schema and all baseline data. Store rehearsal outputs and approval in the change record; do not copy sensitive rows or credentials into repository documentation.

Rehearsal success does not establish the Production migration state. It establishes only that the reconciled candidate sequence works on the representative restore.

## 5. Incremental Production deployment procedure

Production execution requires a separate approved change window and named DBA/release owner. Keep architecture users informed and block conflicting application writes for the complete schema/Worker transition.

### Before the window

- Complete read-only baseline and migration-state reconciliation. Require no `UNKNOWN` or `CONFLICT` entries in the selected dependency chain.
- Complete the representative rehearsal against the exact migration checksums and Worker build intended for release.
- Confirm tested backup/restore, RPO/RTO, recovery owner, prior Worker deployment artifact, and a rollback/recovery decision tree.
- Prepare production-configured Worker/client artifacts; confirm the verified Production Auth endpoint, `JLPROJECT_ENV=production`, Worker routes, limited database role, secret names, and artifact scan. Never deploy Development Auth URLs, `DATABASE_URL` to browser assets, a migration-owner credential, or `NEON_MANAGEMENT_API_KEY`.
- Confirm D023 JWT replay-risk review, required administrator MFA, audit-scope acceptance, and user-visible maintenance notice.

### Execute

1. Confirm two independent Production identity signals (provider project/branch plus approved endpoint record and read-only SQL identity output). If they disagree, stop.
2. Enter maintenance mode or otherwise quiesce Worker writes and background operations. Confirm no active release, import, schedule edit, onboarding, or membership change can race with the migration window. Take and verify the final pre-change backup/snapshot and baseline counts/fingerprints.
3. Reconfirm the migration status ledger, source SHA-256 checksums, prerequisites, and selected files with a second reviewer. Run only `PENDING_VERIFIED` migrations, in numeric order, one file at a time with `ON_ERROR_STOP=1`. Do not run a file already marked applied and do not skip a predecessor.
4. After each file commits, record filename, checksum, environment identity, start/end time, operator, exit status, and postcondition checks in the change record. If any file fails, times out, or returns ambiguous status: stop immediately, keep writes quiesced, preserve logs, and assess from backup/reconciliation. Never blindly retry.
5. After all selected files pass, run the post-migration catalog, role, data-count, date, ancestry, constraint, trigger, and audit checks from sections 1–2. Any unexpected difference is a stop condition.
6. Deploy the matching Worker/client version while the maintenance gate remains active. Run smoke tests with existing users and existing projects plus a clearly identified synthetic test workspace/product: authentication, role permissions, cross-workspace denial, existing schedule/date/calendar/history reads, authorized write/audit, and no unintended changes to existing data. Confirm deployed release IDs and source commit.
7. Resume traffic only after smoke checks pass and counts/fingerprints remain consistent. Monitor errors, authentication, database latency/locks, and audit writes; retain the maintenance/restore decision until the observation window closes.

### Failure, rollback, and recovery

- Every repository migration is individually wrapped in `BEGIN`/`COMMIT`, but the 27-file chain is not atomic. Earlier files may be committed when a later file fails. Stop; do not rerun uncertain files.
- The repository provides no general down-migration sequence. Do not reverse constraints, grants, functions, or tables manually and do not edit an already-applied migration.
- Prefer a separately reviewed forward corrective migration only after the failure is understood, rehearsed, and approved.
- If schema/data compatibility cannot be established, keep writes disabled and restore the verified pre-change backup to a recovery environment. Point the Worker only to a schema compatible with that Worker version. A restore may lose writes after the backup; the maintenance window and write freeze must bound that loss.
- Roll back the Worker version only if rehearsal proved it compatible with the post-migration schema. In particular, verify ordering/membership/function grants before using an old Worker. If compatibility is unknown, keep the service paused and choose a rehearsed forward repair or full coordinated database/Worker recovery.
- Record incident decisions and compare restored counts/fingerprints before resuming. Do not ingest confidential schedules until recovery and audit controls are verified.

## 6. Data-preservation and recovery checklist

The change record must demonstrate preservation of:

- Workspaces, products, disciplines, stage definitions/instances, activities, parent relationships, order, archive/deletion state, and stable IDs.
- Existing planned dates, planning mode/duration/calendar version, Gantt colors, targets/milestones, and all existing R00 snapshots/revision data.
- Workspace calendar versions, exceptions, events, reschedule batches, reversals, activity/target date histories, deletion events, movement events, and product history sources.
- Neon Auth identities, workspace memberships, active state, role values, and workspace ownership. No migration is authorization to invite users, change roles, disable users, or alter Auth settings.
- Worker/executor role attributes, object owners, grants, SECURITY DEFINER status/search paths, and required triggers.

Compare exact before/after row counts by table and workspace; memberships by role/active state; products by active/archive state; activities by parent and planning mode; date distributions/min/max; targets by active state and dates; R00 counts/fingerprints; and each audit/event ledger. Verify foreign keys/check constraints are validated and no activity has partial dates, mismatched root parents, or an out-of-scope product/stage relationship. Investigate every difference; do not normalize or repair data during deployment without a separate approved change.

Before Go, confirm:

- A recent backup exists, restore has been tested in a separate environment, and the restore owner knows how to recover the Production branch.
- The restore point predates the first migration selected for this release; the write freeze remains until Go/No-Go.
- Recovery time and possible write loss are understood and approved; backup status alone is insufficient.
- Post-restore application version, secrets, Auth origin, Worker routing, roles, integrity checks, and synthetic smoke checks are rehearsed.

## 7. Outstanding unknowns and approval gates

The following are **UNKNOWN/PENDING**, not inferred from repository files:

- Production migration state/checksums, actual schema objects, grants, row counts, and current Worker/client versions.
- Whether a Production migration ledger exists and whether its records are complete.
- Development's applied migration state, including the documented `0008` conflict.
- Production backup retention/PITR and a successful restore result.
- Production Auth settings, verified endpoint, admin MFA status, and owner acceptance/mitigation of the 15-minute JWT replay window.
- Whether all current Worker routes remain compatible through the selected schema/Worker transition.

Required approvals: release owner and DBA for the selected migration manifest and change window; security owner for Auth/JWT/MFA and Worker privileges; data owner for audit coverage and preserved-data evidence; recovery owner for backup/restore and RPO/RTO. Production migration execution, credential changes, Auth changes, and deployment each require their own authorization.

## 8. Repository evidence and reconciliation notes

- The repository has `db/migrations/0001` through `0027`; no migration-ledger schema or runner is defined in repository SQL/docs. This does **not** prove Production has no ledger.
- All 27 checked-in migration files are transaction-wrapped. This does **not** prove they were applied, that a full chain succeeds against current Production data, or that the whole chain is atomic.
- `docs/10-PRODUCTION-PREFLIGHT.md` previously listed only `0001`–`0009`; this runbook replaces that fresh-install path with an incremental existing-environment procedure.
- `docs/02-DATA-MODEL.md` and decision D035 disagree about Development migration `0008`. This document marks Development state **UNKNOWN** pending approved evidence; it does not choose one account as fact.
- Decision/architecture notes document successful Development checks through later phases, including migrations `0026` and `0027`. Those historical claims are not Production evidence and do not establish the current Development migration ledger.
- The repository source review found migrations `0020`/`0021` include a corrective deletion-trigger sequence, `0011`/`0012` a corrective clone-function sequence, and later migrations assert exact role/schema/function prerequisites. Keep these files in numeric order and stop when a precondition differs.

## Go / No-Go rule

**Go** only when the migration manifest is reconciled with exact checksums, the representative restore rehearsal succeeds, the approved privileges and post-migration data checks pass, the Production-configured Worker/client pair is verified, the backup restore and security approvals are complete, and the release owner signs the change record.

**No-Go** if any selected migration is `UNKNOWN`/`CONFLICT`, a checksum or precondition differs, the representative rehearsal fails, an existing-data count/fingerprint changes unexpectedly, a privilege/identity boundary is unexplained, the production Auth build is unverified, or restoration is untested. Keep Production unchanged and writes available under the current release until a separately approved maintenance window is ready.
