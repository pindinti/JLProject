# Production Read-Only Baseline Inspection Package

## Status and scope

This package prepares evidence collection only. It has **not** been run against Production or Development. The Production project/branch, applied migration set, current schema, deployed releases, and recovery capability remain **UNKNOWN**.

The package is for an existing populated Production environment. It does not authorize a database connection, migration, deployment, data mutation, or privilege change. It supplements [the existing-environment upgrade runbook](../../10-PRODUCTION-PREFLIGHT.md); read that runbook before collecting evidence.

Files:

- `catalog.sql` — short-timeout database identity, catalog, role/grant, and migration `0025`–`0027` precondition inspection.
- `aggregate-estimates.sql` — fast, approximate row-count estimates from PostgreSQL statistics.
- `aggregate-exact.sql` — opt-in exact aggregate counts, one relation at a time in a read-only snapshot.
- `integrity.sql` — bounded-time aggregate checks for common orphan/invalid-state conditions; assumes the schema shape through migration 0027.

## Safety contract

1. Obtain separate approval and use an already-provisioned **read-only inspection role**. Do not use `neondb_owner`, `jlproject_worker` (it has application write privileges), or an executor role. Do not create or broaden a role to run this package.
2. Verify the Neon Production project and branch in the provider console before connecting. SQL database name and server version do not identify a Neon branch.
3. Keep credentials in the approved credential manager/service file. Never paste connection strings or secret values into commands, tickets, logs, or captured output.
4. Use `psql -X -v ON_ERROR_STOP=1` and the approved service name, for example:

   ```text
   psql "service=jlproject-production-readonly" -X -v ON_ERROR_STOP=1 -f docs/verification/production-baseline/catalog.sql
   ```

   The service definition must use the approved read-only principal and TLS verification. This command is an operator instruction, not an action taken in this review.
5. Run `catalog.sql` first. Review relation estimates before exact counts or integrity checks. Run exact scans only if approved for the current load window; each query has a timeout. A timeout, permission error, missing relation, or incomplete result means **UNKNOWN**, never zero.
6. The SQL scripts open read-only transactions, set local timeouts, and roll back. Catalog reads are low-cost. Exact `COUNT(*)` and integrity scans read table data and can consume I/O even though they cannot write. Exact counts have a five-second per-statement timeout; a timeout aborts the transaction and makes subsequent counts UNKNOWN. Do not remove timeouts or repeatedly retry a slow query in Production.
7. Capture only query output needed for the release record. The scripts return counts, flags, object definitions, role names/grants, and function metadata; they do not select names, emails, schedule rows, tokens, or credentials.

## Ordered operator procedure

1. **Authorize and identify.** Record the change ticket, operator, DBA/release owner, read-only role, and planned collection window. In the provider console, independently record the Production project ID, branch ID, database endpoint label, Auth project/branch, Cloudflare account/environment, and current release identifiers. Never include credential values.
2. **Run catalog inspection.** Execute `catalog.sql`. Confirm that `current_database()` and `current_user` are expected, then compare project/branch identity to the provider record. If they disagree or cannot be independently established, stop.
3. **Reconcile migration history.** Search the returned catalog for a migration tracking relation. If one exists, inspect its actual definition before querying rows. Collect authoritative deployment records, migration checksums, branch identity, success/commit result, timestamp, and operator. Repository object existence alone is not migration history.
4. **Record schema corroboration.** Use the table/column/constraint/function/trigger/grant inventory and the `0025`–`0027` facts. Mark compatibility only; do not mark a migration applied solely because its expected objects exist.
5. **Collect row-count evidence.** Review `aggregate-estimates.sql` first. If exact counts are needed and the DBA approves the I/O cost, run `aggregate-exact.sql` with `psql`; its `\gexec` emits one count query per present base table and reports absent relations or unexpected relation kinds. Exact counts are aggregate-only and have a per-query timeout.
6. **Run integrity indicators.** Run `integrity.sql` only after confirming every referenced table and column exists and the schema is compatible with the 0027 shape. A zero violating-row count is evidence for that check only; validated constraints and independent data checks still matter. A timeout or unavailable privilege leaves that check UNKNOWN.
7. **Collect non-database evidence.** Record deployed frontend and Worker revisions, Auth configuration status, and backup/restore evidence from the relevant provider/release/operations records. These facts cannot be established by PostgreSQL queries.
8. **Complete the matrix below.** Record authoritative migration-history evidence separately from schema corroboration. Keep unsupported rows UNKNOWN. Stop on an unexplained conflict or mismatch; do not proceed to migration execution from this package.

## Expected result structure and interpretation

- **Database identity:** database name, authenticated role, PostgreSQL version, current schema, and search path. Confirm the project/branch separately through the provider console.
- **Catalog:** schemas, relations, columns, owners, indexes, constraints and validation state, functions and security metadata, triggers and enabled state, role attributes, role membership, and visible grants.
- **Migration tracking:** zero or more candidate tracking relations. A matching table or function is schema evidence, not proof of when or from which migration file it was created.
- **Statistics:** estimated live/dead row counts and analyze timestamps. These are approximate, may be stale, and must not be reported as exact counts.
- **Exact aggregates:** one table total per known relation; no individual identity or project records. `business_targets` is the milestone/target count. `workspace_calendar_versions` counts explicit version rows; workspaces without a row use implicit calendar version 0, so interpret it alongside the workspace total. Calendar exceptions and events are counted separately.
- **Integrity:** one violating-row count per tested orphan/invalid-state condition. Zero means no match was found within that query's timeout; a nonzero count requires investigation. A timeout/error is not a pass.
- **Release compatibility:** exact Worker deployment/version ID, source commit/build provenance, frontend release/asset manifest, environment/routes, and Auth configuration status from provider evidence.
- **Recovery:** latest backup/PITR record, retention, restore destination, successful restore-drill record, RPO/RTO, and owner. PostgreSQL catalog inspection cannot prove restore capability.

The exact-count script supplies table totals only. If state breakdowns are required, have the DBA approve and run narrowly scoped `GROUP BY` aggregates against the inspected columns; retain counts only, never identities or project labels. Do not infer application/schema compatibility from a successful database connection: compare the recorded frontend/Worker source commit and build artifact against the repository API calls, SQL function signatures, and required columns.

When migration `0025` is a verified candidate and `catalog.sql` confirms the table and both parent columns exist, run this bounded aggregate precondition check. A zero count means no activity has only one of its two parents; both NULL is permitted for root activities after `0025`.

```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';
SELECT count(*) AS activities_with_mixed_parent_pair
FROM public.stage_activities
WHERE (discipline_id IS NULL) <> (stage_id IS NULL);
ROLLBACK;
```

For counts intended to serve as one preservation baseline, schedule an approved interval without application writes. `aggregate-exact.sql` uses one repeatable-read snapshot; `integrity.sql` runs each bounded check in its own read-only transaction. If writes cannot be paused, record each script's start/end time and treat cross-query comparisons as time-distributed evidence, not a single instant.

## Repository facts and environment unknowns

- Repository fact: the numbered migration chain contains `0001` through `0027`; this package inspected files in the repository but has not executed them.
- Repository fact: the repository does not establish Production or Development migration history. Migration ledger presence, contents, checksums, and deployment outcomes must be evidenced separately.
- Documentation conflict: [`docs/02-DATA-MODEL.md`](../../02-DATA-MODEL.md) says migration `0008` was not applied; [`docs/08-TESTS-AND-DECISIONS.md`](../../08-TESTS-AND-DECISIONS.md) decision D035 says it was applied. The Development state is therefore UNKNOWN until reconciled against environment-specific records; Production remains UNKNOWN independently.
- Environment facts UNKNOWN: actual Production project/branch, schema, migration outcomes, data state, frontend/Worker versions, Auth settings, and recovery capability. The queries in this package have not been executed.

## Migration-state reconciliation matrix

Initial status for every Production migration is **UNKNOWN — no Production evidence collected**. Fill only after this procedure; do not pre-populate status from Development notes or inferred object presence.

| Migration | History status | Authoritative evidence (record/checksum/environment/result) | Schema corroboration | Reconciled by / date |
|---|---|---|---|---|
| 0001 | UNKNOWN | Not collected | Not inspected | — |
| 0002 | UNKNOWN | Not collected | Not inspected | — |
| 0003 | UNKNOWN | Not collected | Not inspected | — |
| 0004 | UNKNOWN | Not collected | Not inspected | — |
| 0005 | UNKNOWN | Not collected | Not inspected | — |
| 0006 | UNKNOWN | Not collected | Not inspected | — |
| 0007 | UNKNOWN | Not collected | Not inspected | — |
| 0008 | UNKNOWN | Not collected | Not inspected | — |
| 0009 | UNKNOWN | Not collected | Not inspected | — |
| 0010 | UNKNOWN | Not collected | Not inspected | — |
| 0011 | UNKNOWN | Not collected | Not inspected | — |
| 0012 | UNKNOWN | Not collected | Not inspected | — |
| 0013 | UNKNOWN | Not collected | Not inspected | — |
| 0014 | UNKNOWN | Not collected | Not inspected | — |
| 0015 | UNKNOWN | Not collected | Not inspected | — |
| 0016 | UNKNOWN | Not collected | Not inspected | — |
| 0017 | UNKNOWN | Not collected | Not inspected | — |
| 0018 | UNKNOWN | Not collected | Not inspected | — |
| 0019 | UNKNOWN | Not collected | Not inspected | — |
| 0020 | UNKNOWN | Not collected | Not inspected | — |
| 0021 | UNKNOWN | Not collected | Not inspected | — |
| 0022 | UNKNOWN | Not collected | Not inspected | — |
| 0023 | UNKNOWN | Not collected | Not inspected | — |
| 0024 | UNKNOWN | Not collected | Not inspected | — |
| 0025 | UNKNOWN | Not collected | Not inspected | — |
| 0026 | UNKNOWN | Not collected | Not inspected | — |
| 0027 | UNKNOWN | Not collected | Not inspected | — |

**Authoritative history** requires an environment-specific record of successful application and the exact migration checksum, corroborated by the database state. If the record is absent or conflicts with the schema, leave the row UNKNOWN/CONFLICT and use the DBA reconciliation process in `docs/10-PRODUCTION-PREFLIGHT.md`. Do not infer `APPLIED_VERIFIED` from a table, column, function, or grant alone.

## Stop conditions

Stop collection and escalate to the named DBA/release owner if:

- Project/branch identity is missing, ambiguous, or disagrees with the SQL identity.
- The current role is not the approved read-only inspection role, the read-only transaction cannot be established, or a query attempts any write.
- A statement times out, errors, returns incomplete data, or requires broader grants.
- Migration records/checksums disagree with catalog state, or any candidate status remains UNKNOWN/CONFLICT for a proposed release chain.
- A required table/column/function/trigger is absent or has an unexpected owner, security mode, search path, constraint state, or grant.
- The server version does not support the migration `0025`–`0027` role membership options, or role-membership option fields are unavailable for the expected compatibility check.
- An integrity count is nonzero for an orphan, invalid date/parent, or workspace without an active administrator.
- An expected base table has an unexpected relation kind in the exact-count output.
- Exact count scans exceed their timeout or the DBA considers the load impact unsafe.
- Deployment revision, Auth configuration, or backup/restore evidence cannot be tied to an authoritative provider record.

## Evidence requiring separate operational access

These are not obtainable from the database scripts and require separately approved, read-only provider or release records:

- Neon Production project/branch identity; Auth enabled/verification/recovery/trusted-origin settings and Auth endpoint status (record status only, never secrets).
- Cloudflare frontend asset release and Worker deployment/version ID, source commit, environment, compatibility date, routes, and release history.
- Secure inventory of Worker secret/variable names and presence; never export values.
- Backup/PITR availability, retention, successful restore drill, recovery destination, RPO/RTO, and accountable owner.
- Migration deployment approvals/logs/checksums and any existing external migration ledger.

## Exact operator actions required

1. Request a separately approved, short-lived/read-only inspection path from the database owner; do not request or paste credentials in chat or repository files.
2. Have the DBA confirm the role is read-only and can see only required catalog metadata and aggregate data. If existing grants do not permit the inspection, stop rather than changing grants under this package.
3. Verify Production project and branch in the provider console, then run `catalog.sql` with the approved `psql` service.
4. Reconcile migration rows against checksum-bearing deployment records; mark gaps UNKNOWN and obtain DBA review.
5. Review row-count estimates and request DBA approval before exact aggregate or integrity scans. Run each approved script once and preserve restricted outputs.
6. Obtain frontend/Worker/Auth/backup evidence from their owners and complete the matrix.
7. Stop and deliver the evidence package to the release owner. Do not apply migrations, change configuration, deploy, or resume work into REL-03 execution without separate authorization.

The three data-query scripts use the same service form after the required review/approval gates:

```text
psql "service=jlproject-production-readonly" -X -v ON_ERROR_STOP=1 -f docs/verification/production-baseline/aggregate-estimates.sql
psql "service=jlproject-production-readonly" -X -v ON_ERROR_STOP=1 -f docs/verification/production-baseline/aggregate-exact.sql
psql "service=jlproject-production-readonly" -X -v ON_ERROR_STOP=1 -f docs/verification/production-baseline/integrity.sql
```

These are operator commands only; do not execute them as part of this review.
