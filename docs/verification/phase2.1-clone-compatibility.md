# Phase 2.1 clone compatibility preparation

## Confirmed defects and correction

The installed Development `clone_product` accepts active and archived source products after migration 0034. Its `clone_root_activity` helper, introduced by 0025, still requires an active source; an archived product with a root activity fails partway through the clone transaction. The stage activity insert in `clone_product` copies dates but omits the three working-day planning fields. Its R00 builder omits the same fields for stage activities. The root helper and root R00 already preserve them.

Migration 0035 changes these two functions and adds one executor-owned stage activity helper. It remains one `BEGIN`/`COMMIT` transaction and guards the reviewed function definitions before replacement. The helpers check the workspace and active editor/administrator membership, accept the source regardless of product status, and require an active target created by the actor in the current transaction. Source activity rows must be active within active source hierarchy. The Worker receives helper `EXECUTE` only; it retains no direct insert privilege for planning metadata. Temporary schema `CREATE` and owner role membership are revoked before commit. All function calls use schema-qualified business tables; the definer helpers use `pg_catalog, pg_temp` search paths. No existing schedule, audit, or R00 row is modified by the migration.

Prepared migration SHA-256: `C86E8AE1A53EF5800724C86B7C74065FFB6B1BAF65DCAEAD68641925118F6D68`.

The isolated run of the previous checksum stopped in the first prerequisite check before any grants or schema changes. The corrected assertion uses `proconfig @> ARRAY['search_path=pg_catalog, pg_temp']` with `IS NOT TRUE` to reject a missing or mismatched setting. A read-only Development query accepted the installed setting and rejected a different setting, a null array, and a missing catalog row. The corrected migration remains unapplied.

Development preflight found a `cloud_admin` grant of `jlproject_date_executor` to `neondb_owner` with `ADMIN TRUE`, `INHERIT FALSE`, and `SET FALSE`. The former cleanup assertion checked whether any membership remained, so it would have rejected this baseline. The corrected migration explicitly attributes its temporary grant to `neondb_owner` and revokes only that grant. Before granting and after revoking, it requires exactly one direct membership for the pair in `pg_auth_members`, with `cloud_admin` as grantor and the original options. An unexpected baseline or a leftover temporary grant aborts the transaction. The [preflight query](../../db/verification/phase2.1-0035-preflight.sql) reports those catalog fields. The six focused contract tests pass. Execution and database integration remain pending.

## Source-to-clone field contract

| Entity | Copied | Regenerated or excluded |
| --- | --- | --- |
| Product | Description | New ID/name, `em_estudo` classification, active status, actor and timestamps; no source status or lineage claim |
| Disciplines and stages | Active hierarchy, shared stage definition, display metadata, explicit full or partial stage dates | New product-specific IDs, actor and timestamps; deleted rows and source audit provenance excluded |
| Stage and root activities | Name/type, ISO civil dates, order, notes, color override, planning mode, working-day duration, calendar version | New activity IDs, actor and timestamps; source external/import identifiers, row version, audit history excluded |
| Targets | Active target dates, order, description, color | New IDs, actor and timestamps; deleted targets excluded |
| New R00 | Initial clone hierarchy, activity planning fields, stage dates, root activities, targets | New immutable baseline ID; source import metadata and dependencies excluded |

The existing clone transaction and product-scoped audit triggers should yield one Living Schedule version increment for the clone and related entity events under one operation ID. Failed clone statements should roll back all new rows and audit details. The migration does not alter product history or reversal logic.

## Verification and remaining work

`db/verification/phase2.1-0035-rollback.sql` prepares a Worker-role, rollback-only synthetic check of an active source with root and stage working-day activities, full and partial stage dates, copied R00 metadata, source immutability, audit grouping, and helper denial. It must run only after separate authorization to apply migration 0035. It has not been executed against Development.

The archived-root case also needs a multi-transaction synthetic source: root activity creation requires an active product, while the status function assigns a distinct operation ID and the audit model disallows two operation IDs for one product in one transaction. An isolated, disposable Development-derived branch can create the synthetic source, commit its archive transition, run the clone verification, and discard the branch. This cannot be represented as one rollback-only transaction without weakening the production audit constraint. The `em_estudo` source case can be checked similarly on that branch or through an isolated rollback-only source created with that classification. No real product will be used as a write fixture. Confirm source status and R00 fingerprints before and after integration checks.

Migration execution should use the verified Development project `rapid-mud-63974868`, branch `development` (`br-delicate-glitter-b6mj0051`), database `neondb`, `neondb_owner`, and `ON_ERROR_STOP=1`, after object and privilege preflight. The local Worker connection must remain `jlproject_worker`. The migration is pending authorization and has no execution timestamp or result.

## Development execution and verification

The approved checksum above committed on official Development (`rapid-mud-63974868`, `br-delicate-glitter-b6mj0051`, `neondb`) as `neondb_owner` with `ON_ERROR_STOP=1`. The client recorded success at `2026-11-19T04:30:47Z`. This supersedes the pending status above.

The rollback fixture now uses `read_product_schedule_cursor` and `list_product_schedule_operations` to verify one version increment, one grouped audit operation with activity detail, and no version change after duplicate rejection. The Worker still cannot read the backing audit tables directly. The corrected fixture passed on the already migrated isolation branch `br-square-haze-b69b03ow`. The archived fixture used separate committed seed and archive transactions on that branch and rolled back the verification clone. It verified nonmember and foreign-workspace rejection, an active `em_estudo` clone, regenerated activity IDs, matching root and stage activity planning values in the new R00, grouped audit events at schedule version 1, and unchanged source status, stages, activities, R00 and audit history.

Official Development passed both the Phase 2.1 Worker rollback test and the existing Phase 1.1 clone/import Worker regression. Pre/post fingerprints matched for all six products, five R00 snapshots, six cursors, six operations, 33 disciplines, 78 stages, 150 activities, and 16 targets. The only owner membership remained the `cloud_admin` grant (`ADMIN TRUE`, `INHERIT FALSE`, `SET FALSE`). The executor had no schema `CREATE` privilege. The Worker could execute the clone helper and had no executor membership, direct planning-column insert, direct schedule-state read, or R00 update/delete privilege.

The six migration contract tests, the full suite (57 files, 471 tests), lint, typecheck, build, and whitespace checks passed. The build emitted the existing client chunk size advisory and removed the generated copy of local Worker secrets.

Neon confirmed deletion of the disposable validation branch after the results were recorded.
