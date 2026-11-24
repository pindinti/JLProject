# REL-05 Phase 4B.5 Production Cutover Closeout

**Status: PASS — formally accepted on 2026-11-24.** This closeout supplements the historical [REL-05 release report](../12-REL-05-RELEASE-REPORT.md) and the separate [Production hotfix provenance record](REL-05-PRODUCTION-HOTFIX-PROVENANCE.md). Neither earlier record is replaced.

## Release identity

| Item | Verified value |
| --- | --- |
| Approved source commit | `61a6f0f5d84772f8eff4cb157af051435afcb57a` |
| Neon Production project / branch / database | `crimson-glade-72578238` / `br-orange-shadow-b6yu9uxu` / `neondb` |
| Canonical Cloudflare Worker | `jlproject` |
| Deployment ID | `16e10b4e-9bad-42a9-9907-26d1e2c88046` |
| Attested executing Worker version | `80cb6fc6-5ac7-49ae-8e4c-789084ca4b71` |
| Frontend artifact SHA-256 | `51679A98B149B4FAD57AF5548533B463C37DE14E7DA91031CA0F1C6EF93A12B4` |

The accepted artifact set contained 14 pinned files. Its hashes were rechecked during cutover and remained unchanged. No application artifact was rebuilt or modified during this closeout.

## Migration chain

All 17 migrations were applied once, in numeric order, to official Production. Each committed and passed its required fresh-session postflight. The final installed migration is `0044`. Local migration files were rehashed for this record and match the approved chain.

| Migration | File | Result | Approved SHA-256 |
| --- | --- | --- | --- |
| 0028 | `0028_stage_date_planning_audit.sql` | PASS | `5E8E66FC082B95D1D3FA71E5B1FA6E014E76BD4F4BC105B8A6759AA009DE8F48` |
| 0029 | `0029_living_schedule_audit_concurrency.sql` | PASS | `C26D9E4DF65946C5B4D72A1B482E93A99F076EF837EB856CECC3D90288CB0626` |
| 0030 | `0030_multi_entity_audit_grouping.sql` | PASS | `0591E6960F419F8B29FE17FD8C21D178EB64084EBF393437DBA83A3AB82DCDF1` |
| 0031 | `0031_import_authorization_compatibility.sql` | PASS | `80F7595DE74E4D7C2E206B7E537241952A950FF7ABB74BD43F0FF2FE297BD884` |
| 0032 | `0032_unified_living_schedule_change_history.sql` | PASS | `96FB133943AF62636830919ABF2BB4FF076F9FE0856AD6CB3755F71CDB3D2E67` |
| 0033 | `0033_product_import_provenance_compatibility.sql` | PASS | `9A313419A67E66023FB3BC6B884A2CF518D1EEAF9C8FC7E6DB3B330E8BC6D175` |
| 0034 | `0034_product_status_study_workflow.sql` | PASS | `35CC637C78FB57B5005FC085E1641B2845F59B22E5A7FC0E088B71C10AC9BB2D` |
| 0035 | `0035_product_cloning_compatibility.sql` | PASS | `C86E8AE1A53EF5800724C86B7C74065FFB6B1BAF65DCAEAD68641925118F6D68` |
| 0036 | `0036_schedule_dependency_storage.sql` | PASS | `9EA61A6550BCB7F04165D21106D8CB7D7EC0246B22D1EDF51B3608857BB2CA52` |
| 0037 | `0037_controlled_schedule_dependencies.sql` | PASS | `FA0093B0452B7D0AC11CDFB518EA1A9F662C8C489AED7F6FA74F1A91AC78723B` |
| 0038 | `0038_guard_individual_schedule_dates.sql` | PASS | `50F5479D077F7A0A29DBCA6F323D111A79E06966CDEBA1A7FA60044D29980C49` |
| 0039 | `0039_guard_calendar_reschedule_apply.sql` | PASS | `B5566A30E4445F6B969C6BEAB6F6599600C014F68730B1085E823A674A72E876` |
| 0040 | `0040_guard_calendar_reschedule_reversal.sql` | PASS | `2A8657C04CF357CB9FFBAE137B6520C1807D77B7192C0227ECF241DED1522B00` |
| 0041 | `0041_guard_activity_creation_dependencies.sql` | PASS | `385250D8ADA2BB9369DD561A4BC5E102F1F662A56A562C435D0AC5F48EB54998` |
| 0042 | `0042_guard_hierarchy_move_dependencies.sql` | PASS | `A59EC689C267A7CE4E9F343029016D184536BC63154C26D5ECBE18478DBC6524` |
| 0043 | `0043_guard_schedule_deletion_dependencies.sql` | PASS | `FBE35B36EBAE927DDB4CE2A56B243CDCCCA7381C4C775A9809866808F1B21CD2` |
| 0044 | `0044_clone_schedule_dependencies.sql` | PASS | `A7D4DECF9096507164439B8AD42708D66E41D3EAD92AA59D1CD001200C8AE2C2` |

## Data preservation and security

- **Preservation: 24/24 PASS, zero unexplained differences.** The checks covered workspaces and memberships; products, disciplines, stages and stage definitions; activity rows, dates, ordering and versions; targets; imports and source rows; all four protected audit tables; calendar versions, exceptions and events; effective stage intervals; the Production R00 snapshot; and catalog fingerprints.
- The accepted Production baseline contained one R00 snapshot. Its identity and content fingerprint remained unchanged, and its immutability protection remained in place.
- The dependency storage and API remain dormant for existing Production data. No dependency rows were introduced. Dependency endpoints returned HTTP 404 in private and public application checks.
- **Final privileges: 16/16 PASS.** Checks covered private executor graph select/insert/delete rights; executor denial of R00 trigger and schema-creation capabilities; absence of temporary owner SET membership; the narrowly scoped Worker clone entry point; Worker clone-only graph behavior; no Worker executor membership; no direct Worker graph or deletion-audit table access; and no Worker execution of the private deletion guard.
- The 16 named privilege assertions all returned true: `executor_graph_delete`, `executor_graph_insert`, `executor_graph_select`, `executor_no_r00_trigger`, `executor_no_schema_create`, `owner_no_temp_set`, `worker_clone_entry`, `worker_dependency_clone_only`, `worker_no_deletion_audit_read`, `worker_no_executor_membership`, `worker_no_graph_delete`, `worker_no_graph_insert`, `worker_no_graph_select`, `worker_no_graph_update`, `worker_no_private_delete_guard`, and `worker_root_clone`.
- Temporary migration role memberships and grants were cleaned up. No Neon Auth configuration, identities, or memberships were changed by the cutover.

## Application verification and reopening

- The candidate Worker was deployed to the canonical `jlproject` Worker while public ingress was disabled. Cloudflare invocation telemetry correlated the private health request nonce to the exact executing version shown above. The request verified the Production database destination and returned HTTP 200.
- **Private authenticated smoke: 23/23 PASS.** Covered health, authenticated and anonymous session behavior, workspace and product listing, hierarchy, authorization scope, product status contract, calendar, unified history, calendar history, dormant dependency routes, and the unavailable development diagnostic route.
- **Public smoke: 26/26 PASS.** Repeated the authenticated application read checks and verified public health HTTP 200, frontend HTTP 200, `pt-BR` locale, and exact pinned frontend HTML.
- The durable smoke assertion record comprises: approved mode/version and token-time checks; health status/content; anonymous denial and authenticated success; workspace and product reads/scopes; existing authorized product identity; hierarchy payload; unscoped workspace denial (HTTP 403); product-status contract; calendar status/payload; unified and calendar-reschedule history; dormant dependency route denial (HTTP 404); and unavailable development diagnostics (HTTP 404). Public-only additions were frontend HTTP 200, expected locale, and exact pinned frontend HTML.
- Workspace scope checks passed; an unscoped workspace read returned HTTP 403. No customer schedule records were mutated by smoke testing.
- Effective observability settings matched the recorded pre-deployment unset state (`observability: null`). Supported Cloudflare metadata confirmed the equivalent unset configuration; bounded post-cleanup telemetry checks found no new invocation record. Logging was not changed and the Worker was not redeployed for this check.
- Cloudflare ingress was restored to `enabled=true`, `previews_enabled=true` and verified through a fresh GET at `2026-11-24T03:11:03.8543935Z`. Public `/api/health` returned HTTP 200. The matching frontend and authenticated reads were available.

The recorded maintenance window was `2026-11-24T00:23:22.5263459Z` through `2026-11-24T03:11:08.9603957Z`, or 167.77 minutes (2 hours 47 minutes 46 seconds). Public ingress is restored. Manual or external business-writer resumption remains under the release owner's operational control; the closeout did not change those systems.

## Backup and recovery evidence

- Retained exact-checkpoint backup: `backup-pre-phase4b5-20261124-exact`, branch `br-dry-sunset-b6h69xsk`, direct child of Production at parent LSN `0/3DA61B8`, ready, no expiration, read-only compute. Backup-to-frozen-baseline comparison passed 24/24.
- Independent recovery drill: child `br-damp-flower-b6w1u9lu`, created from that retained backup at the same parent LSN. The independent read-only comparison passed 24/24, including protected audits, effective stage intervals, R00, catalog, ownership and privileges.
- Earlier retained backup: `backup-pre-release-20261113`, branch `br-round-band-b6qslh9d`, no automatic expiration. Both retained backup branches were preserved.

## Durable sanitized evidence and supporting files

This closeout is the durable sanitized release evidence record. It preserves the accepted commit and artifact identifiers, all 17 migration hashes and PASS statuses, all 24 preservation categories and result, all 16 named privilege assertions and result, smoke coverage and counts, R00 result, backup/recovery identities and verification, ingress restoration, and maintenance times. The historical REL-05 report and hotfix provenance supplement preserve the preceding release history. No row-level customer data, authentication material, connection string, raw terminal transcript, or unfiltered provider response is included in these committed records.

Detailed sanitized operator evidence remains supplemental and outside Git. Its per-migration install, postflight, and preservation files are under:

```text
%TEMP%\jlproject-official-cutover-0028-0044\official-migrations-20261124T025316Z\
%TEMP%\jlproject-official-cutover-0028-0044\official-migrations-20261124T030013Z\
```

The second directory contains per-migration install, fresh-session postflight and preservation records for 0034–0044, plus `final-privileges.json`, `final-application-contracts.json` and the `application` evidence directory. The application directory contains `official-cutover-result.json`, deployment/version and observability evidence, ingress restoration, and an authorized read-only R00 check. The sanitized smoke evidence is:

```text
%TEMP%\jlproject-official-cutover-0028-0044\smoke-private-20261124T031052Z.json
%TEMP%\jlproject-official-cutover-0028-0044\smoke-public-20261124T031108Z.json
```

Backup and recovery-drill evidence is under:

```text
%TEMP%\JLProject-phase4b5-production-checkpoint-20261124T002322Z-d7145cff\
```

Do not copy connection configuration, raw transcripts, credentials, Auth tokens, business rows, or unreviewed snapshots into Git.

## Temporary resources and operator cleanup

Metadata-only branch checks at `2026-11-24T03:26Z` found these known Production branches:

| Branch | Purpose and state | Expiration / disposition |
| --- | --- | --- |
| `br-dry-sunset-b6h69xsk` | Retained exact-checkpoint recovery backup; ready, parent `br-orange-shadow-b6yu9uxu`, LSN `0/3DA61B8` | No expiration; **retain** |
| `br-round-band-b6qslh9d` | Earlier retained Production backup; ready | No expiration; **retain** |
| `br-damp-flower-b6w1u9lu` | Independent recovery-drill child of `br-dry-sunset-b6h69xsk`; ready | Expires `2026-11-24T03:27:27Z`; disposable drill child, not a retained backup |
| `br-fragrant-firefly-b6ixdioy` | Production-copy migration rehearsal from Production LSN `0/3DA61B8`; ready | Expires `2026-11-24T03:33:11Z`; disposable rehearsal child, not a retained backup |

Do not treat the two expiring children as recovery backups. Their expiration or later cleanup must not affect either retained backup. The isolated `jlproject-cutover-rehearsal` Worker and local operator relay were removed/stopped as part of the previously accepted proof; no listener remained on local ports 4179 or 4184 at this closeout check. The full Neon project branch list did not produce a usable CLI result during this closeout, so the table is the inventory of known Production-related branches, not a claim that no other project branch exists. Before any later branch deletion, refresh the authoritative branch inventory and match the exact branch ID.

Two encrypted DPAPI handoff files still exist in the current Windows user's temporary directory:

```text
%TEMP%\jlproject-observability-token.dpapi
%TEMP%\jlproject-production-smoke-token.dpapi
```

The first contains the temporary account-scoped Cloudflare `Workers Observability: Edit` token; the second contains the encrypted short-lived authenticated smoke handoff. Their ciphertext was not read or decrypted for this closeout. Revoke the temporary Cloudflare token before deleting either local handoff:

1. In the Cloudflare dashboard, select the verified JLProject account (`8c4dffce7be1030cad7780c38a1b470f`), then open **My Profile → API Tokens**.
2. Identify the temporary token by its operator-recorded creation and the exact `Workers Observability: Edit` permission and account-only scope. The token ID is not recorded in this repository; do not guess or revoke another token.
3. Revoke that exact token, then refresh the token list and confirm it is no longer active. Do not paste the token, token ID, authorization header, or verification response containing sensitive fields into logs or chat.
4. After confirming no process uses the handoffs, remove only the two named encrypted files and verify they are absent:

```powershell
$handoffs = @(
  (Join-Path $env:TEMP 'jlproject-observability-token.dpapi'),
  (Join-Path $env:TEMP 'jlproject-production-smoke-token.dpapi')
)
foreach ($path in $handoffs) {
  if (Test-Path -LiteralPath $path) {
    Remove-Item -LiteralPath $path -Force
  }
  if (Test-Path -LiteralPath $path) {
    throw "Encrypted handoff cleanup failed: $path"
  }
}
```

This cleanup procedure is documentation only; neither token revocation nor file deletion was performed during closeout.

## Tooling to retain for future releases

- Keep migration SQL and verification SQL as checked-in files; invoke native PostgreSQL `psql` directly with TLS verification and `ON_ERROR_STOP=1`. Avoid Neon CLI's embedded psql fallback and dynamic inline SQL construction.
- Keep the version-pinned migration hash manifest, explicit one-file-at-a-time transactions, commit-marker checks, and fresh-session postflight before advancing.
- Keep the fixture runner and handoff manifest's strict typed variable validation, exact variable names, lossless argument passing, exit-code propagation, and stdout/stderr evidence capture. Do not filter by naming convention or parse truncated JSON in temporary wrappers.
- Keep stage-aware fixtures and separate owner, Worker, and read-only verification sessions. Preserve the 0036-only postflight at its migration boundary.
- Keep deterministic two-session PostgreSQL races that prove actual blocking with `pg_blocking_pids()`, bounded timeouts, explicit release/rollback, and complete before/after state comparisons.
- Keep read-only 24-check preservation snapshots and the historical R00 SQL as checked-in file invocations, with evidence stored outside the repository.
- Keep Cloudflare identity/ingress preflight and exact executing-version attestation correlated through a unique request nonce and provider telemetry. Obtain fresh authorization through the supported Wrangler mechanism without placing credentials in command output or artifacts.
- Retain a single reviewed release evidence schema that records target identity, migration commits, fresh postflights, final privileges, smoke counts, artifact digests, ingress state, and cleanup status without raw customer data or credentials.

## Git closeout proposal

At closeout inspection, the existing untracked files were the hotfix provenance supplement and `docs/verification/production-baseline/aggregate-exact-reviewed.sql`. The latter is an operator-reviewed baseline query and is excluded from this release documentation commit. Recommended exact staging allowlist:

```text
docs/12-REL-05-RELEASE-REPORT.md	document link to this later closeout; historical report body remains intact
docs/verification/REL-05-PRODUCTION-HOTFIX-PROVENANCE.md	preserve the approved November 13 hotfix provenance
docs/verification/REL-05-PHASE4B5-PRODUCTION-CUTOVER-CLOSEOUT.md	formal 2026-11-24 cutover record
```

Suggested single commit message: `Record Phase 4B.5 Production cutover closeout`. Do not include the Production baseline SQL, temporary evidence, credentials, generated output, or any unrelated file. No staging or commit was performed for this closeout.
