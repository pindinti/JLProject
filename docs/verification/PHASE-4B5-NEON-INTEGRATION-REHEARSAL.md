# Phase 4B.5 Neon integration rehearsal

## Formal clean rehearsal — PASS

On 2026-11-23, the complete run passed on one new three-hour disposable Development child, `br-tiny-salad-b6i5c4c4`. The preflight verified the Development catalog and historical R00 fingerprint read-only, all nine approved migration SHA-256 values, the fixture manifest, native psql 18.7 over TLS 1.3 with hostname verification, and 251 targeted tests across 20 suites. Both branch-scoped synthetic Auth identities passed the HTTP and database checks. No fixture was changed or retried during the run.

| Migration | Result and required fixture evidence |
|---|---|
| 0036 | PASS. Storage and initial least-privilege postflight before 0037. |
| 0037 | PASS. Controlled confirmation, audit grouping, replay and rollback. |
| 0038 | PASS. Individual date-writer guards and empty-graph compatibility. |
| 0039 | PASS. Calendar apply and dependency conflict handling. |
| 0040 | PASS. Calendar reversal, audit preservation and atomic conflict rejection. |
| 0041 | PASS. Activity creation, audited stage-date setup, dependency guards and viewer denial. |
| 0042 | PASS. Hierarchy moves, dependency guards, audit/cursor checks and rollback. |
| 0043 | PASS. Linked subtree and direct stage protection, deletion audit, exact collision rollback and repeated owner postflight. |
| 0044 | PASS. Corrected UUID handoff, four clone cases including archived linked roots, remap rollback, graph/R00 equivalence and source immutability. |

| Two-session race | Waiting PID | Blocking PID | Result |
|---|---:|---:|---|
| Cycle prevention | 2369 | 2368 | PASS. Stale preview and fresh cycle rejected. |
| Duplicate edge | 2379 | 2378 | PASS. Stale preview and fresh duplicate rejected. |
| Graph versus activity date | 2390 | 2389 | PASS. Current graph blocked the date change. |
| Workspace calendar versus graph | 2401 | 2402 | PASS. Calendar-version change invalidated the graph confirmation. |

Each race observed the blocker using `pg_blocking_pids()` before releasing the winner. The required independent version-token, audit and state comparisons passed. The final privilege audit passed 16/16 after the grantor-qualified revoke. A fresh owner session verified that the original `cloud_admin` membership remained intact and effective temporary SET access was absent. The historical R00 check matched exactly six rows with fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1` before branch creation and after cloning and concurrency. The child identity was reverified before deletion, and the follow-up lookup returned HTTP 404.

The sanitized local rehearsal log is `jlproject-phase4b5-clean-2fc17bc4d0.log`, SHA-256 `8155537E685911F89D711ABA86DB1B081F181B92C8D528B30A9194CC43CD5364`. This summary retains the results and identifiers needed to cross-check that log. The log stays outside version control.

The clean isolated rehearsal is complete. Official Development access was read-only, Production was untouched, and dependency routes remained dormant. Applying migrations to official Development or enabling routes requires separate authorization.

## Formal closure audit and clean-rehearsal gate

The project owner reports that 0036–0044 passed functional verification on a disposable child, all four races passed with observed `pg_blocking_pids()`, the final privilege audit passed 16/16, the temporary grant was removed, the original `cloud_admin` membership survived, and historical R00 was preserved. This evidence describes a run that continued after a local 0044 fixture correction. It does not count as the clean run required by the execution order. This repository audit did not connect to a database or independently replay the supplied run.

### Findings

| Severity | Finding and disposition |
|---|---|
| BLOCKER | A fresh run must pass from 0036 through 0044 and all four races on one separately approved child. The [clone dependency seed](../../db/verification/phase4b3c4-clone-seed-owner-dependencies.sql#L89) already contains `<> (CASE WHEN v_source.root_operation_id IS NOT NULL THEN 2 ELSE 0 END)`. The [0044 contract](../../tests/migration-0044.test.ts) now pins the corrected comparison. |
| IMPORTANT | The Auth gate required an email property the create response does not guarantee. The [gate](../../db/verification/phase4b5-provision-auth.ps1#L55) now accepts the documented ID-only response. Any returned email must match, and the existing read-only SQL must still match both provider UUIDs and exact branch-derived emails before the gate returns either ID. Local mocks now exercise that response shape. [Neon Auth response contract](https://neon.com/docs/reference/api/auth/create-branch-neon-auth-new-user) |
| IMPORTANT | The confirmation, reversal, clone and shared edge seed fixtures had successful early `\quit` paths. Their prerequisite failures now raise SQLSTATE `22023` under `ON_ERROR_STOP`. The concurrency seed also fails closed before writes and uses the verified synthetic Auth pair rather than picking a pre-existing member. |
| IMPORTANT | The [concurrency procedure](PHASE-4B5-POSTGRESQL-CONCURRENCY.md#sessions-and-permissions) had used autocommit for the temporary grant and only checked effective permissions. It now commits GRANT and grantor-qualified REVOKE in explicit transactions and checks the separate catalog rows and effective SET access in fresh read-only sessions. The same procedure distinguishes a succeeded command tag from an effective committed grant. The cause of the earlier standalone GRANT discrepancy is unconfirmed. |
| IMPORTANT | The loser state comparison omitted the authoritative operation source-event rows. [Concurrency state](../../db/verification/phase4b5-concurrency-state.sql) now includes them. These checks complement the existing audit, cursor and state comparisons and do not replace the real blocker observation. |
| OPTIONAL | The checked-in runner can drive serial fixture calls and manifest handoffs. Keep two-session coordination explicit until an end-to-end conductor has been validated. Retain sanitized outcome and privilege evidence with the clean-run record so a later audit does not have to infer what a PASS label covered. |

### API and migration review

- The Worker entry point is [wrangler.jsonc](../../wrangler.jsonc). Its [router](../../worker/index.ts#L131) has no dependency dispatch, and [schedule route parsing](../../worker/schedule-api.ts#L13) excludes the graph endpoints. The entry-point test asserts 404 for GET dependencies and POST preview/confirm, before authentication runs. The only direct handler caller outside its own module is its test.
- The [dormant handler](../../worker/dependency-api.ts#L126) checks origin, identity, UUID routes and method. [Workspace authorization](../../worker/authorization.ts#L23) requires the active membership to match the requested workspace, grants graph read to viewers, and limits edits to editor/admin. The handler binds a signed, expiring preview to the actor, workspace, product, schedule/calendar versions, and fingerprint before confirmation. [0037](../../db/migrations/0037_controlled_schedule_dependencies.sql#L361) revokes Worker and PUBLIC execution on private graph, receipt and confirmation functions. SQL independently scopes the product and active membership.
- Existing schedule routes remain active intentionally. They authenticate and authorize through the router and schedule handler and report dependency conflicts through existing mutation paths. The existing [clone route](../../worker/product-api.ts#L99) requires edit permission. Its [database clone helper](../../db/migrations/0044_clone_schedule_dependencies.sql#L62) is intentionally callable by the Worker, verifies editor/admin membership and fresh scoped clone rows, and writes remapped edges with the immutable R00. This is distinct from general-purpose graph access. 0036 denies direct edge access, 0037 grants executor-only edge operations, and 0044 retains Worker denial while granting the scoped clone helper.
- All nine approved hashes and outer transaction boundaries matched. Reviewed boundaries were 0036 storage-only privilege postflight, 0037 controlled confirmation and rollback, 0038 individual date guards, 0039 calendar apply, 0040 reversal, 0041 audited activity creation, 0042 hierarchy setup/postflight/runtime, 0043 collision preflight/commit/owner checks and rollback-only deletion, and 0044 four clone cases and source/R00 postflight. The 0036 postflight stays before 0037. The 0043 owner postflight stays on both sides of the rollback-only Worker test. The remaining CASE occurrences inspected were ordinary SELECT expressions, assignments or already parenthesized predicates. Static review cannot validate PostgreSQL runtime behavior.

The [clean-rehearsal sequence](PHASE-4B5-EXECUTION-ORDER.md#formal-clean-rehearsal-and-evidence) is ready for separately approved execution. Record each stage's commit and fixtures, both Auth IDs verified in the child, all four real waits with paired PIDs and state comparisons, the final privileges and exact grantors, all six historical R00 fingerprints, and verified child deletion. Stop on the first unexpected failure and discard that child. **Phase 4B.5 remains open** until a clean record is reviewed. Shared Development migration, Production access, deployment and route activation require separate authorization.

Local verification passed 221 tests across 20 suites covering migration contracts 0036–0044, the Phase 4B.5 verification contracts and Windows PowerShell mocks, Worker dependency and schedule routes, and dependency preview rules. Targeted ESLint on the four changed test files, TypeScript typecheck, the nine reviewed SHA-256 and outer transaction checks, and `git diff --check` passed. The application build and full test suite were skipped because the audit changes only verification tooling, tests and documentation. No migration, fixture, Auth request, role change, branch operation or deployment ran in this audit.

## Rehearsal passed the Auth status check and stopped at response-body validation

Read-only preflight verified ready Development branch `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`, database `neondb`, the catalog prerequisites, and all nine approved migration checksums. Native psql 18.7 launched through Neon CLI 9.9.3 and negotiated TLS 1.3 with `verify-full`. The checked-in handoff probe preserved the supplied values and exited 0. Its deliberate division by zero produced SQLSTATE `22012` and the expected exit 3.

The only disposable child was `br-withered-meadow-b6u83lic`, named `phase4b5-rehearsal-fcbd3d717a` with expiry `2026-11-23T16:22:46Z`. The checked-in provisioning gate verified the child metadata and advanced past its exact HTTP 201 and CLI exit 0 checks for the admin request. It then failed at line 58 with `Invalid provider ID or unexpected email for the synthetic admin.` This is a PowerShell validation failure. No SQLSTATE was issued by the provisioning gate. The failure occurred after JSON parsing and before the viewer request or database identity preflight. The response body was suppressed, so the exact rejected field cannot be recovered from this run.

Neon's documented HTTP 201 response schema lists only an `id` field. The current gate also requires an `email` property in that response, which the schema does not promise. This explains a concrete contract mismatch, although the actual response shape was not retained. A read-only child query found one row with the expected synthetic admin email and zero viewer rows. No create was retried. Any separately reviewed correction should keep the HTTP 201 and provider UUID checks, use the existing owner SQL to verify the exact UUID/email pairs on the child, and cover the documented ID-only response in local tests. [Neon Auth response contract](https://neon.com/docs/reference/api/auth/create-branch-neon-auth-new-user)

| Migration | Installation | Runtime fixture |
|---|---|---|
| 0036 | NOT VERIFIED | NOT VERIFIED storage and privileges |
| 0037 | NOT VERIFIED | NOT VERIFIED confirmation, audit grouping and rollback |
| 0038 | NOT VERIFIED | NOT VERIFIED individual date guards |
| 0039 | NOT VERIFIED | NOT VERIFIED calendar apply |
| 0040 | NOT VERIFIED | NOT VERIFIED calendar reversal |
| 0041 | NOT VERIFIED | NOT VERIFIED activity creation and viewer denial |
| 0042 | NOT VERIFIED | NOT VERIFIED hierarchy moves |
| 0043 | NOT VERIFIED | NOT VERIFIED subtree, direct stage and ancestor protection, exact collision rollback and owner audit/cursor postflight |
| 0044 | NOT VERIFIED | NOT VERIFIED all four clone cases, archived roots, remapping, source immutability and new R00 equivalence |

Cycle, duplicate edge, graph versus date and calendar versus graph were each **NOT VERIFIED**. No contender sessions started and there is no `pg_blocking_pids` evidence. No migration or fixture membership write began. Audit grouping, cursor advancement and complete-chain permissions remain unverified in this rehearsal.

Read-only post-stop checks confirmed that dependency storage and private confirmation were still absent, with no owner executor SET, Worker executor membership or executor schema CREATE privilege. All six historical R00 rows matched fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1` on Development and the child. Cleanup reverified the exact child ID, project, parent, name, expiry and non-default status before deletion and confirmed HTTP 404 on follow-up. The temporary public CA bundle was removed. Only this report changed. Application lint, typecheck, tests and build were skipped for the report-only update.

**Technical NO-GO for official Development.** The Auth response-body contract must be reviewed before another isolated run. Corrected 0043 runtime, 0044 cloning and all four races still require live evidence.

## Neon Auth HTTP status gate corrected and tested locally

The failed invocation used `neon api /projects/<project>/branches/<child>/auth/users -X POST -f email=<synthetic-email> -i` and matched only an `HTTP/<version>` prefix. Inspection of installed Neon CLI 9.9.3 confirmed that `-i` writes one textual `HTTP <status> <reason>` line followed by headers, a blank line and a separate body. JSON output mode only structures the body. The original request's status cannot be recovered from the admin row.

The checked-in `db/verification/phase4b5-provision-auth.ps1` now confirms the disposable child's metadata and accepts one complete unversioned or versioned status line. Each role must independently return HTTP 201, CLI exit 0, a valid nonzero provider UUID and the expected email. The gate fails on missing, malformed, duplicate or contradictory status evidence and does not expose raw API output. It returns the two distinct IDs only after the existing read-only owner SQL verifies both IDs and emails in the verified child's Auth schema. Later owner seeds still repeat that check. Failed or partial provisioning stops the run and requires child cleanup without retry.

All 48 focused tests, targeted ESLint, typecheck and `git diff --check` passed. Native Windows PowerShell tests used a fake Neon executable and sanitized output. Both supported status forms passed. HTTP 400, 401, 409 and 500 failed, including HTTP 409 with CLI exit 0. Missing, malformed, duplicate and conflicting statuses, invalid identities and a simulated Auth row mismatch failed closed. A successful admin response followed by a failed viewer response exited nonzero, emitted neither ID, skipped the SQL check and sent no retry. The application build was skipped because this is verification tooling only.

The corrected gate is ready for another authorized isolated rehearsal. No Neon branch, Auth API request or database access was made during preparation. Official Development remains **NO-GO** pending live end-to-end rehearsal evidence.

## Rehearsal stopped at the Neon Auth response check

Read-only preflight verified official Development project `rapid-mud-63974868`, ready branch `br-delicate-glitter-b6mj0051`, and database `neondb`. The prerequisite catalog showed the scoped keys, intact R00 immutability trigger and no dependency storage. All nine local migration hashes matched the reviewed values. Native psql 18.7 launched through Neon CLI 9.9.3 over TLS 1.3 with `verify-full`. The checked-in handoff probe preserved all supplied values and rolled back with exit 0. Its deliberate division by zero produced SQLSTATE `22012` and the expected exit 3.

Neon created the single non-default Development child `br-withered-wind-b6vr9fw3`, named `phase4b5-rehearsal-b3295e5a6f`, with expiry `2026-11-23T16:05:12Z`. The child was ready and its ID, project, parent, name and expiry matched before the branch-scoped synthetic admin request. The first unexpected failure was the local exception `Auth call for admin did not return HTTP 201.` The status check expected an `HTTP/<version>` prefix, but the installed Neon CLI's `api -i` implementation formats status as `HTTP ${response.status} ${response.statusText}`. The CLI call itself returned exit 0. A read-only query on the child found one row matching the synthetic admin email and zero matching the viewer email. The viewer request was never sent, the numeric HTTP status was not retained, and no provider ID comparison or shared identity gate ran. No Auth request was retried.

| Migration | Installation | Runtime fixture |
|---|---|---|
| 0036 | NOT VERIFIED | NOT VERIFIED storage and privilege check |
| 0037 | NOT VERIFIED | NOT VERIFIED confirmation, audit grouping and rollback |
| 0038 | NOT VERIFIED | NOT VERIFIED individual date guards |
| 0039 | NOT VERIFIED | NOT VERIFIED calendar apply |
| 0040 | NOT VERIFIED | NOT VERIFIED calendar reversal |
| 0041 | NOT VERIFIED | NOT VERIFIED activity creation and viewer denial |
| 0042 | NOT VERIFIED | NOT VERIFIED hierarchy moves |
| 0043 | NOT VERIFIED | NOT VERIFIED linked-child edge `0101`, direct stage edge `0103`, positive deletions, collision and owner postflight |
| 0044 | NOT VERIFIED | NOT VERIFIED all four clone scenarios, archived root remapping, clone R00/working-graph equivalence and source immutability |

The four concurrency races, cycle, duplicate edge, graph versus date and calendar versus graph, are each **NOT VERIFIED**. No contender sessions were opened, so there is no `pg_blocking_pids` evidence. Audit grouping, cursor advancement and complete-chain Worker permissions remain unverified in this run.

The child read-only post-stop check confirmed the dependency table and private confirmation function were absent. Owner executor SET, Worker executor membership and executor schema CREATE were all false. The checked-in historical R00 check passed on both Development and the child for all six rows and fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`. No migration, fixture, or fixture membership write began. Cleanup reverified the child's exact identity, parent and expiry, deleted it and confirmed HTTP 404 on follow-up. The temporary public CA bundle was removed. Only this report changed, so application lint, typecheck, tests and build were skipped.

**Technical NO-GO for official Development.** Before another authorized rehearsal, validate status handling with the current Neon CLI on a harmless read-only request so the Auth gate can verify HTTP 201 and both provider IDs. Live 0043, 0044 and concurrency evidence is still required.

## 0043 linked-stage deletion assertion corrected

The overlapping stage and its child match edges ending `0102` and `0101`, respectively. The guard considers every endpoint in the deletion subtree, orders the matching edges by ID and takes the first. The Worker now requires `dependency_conflict`, reason `linked_endpoint`, edge `0101` and the exact linked child ID and kind. It submits the preview fingerprint and requires the confirmed deletion to return the same conflict payload.

A separate scenario targets the stage endpoint of edge `0103` directly in the descendant product, where that edge is the only dependency. The existing ancestor-discipline probe still checks that same stage as a linked descendant. The directly linked activity and the `missing_boundary` case each match a single seeded edge. The other deletion cases have no additional competing-edge expectation. Positive deletion, explicit and partial stage coverage, and the exact `schedule_deletion_events_pkey` collision probe are preserved.

The Worker compares all product-scoped discipline, stage and activity rows, public audit history and the schedule cursor before and after each of the three subtree rejections, inside the rollback-only transaction. The existing read-only owner postflight after rollback still compares the private graph and audit fingerprint with the committed collision baseline. The runtime handoff no longer includes the unused `0102` variable. Owner dependency setup retains and verifies both overlapping edges.

All 45 focused migration, seed, boundary, handoff and execution-order tests, targeted ESLint, typecheck and `git diff --check` passed. The application build was skipped because the changes are confined to verification. The corrected fixture is ready for another authorized isolated rehearsal. No SQL was executed in this preparation. Corrected 0043 runtime, 0044 clone/R00 verification and all four concurrency races still need live evidence. Official Development remains **NO-GO**.

## 0043 collision setup passed; runtime selected a linked child edge

Read-only preflight verified canonical Development project rapid-mud-63974868 and branch br-delicate-glitter-b6mj0051, the catalog prerequisites, and all nine migration checksums. Native psql 18.7 delegated over TLS 1.3 with verify-full. The handoff probe succeeded with exit 0 and its deliberate SQL error returned 22012 and exit 3. The historical R00 file matched six rows and fingerprint 9b6daa6196b11b3bee428a1d96fcd1c1. The only disposable child was br-gentle-fire-b6oued32, named phase4b5-rehearsal-e384e1fb45 with expiry 2026-11-23T16:54:32Z. Both child Auth requests returned HTTP 201 and the shared identity gate passed.

| Migration | Installation and in-file postflight | Fixture result |
|---|---|---|
| 0036 | PASS | PASS storage and privilege check before 0037 |
| 0037 | PASS | PASS confirmation, audit grouping and rollback |
| 0038 | PASS | PASS individual date guards |
| 0039 | PASS | PASS calendar apply |
| 0040 | PASS | PASS calendar reversal and conflict, audit and rollback assertions |
| 0041 | PASS | PASS structure, four audited stage dates and source events, four edges, activity creation and viewer denial |
| 0042 | PASS | PASS six edges, owner audit/cursor postflight and Worker hierarchy runtime |
| 0043 | PASS | PASS owner structure, two audited dates, five edges, owner collision preflight, direct Worker collision commit and first owner postflight. FAIL Worker deletion runtime at the linked-stage preview. Later runtime cases and repeated owner postflight NOT VERIFIED. |
| 0044 | NOT VERIFIED | NOT VERIFIED all four clones, archived linked roots, endpoint remapping, source immutability and new R00/working-graph equivalence |

The corrected collision sequence verified the committed deletion with one ledger row, one grouped operation, two audit events, the expected legacy and source-event associations, one activity version and cursor advance, and unchanged unrelated records. The direct Worker fixture used the authorized preview/delete path without private ledger reads. The runtime passed the direct linked-activity rejection and unchanged-row assertion before stopping at the linked-stage preview.

The first unexpected error was SQLSTATE P0001 at db/verification/phase4b3c3-schedule-deletion.sql:309, inline block line 120, with native exit 3. The assertion expected the linked-stage edge ending 0102. The actual preview returned status dependency_conflict, reason linked_endpoint, edge 4b430000-0000-4000-8000-000000000101 and linkedEndpoint activity 5c388d48-8b79-3907-4833-8f17c94c5eda. The stage subtree includes that linked child. The guard selects the first matching edge by edge ID, so the child edge 0101 wins before the direct stage edge 0102. PostgreSQL blocked the deletion. The fixture's expected edge did not match its overlapping seed data. The test session closed without a commit. Later subtree and boundary cases, the exact schedule_deletion_events_pkey rejection, successful runtime deletions and the repeated owner snapshot comparison were not reached. No retry, script repair, or privilege change was performed in response.

Read-only post-stop checks found no Worker direct graph access, private graph read or confirmation execute privileges, Worker executor membership, temporary owner SET or executor schema CREATE. The historical R00 file again verified all six rows against the approved fingerprint. All four concurrency races remain NOT VERIFIED. No contender sessions started and there is no pg_blocking_pids evidence. Complete-chain security and clone isolation were not reached.

Cleanup reverified the child's project, parent, ID, name, expiry and non-default status, then deleted it. The follow-up lookup returned HTTP 404. Canonical Development access was read-only. Only this report changed, so application lint, typecheck, tests and build were skipped.

**Technical NO-GO for official Development.** The 0043 runtime fixture must account for the deterministic child edge when several edges block the same subtree, while retaining coverage of a direct stage endpoint. The remaining 0043 runtime assertions, 0044 and the four races still need authorized isolated verification.

## 0043 collision fixture separates Worker writes from private audit reads

The prior direct Worker read at line 32 of the collision seed checked that the deletion operation ID had no ledger row. The second read at line 54 expected one committed collision deletion with the intended actor and reason. The ledger operation ID is a primary key. Both private reads now live in the owner verification, where the expected counts are zero before the collision and one after it. The Worker date seed, its included date helper, and the Worker deletion runtime contain no direct private audit or dependency table reads.

The runbook now starts with a read-only owner preflight after the five dependency confirmations. It checks the synthetic live root activity, active admin, empty graph and unused operation ID. It emits the original activity version, schedule cursor, and a fingerprint of the scoped workspace schedule, graph, cursor and audit state, excluding only the collision writes checked separately. The checked-in manifest passes the two versions to the direct Worker seed and all three baseline values to the owner postflight. The Worker preserves its own role and membership checks, preview, justification, operation ID, committed deletion, and response checks. It verifies that the activity version and schedule cursor each advance once before committing.

The first owner postflight checks the exact private deletion ledger row and affected item, the matching Living Schedule operation and two grouped events, the source event and legacy link, the cursor and history watermark, and the baseline fingerprint. The rollback-only Worker runtime retains all deletion scenarios. Its collision probe now requires the unique violation on schedule_deletion_events_pkey specifically and compares its authorized audit history, root row and schedule cursor before and after the rejected call inside the transaction. The same owner postflight runs again after the Worker rollback, verifying that the committed collision remains and no other scoped schedule, graph or audit change persists.

All 44 focused tests, targeted ESLint, typecheck and git diff --check passed. The application build was skipped because this is a verification-only change. No database was accessed, no migrations ran, and no child was created. The corrected session sequence is prepared for an authorized isolated rehearsal. Live 0043 collision and runtime, 0044 cloning, and the four races remain unverified. Official Development remains **NO-GO**.

## 0043 owner setup passed; Worker collision seed stopped at a ledger read

Read-only preflight verified canonical Development project rapid-mud-63974868 and branch br-delicate-glitter-b6mj0051, all nine approved checksums, the baseline catalog and all six historical R00 rows. Native psql 18.7 delegated over TLS 1.3. The positive handoff probe rolled back and exited 0, and the deliberate SQL error returned SQLSTATE 22012 and exit 3. The sole disposable child was br-damp-pond-b659a0n2, named phase4b5-rehearsal-2385839ff5, with expiry 2026-11-23T16:40:19Z. Both Auth user requests returned HTTP 201, and the shared identity and reached child-safety gates passed. Migrations and stage fixtures ran in the documented order, with the storage-only postflight before 0037.

| Migration | Installation and in-file postflight | Fixture result |
|---|---|---|
| 0036 | PASS | PASS storage and privileges |
| 0037 | PASS | PASS confirmation, audit grouping and rollback |
| 0038 | PASS | PASS individual date guards |
| 0039 | PASS | PASS calendar apply |
| 0040 | PASS | PASS reversal, dependency conflict, audit and rollback |
| 0041 | PASS | PASS structure, four date operations and source events, four edges, activity creation and viewer denial |
| 0042 | PASS | PASS six edges, three date operations and source events, committed SQL postflight and full hierarchy runtime |
| 0043 | PASS | PASS corrected owner structure, two Worker date operations, owner audit assertions and all five edge confirmations. FAIL Worker collision seed. Deletion runtime NOT VERIFIED. |
| 0044 | NOT VERIFIED | NOT VERIFIED four clone cases, archived linked roots, remapping, source immutability and new R00/working-graph equivalence |

The 0042 SQL postflight verified exact typed endpoints, audit event versions, product cursors, history watermarks and the November 3–5 derived interval. The Worker hierarchy fixture then passed its reparent, November 11 earliest-start conflict, missing-boundary, viewer denial, and rollback assertions. The corrected 0043 structural seed committed the collision activity with its declared ID. Both 0043 stage-date commits and their owner source-event and cursor checks passed, and each of the five positive dependencies committed with its audited edge event.

The first unexpected failure was SQLSTATE 42501, `permission denied for table schedule_deletion_events`, at db/verification/phase4b3c3-schedule-deletion-seed-worker.sql:65. Native psql exited 3. The inline DO block failed at line 14 when its initial IF at source line 32 referenced the private ledger directly as jlproject_worker. The deletion preview, delete call and cursor advancement check were not reached. The session closed before COMMIT, and the failed transaction performed no persistent write. A subsequent static check found the same direct ledger read in the post-delete assertion at source line 54. Correcting the fixture will need to address both reads using the approved audit path or an authorized owner observer. No grant was added.

Post-stop checks confirmed that the Worker lacked direct graph-table access, private graph read/confirmation execute privileges and executor membership. Temporary owner SET and executor schema CREATE were absent. The checked-in read-only R00 file again verified six rows and fingerprint 9b6daa6196b11b3bee428a1d96fcd1c1. Clone cross-workspace isolation and complete-chain privileges remain NOT VERIFIED. The cycle, duplicate-edge, graph/date and calendar/graph races are each NOT VERIFIED. No contender session started and no pg_blocking_pids evidence was collected.

Cleanup reverified the child ID, project, parent, name, expiration and non-default status before deleting it. The follow-up lookup returned HTTP 404. Official Development access was read-only. Only this report changed, so application lint, typecheck, test and build were skipped.

**Technical NO-GO for official Development.** The remaining blocker is the 0043 collision fixture's private ledger access. The 0043 deletion runtime, 0044 clone verification and four races still require an authorized isolated run.

## 0043 collision activity variable corrected

The 0043 owner seed now uses `:'test_collision_activity'` in the INSERT for the synthetic root activity named `Committed collision history target`. Its existing gset declaration derives that ID from `md5('jlproject.phase4b3c3.collision_activity')`, and the Worker handoff already exports `test_collision_activity`. The prior INSERT used the undeclared `:'collision_activity'`, which caused SQLSTATE 42601 before the structural transaction could commit. The ID, row values, seed order and Worker handoff are unchanged.

The remaining SQL references and handoff values in the owner seed resolve to its declarations or the identity include. The focused contract verifies that the INSERT uses the same collision activity variable the owner hands to Worker. All 35 focused tests, targeted ESLint, typecheck and git diff --check passed. The application build was skipped because only verification files changed.

The correction is prepared for review. No database was accessed or branch created. The 0043 and 0044 runtime fixtures and the four concurrency races remain unverified. Official Development remains **NO-GO**.

## 0042 hierarchy passed; rehearsal stopped at the 0043 owner seed

Read-only preflight verified canonical Development project rapid-mud-63974868 and branch br-delicate-glitter-b6mj0051, all nine reviewed SHA-256 values, and the catalog prerequisites. Native psql 18.7 delegated through Neon over TLS 1.3 with verify-full for owner and Worker file probes. The checked-in handoff probe preserved all values and exited 0. Its deliberate SQL error returned SQLSTATE 22012 and exit 3. The historical R00 file matched the six rows and fingerprint 9b6daa6196b11b3bee428a1d96fcd1c1.

The only child created was br-plain-cake-b6ci2nt9, named phase4b5-rehearsal-c60e2fe5ee, with expiry 2026-11-20T08:10:39Z. Both branch-scoped Auth calls returned HTTP 201, and the existing identity and child-safety gates passed for the reached stages. The checked-in manifest launcher ran the 0041–0043 fixture handoffs. The 0036 storage postflight ran before 0037.

| Migration | Installation and in-file postflight | Fixture result |
|---|---|---|
| 0036 | PASS | PASS storage and privilege postflight |
| 0037 | PASS | PASS confirmation, audit grouping, stale and cycle rejection, and rollback |
| 0038 | PASS | PASS date-guard setup and Worker runtime |
| 0039 | PASS | PASS owner and Worker setup and calendar apply guards |
| 0040 | PASS | PASS reversal setup, dependency conflict, audit, cursor and rollback |
| 0041 | PASS | PASS owner structure, four audited stage-date transactions and source-event associations, edge confirmations, activity creation and viewer denial |
| 0042 | PASS | PASS owner structure, three audited stage-date operations, six edge confirmations, read-only SQL postflight and Worker hierarchy runtime |
| 0043 | PASS | FAIL owner structural seed. Worker date/setup, edge confirmations and deletion runtime NOT VERIFIED. |
| 0044 | NOT VERIFIED | NOT VERIFIED four clone cases, archived linked roots, endpoint remapping, graph/R00 equivalence and source immutability |

The 0042 read-only postflight printed its PASS line after ROLLBACK and exited 0. It checked all six typed endpoints, exact dependency-added audit events at versions 2/3 for the conflict product, 2 for the valid product, 5/6 for the fixed product and 2 for the root product, and cursors/history watermarks for all five products. It confirmed the conflict destination had null explicit dates and a November 3–5 derived interval. The three fixed-stage date operations and their exact source-event associations passed before those edges. The Worker fixture then completed and explicitly rolled back. Its assertions verified valid reparenting, a Finish-to-Start rejection with earliest successor start changing from November 6 to November 11, unchanged source row and cursor for the rejected move, the missing-boundary rejection, viewer denial, and rejection and state preservation for a second logical operation on the same product.

The first unexpected error was SQLSTATE 42601 at db/verification/phase4b3c3-schedule-deletion-seed-owner.sql:151, with native psql exit 3. The complete diagnostic was `syntax error at or near ":"`, pointing to the unresolved `:'collision_activity'` in line 15 of the activity INSERT. The seed's earlier SELECT into gset defines `test_collision_activity` at line 47. The INSERT uses a different name. This occurred before the seed's COMMIT at line 152. The activity statement failed as a unit and closing the session rolled back the open structural transaction. No deletion procedure response was reached. The post-stop probes independently checked historical R00 and privileges. No separate scoped row-absence query ran before cleanup.

Cycle prevention, duplicate-edge rejection, graph versus date, and calendar versus graph are each **NOT VERIFIED**. No contender sessions opened, so there is no pg_blocking_pids or race-based independent version-token evidence. Complete-chain security and clone cross-workspace checks were not reached.

Read-only post-stop checks confirmed that the Worker had no direct graph-table access, private graph-read or confirmation execute privileges, or executor membership. Temporary owner SET and executor schema CREATE were absent. All six historical R00 rows still matched the approved fingerprint. Cleanup reverified the child's project, parent, ID, name, expiry and non-default status, deleted it, and observed HTTP 404 on follow-up. Official Development access was read-only. Only this report changed. Lint, typecheck, application tests and build were skipped for this evidence-only update.

**Technical NO-GO for official Development.** Correct the 0043 local SQL variable reference before another authorized rehearsal. The 0043 runtime, full 0044 clone verification, and all four races remain outstanding.

## Checked-in 0042 post-confirmation assertions

The temporary wrapper's Check-42 called Single-Row with a pattern matching the STATE prefix through the JSON label. Single-Row returned a regex Match. Its Value ended at the closing label quote, so taking Substring(6) produced the partial object `{"label": "conflict"` instead of the full database row. ConvertFrom-Json threw locally after PostgreSQL had returned all four rows. Native psql had not reported a database error.

The existing seed checks remain in place. Each confirmation verifies its own typed edge and one dependency-added event before commit. The owner date setup verifies the exact three audited date operations, source-event associations and cursor increase before seeding edges. Those checks do not independently verify the complete committed graph and operation histories together.

The new phase4b3c2-hierarchy-move-postflight-owner.sql runs through the manifest launcher after all six edge commits and before the Worker hierarchy fixture. In one repeatable-read, read-only snapshot it checks every typed endpoint and exact edge event payload, operation identity, actor and version. It verifies five products, six graph rows, six dependency events and 14 expected operation rows, including the fixed product's three date operations. It checks each schedule cursor and history watermark against the expected committed history and verifies the conflict destination's November 3–5, 2026 derived interval. The result is the native psql exit status plus a readable success or failure message. PowerShell does not need to parse evidence JSON. The launcher keeps PostgreSQL evidence lines, suppresses Neon debug output at its source and redacts connection URI credentials in place.

Read-only catalog evidence confirmed neondb_owner already has SELECT on the schedule operation, event, state and source-event tables. A native psql 18.7 file-mode assertion over two harmless VALUES rows passed with explicit rollback and exit 0. A deliberate count mismatch raised SQLSTATE P0001 and exited 3. The checked-in postflight rejected a synthetic nonexistent fixture scope through the manifest launcher with the complete P0001 diagnostic and exit 3. The existing positive handoff probe through the launcher preserved every value over TLS 1.3 and rolled back with exit 0.

All 40 focused tests, targeted ESLint, typecheck and git diff --check passed. The application build was skipped for this verification-only change. No branch was created, no migration ran, and Development access was read-only. The positive postflight over committed 0042 fixture rows still requires an authorized isolated rehearsal. Official Development remains **NO-GO**.

## All six 0042 edges confirmed; rehearsal stopped before the hierarchy runtime

Read-only preflight verified native PostgreSQL psql 18.7, Neon delegation, TLS 1.3 with verify-full, and successful owner and Worker file-mode probes. The checked-in handoff probe preserved its mixed variable names and multiword value. Its deliberate SQL error returned SQLSTATE 22012 and exit 3. The canonical Development project rapid-mud-63974868 and branch br-delicate-glitter-b6mj0051 matched the runbook. All nine migration hashes matched. Dependency storage and the private confirmation routine were absent. The historical R00 file matched all six rows and fingerprint 9b6daa6196b11b3bee428a1d96fcd1c1.

The single disposable Development child was br-misty-sound-b646mqz6, named phase4b5-rehearsal-adfda6f840, with expiry 2026-11-20T08:01:18Z. Both synthetic Auth calls returned HTTP 201. The shared identity gate and reached child safety gates passed. The checked-in fixture launcher and manifest handled the 0041 and 0042 handoffs. The 0036 storage postflight ran before 0037 as required.

| Migration | Installation and postflight | Runtime fixture |
|---|---|---|
| 0036 | PASS | PASS storage and initial privileges |
| 0037 | PASS | PASS confirmation, audit grouping, stale and cycle rejection, and rollback |
| 0038 | PASS | PASS individual date guards |
| 0039 | PASS | PASS calendar apply |
| 0040 | PASS | PASS calendar reversal, audit and rollback |
| 0041 | PASS | PASS setup, four audited date changes and their source events, cursor checks, four edge confirmations, activity creation and viewer denial |
| 0042 | PASS | PASS structure, three audited stage-date operations and exact source-event associations, all six initial boundary checks and edge confirmations. FAIL in the transient post-confirmation readback parser. Hierarchy runtime NOT VERIFIED. |
| 0043 | NOT VERIFIED | NOT VERIFIED subtree deletion, preview, conflict rejection, audit and rollback |
| 0044 | NOT VERIFIED | NOT VERIFIED four clone cases, archived root remap, new R00 equality and source immutability |

Each 0042 edge committed separately. The seed helper checked the persisted graph endpoints and exactly one dependency-added audit event per confirmation. A subsequent read-only Worker query showed the following committed cursors and edge-event versions.

| 0042 product | Edge suffixes | Edge-event versions | Final cursor |
|---|---|---|---|
| Conflict | 0101, 0102 | 2, 3 | 3 |
| Valid move | 0103 | 2 | 2 |
| Fixed stages | 0104, 0105 | 5, 6 | 6 |
| Root move | 0106 | 2 | 2 |

The fixed product passed the exact three-operation stage-date audit gate at cursor 4 before its two edges. Independent readback confirmed the conflict destination stage had null explicit dates and derived November 3–5, 2026. The database returned all four post-confirmation readback rows. The agent's temporary PowerShell wrapper selected a row using a regex that matched only the JSON prefix through its label, then attempted to deserialize the match value. PowerShell returned `Invalid object passed in, ':' or '}' expected. (20): {"label": "conflict"`. This was a local evidence-processing error with no PostgreSQL SQLSTATE. No edge returned invalid. The run stopped before the Worker hierarchy runtime and the post-stop read-only query preserved the full rows. The automated before/after digest comparison did not complete. The November 10 proposed finish, November 11 earliest start, second conflict-product and missing_boundary scenarios, and rejected reparent state preservation remain NOT VERIFIED. A later evidence wrapper must identify rows without truncating them before JSON deserialization.

The four two-session races are individually NOT VERIFIED: cycle prevention, duplicate edge rejection, graph versus date, and calendar versus graph. No contender sessions were opened, so no pg_blocking_pids evidence or race-based version independence result exists.

Read-only post-stop checks confirmed no temporary owner SET membership, Worker executor membership, executor schema CREATE, direct Worker graph-table privilege, or Worker execute on private confirmation and read. The historical R00 check still matched all six rows. Full-chain privileges and clone workspace isolation remain NOT VERIFIED. Cleanup reverified the child project, parent, exact ID, name, expiry and non-default state before deletion. The follow-up branch lookup returned HTTP 404. Official Development access was read-only. Only this report changed. Application lint, typecheck, tests and build were skipped because this update records database verification rather than code changes.

**Technical NO-GO for official Development.** The six 0042 edge seeds passed. The 0042 runtime and remaining stages and races still require an authorized isolated rehearsal.

## 0042 fixture corrected to establish initial dependency boundaries

The first failed edge, `4b420000-0000-4000-8000-000000000101`, connects `test_conflict_destination_stage` to `conflict_destination_successor` in the conflict product. It is positive seed setup for a later rejected reparent. Its derived predecessor originally had effective interval `NULL–NULL`, and the successor derived `2026-11-06–2026-11-07` from its child. The three audited date updates are for a separate fixed-stage product, where the fixture covers explicit and partial D065 dates. An explicit interval on the conflict destination would prevent its derived finish from moving with its children and invalidate the conflict test.

All intervals in the table are in November 2026. Each edge is stage-to-stage in its own workspace/product scope.

| 0042 edge | Old predecessor → successor | Corrected predecessor → successor | Earliest successor start |
|---|---|---|---|
| 0101, conflict destination | null–null → 06–07 | 03–05 → 06–07 | 06 |
| 0102, conflict source | 03–10 → 09–10 | 03–10 → 11–12 | 11 |
| 0103, valid destination | null–null → 06–07 | 05–05 → 06–07 | 06 |
| 0104, explicit stage | 03–05 → 06–10 | 03–05 → 06–10 | 06 |
| 0105, partial stage | null–05 → 06–10 | null–05 → 06–10 | 06 |
| 0106, root scenario stage | null–null → 06–07 | 05–05 → 06–07 | 06 |

The owner seed adds one dated child to each of the three previously childless predecessors under its existing product-created operation and moves the conflict source successor child to November 11–12 so both conflict-product edges start valid. The same-parent reorder still checks that linked work can be reordered without date changes. Moving the November 9–10 activity would extend the destination to November 3–10 and raise its earliest successor start from November 6 to November 11. The runtime fixture requires that exact Finish-to-Start rejection and retains its row/cursor comparison. The valid move and its second-operation rollback probe keep the destination finish at November 5 even after the moved activity is removed. The root scenario first attempts to move the sole dated child to the root and requires missing_boundary. It then moves the separate existing root activity into the stage successfully.

The 0042 owner now checks all six edges with the installed D065 interval and first-working-start helpers while in the existing temporary executor context, before confirming any edge. The gate rejects missing, deleted, wrong-kind or out-of-scope endpoints through null boundary checks, and rejects a successor earlier than the first working day after its predecessor finishes. Three separately committed Worker stage-date operations, their exact source-event associations and the fixed product cursor delta of +3 are unchanged. No extra logical schedule operation or new Worker grant is needed.

The targeted review found all five 0043 positive edges in scope. Its activity pair and four derived stage pairs have predecessor finish November 5 and successor start November 6. The sole-child deletion case loses its boundary only during the negative runtime probe. The separate fixed and partial stage dates are set by the two existing Worker operations before confirmation. For 0044, Vigente and Arquivado each seed a November 12 → 13 root activity edge, a November 2 → 3 imported activity edge, and a D1-S3 → D2-S1 derived stage edge (November 6–9 → November 10–11). The Em estudo source has the November 2 → 3 and November 4 → 5 imported activity pairs and the same derived stage pair. November 2 is a national holiday, but the manually imported predecessor retains that date and its earliest allowed successor start is November 3. All nine edges use endpoints selected within the same workspace and product, and the approved source date/working-plan setup precedes edge confirmation. The study and archive transitions follow confirmation. The empty source has no edge. No 0043 or 0044 edge seed changes were needed based on this static review.

All 54 focused tests passed, including static boundary checks against the 0042 and 0043 seed rows and the relevant migration, handoff and execution-order contracts. Targeted ESLint, typecheck and git diff --check passed. The application build was skipped because only verification fixtures, tests and this record changed.

The corrected fixtures require live verification on the next authorized disposable child. No branch was created and no database or migration ran in this preparation. Official Development remains **NO-GO**.

## Rehearsal stopped at the first 0042 hierarchy edge

Read-only preflight confirmed the ready Development branch `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`, database `neondb`, and all nine approved SHA-256 values. The catalog showed the expected baseline, including absent dependency storage and confirmation routine, six empty R00 dependency arrays, and the immutable R00 trigger. Native psql 18.7 delegated through Neon over TLS 1.3 with `verify-full` as owner and Worker. The file probes verified variable expansion, conditional execution, includes and gset, and both sessions rolled back with exit 0. The checked-in handoff probe preserved all mixed-name values and the full multiword target. Its deliberate error returned SQLSTATE `22012` and exit 3. The historical R00 file matched six rows and fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`.

The single disposable child was `br-restless-tree-b6vagoxf`, named `phase4b5-rehearsal-08fbac8f04`, with expiry `2026-11-20T07:47:18Z`. Both synthetic Auth API calls returned HTTP 201. The shared owner identity gate matched both issued UUIDs to their branch-specific identities, and the seed safety gates passed through the executed stages. The 0036 storage fixture ran immediately after 0036.

| Migration | Install and in-file postflight | Runtime and fixture status |
|---|---|---|
| 0036 | PASS | PASS storage and initial privileges |
| 0037 | PASS | PASS confirmation, audit grouping, stale and cycle rejection, and rollback |
| 0038 | PASS | PASS individual Activity and D065 date guards |
| 0039 | PASS | PASS calendar setup and apply guards |
| 0040 | PASS | PASS calendar reversal setup, conflict, successful reversal audit and rollback assertions |
| 0041 | PASS | PASS owner setup, four direct Worker stage-date transactions, owner source-event/cursor assertions, four edge confirmations, activity creation and viewer denial |
| 0042 | PASS | PASS owner structure, three direct Worker stage-date transactions, and owner source-event/cursor assertions. FAIL on first edge confirmation. Remaining edge confirmations and hierarchy runtime NOT VERIFIED. |
| 0043 | NOT VERIFIED | NOT VERIFIED deletion setup, source-event audit, and runtime |
| 0044 | NOT VERIFIED | NOT VERIFIED Vigente, Em estudo, Arquivado and empty-graph clones, archived root remap, source immutability, and working graph/R00 equivalence |

The 0040 fixture observed `dependency_conflict` with `finish_to_start` on edge `4b400000-0000-4000-8000-000000000201`. The reversal would move the earliest permitted successor start from November 12 to November 16 while the successor remained on November 12. The 0041 owner gate committed its audit assertion transaction after verifying four exact stage-date source-event associations and cursor advances. The corresponding 0042 audit assertion transaction also committed. It verified three exact associations and the fixed-product cursor change from 1 to 4 before edge setup.

The first unexpected error was SQLSTATE `P0001` at `db/verification/phase4b5-seed-one-dependency.sql:93`, inline block line 51: `Audited dependency fixture setup did not create exactly one edge event: {"status": "invalid"}`. Native psql exited 3. The parent file was `phase4b3c2-hierarchy-move-seed-owner-dependencies.sql`, attempting stage edge `4b420000-0000-4000-8000-000000000101` from `test_conflict_destination_stage` to `conflict_destination_successor`. The handoff supplied both endpoint IDs. The structural fixture creates the predecessor with both explicit dates null and gives it no child. The successor has a dated child. The reviewed 0037 confirmation function requires a derived predecessor to have a child finish date at edge creation. The first edge fails that prerequisite before the insert or audit write. The 0042 stage-date transactions updated the separate fixed product, so those changes cannot provide this predecessor's finish. The valid and root scenario predecessor stages also appear in the seed as undated and childless at edge creation. Those later cases were not executed.

The failed edge transaction closed on error. The separate read-only post-stop checks confirmed absence of temporary owner SET membership, Worker executor membership, executor schema CREATE, direct Worker graph access, and Worker access to the private confirmation and graph-read functions. The checked-in historical R00 file again matched all six rows and the approved fingerprint. No independent post-stop query of that edge's audit rows or product cursor was run. Complete-chain privilege checks remain NOT VERIFIED.

| Two-session race | Status |
|---|---|
| Cycle prevention | NOT VERIFIED |
| Duplicate edge rejection | NOT VERIFIED |
| Graph versus date | NOT VERIFIED |
| Calendar versus graph | NOT VERIFIED |

No contender sessions were started, so there is no `pg_blocking_pids` evidence or race-based independent version token result. Cleanup reverified the child's project, parent, name, exact ID, expiry and non-default status, deleted it, and received HTTP 404 on the follow-up lookup. Official Development was accessed read-only. Only this report changed. Application lint, typecheck, tests and build were skipped for the report-only update.

**Technical NO-GO for official Development.** Review how the 0042 fixture establishes the predecessor finish required by edge confirmation while preserving the intended move scenarios. The remaining stages and four races require a new authorized isolated rehearsal.

## Variable handoff and historical R00 verification prepared

The previous runner tokenized each seed's output and retained only names matching a prefix filter and a few clone aliases. The 0041 owner correctly emitted fixed_successor_stage and violation_successor_stage. The filter rejected both, leaving the first unresolved psql reference at line 12 of the Worker stage-date file. The 0042 and 0043 owner seeds now also print the successor endpoint IDs their owner edge sessions consume. The 0043 seed additionally prints test_valid_dependency, which its edge session already referenced. These changes expose values already generated in the seeds. Fixture data and write statements are unchanged.

The checked-in 0041–0044 handoff manifest lists exact caller inputs, seed exports, roles and types. The PowerShell launcher validates those names and values before connecting. Its seed-output mode accepts the declared assignment lines and fails on missing or repeated lines or incorrect assignments. The launcher passes an array of separate -v arguments and executes the approved SQL with -f. The runbook documents the per-stage handoffs, clone record mapping and session boundaries.

The live read-only native psql 18.7 probe used Neon TLS 1.3 with verify-full. It returned all three distinct synthetic UUIDs unchanged, including both successor variable names, and the full multiword clone target name. The transaction explicitly rolled back and the positive run exited 0. A separate deliberate SQL error returned SQLSTATE 22012 and process exit 3. Missing fixed_successor_stage, an unexpected name, a malformed violation_successor_stage value and a duplicate fixed_successor_stage were rejected in PowerShell before psql launch. The temporary public CA bundle was removed.

The historical R00 check now runs from a checked-in SQL file instead of the multiline -c argument that produced SQLSTATE 42703. In a read-only Development session it verified exactly six rows and the approved fingerprint 9b6daa6196b11b3bee428a1d96fcd1c1, explicitly rolled back, and exited 0. After clone setup the same check excludes only the verified synthetic clone workspace. The existing clone postflight still verifies the total count and clone R00 graph independently.

All 29 focused tests passed across the handoff, Windows PowerShell, execution-order and deterministic seed suites. The local PowerShell process test confirmed exit 1 for missing assignments without resolving a CLI. Targeted ESLint, TypeScript typecheck and git diff --check passed. The application build was skipped because this change is limited to verification tooling, fixture output and documentation.

No branch was created, and this preparation did not execute migrations or write database data. The remaining fixture and concurrency results stay **NOT VERIFIED**. The handoff correction is prepared for another authorized isolated rehearsal. Official Development remains **NO-GO**.

## Corrected native probe passed, rehearsal stopped at the 0041 argument handoff

The temporary PowerShell probe now writes each SQL file from a literal here-string and compares the saved contents with the expected text before execution. Owner and direct Worker runs both used native psql 18.7 through Neon with TLS 1.3 and `verify-full`. Each returned `included_ok=1`, `probe_result=harmless-included`, read-only mode `on`, an explicit `ROLLBACK`, and exit 0. The separate deliberate division by zero ran after explicitly closing its read-only transaction and returned SQLSTATE `22012` with exit 3. The temporary files and CA bundle were removed.

The official Development branch was `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`. The catalog and nine reviewed SHA-256 values matched. Read-only checks found six historical R00 rows with fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`, no dependency storage and no temporary executor privileges. The only child created was `br-misty-cherry-b638go14`, named `phase4b5-rehearsal-bc49a9ecde`, with expiration `2026-11-20T07:30:24Z`. Both child Auth API calls returned HTTP 201, and the shared read-only identity preflight matched both issued UUIDs to the branch-specific email addresses. The 0036 storage-only check ran before 0037.

| Migration | Commit and in-file postflight | Runtime fixture |
|---|---|---|
| 0036 | PASS | PASS (storage and initial grants) |
| 0037 | PASS | PASS (confirmation, audit and rollback) |
| 0038 | PASS | PASS (individual date guards) |
| 0039 | PASS | PASS (calendar apply) |
| 0040 | PASS | PASS (calendar reversal) |
| 0041 | PASS | FAIL (Worker seed argument handoff after owner structural setup committed). Stage-date source assertions, activity creation and viewer denial NOT VERIFIED. |
| 0042 | NOT VERIFIED | NOT VERIFIED (hierarchy moves and three source-event associations) |
| 0043 | NOT VERIFIED | NOT VERIFIED (subtree deletion and two source-event associations) |
| 0044 | NOT VERIFIED | NOT VERIFIED (all clone scenarios, source integrity and R00 graph equivalence) |

The 0040 fixture returned `dependency_conflict` with `finish_to_start` for edge `4b400000-0000-4000-8000-000000000201`. The proposed reversal raised the earliest successor start from November 12 to November 16 while the successor remained on November 12. Its assertions for rejected-state preservation and successful reversal audit and cursor advancement passed.

The first unexpected SQL error was SQLSTATE `42601` at `phase4b3c1-activity-creation-seed-worker-stage-dates.sql:12`. The error pointed to the unresolved `:'fixed_successor_stage'` in the initial `set_config` statement, and psql exited 3. The owner seed emits both `fixed_successor_stage` and `violation_successor_stage`. The temporary runner retained `test_*` and selected other keys, dropping both successor-stage arguments because they lack the `test_` prefix. This error occurred before the first audited Worker operation or its transaction. The separately committed owner structural setup had succeeded. The next runner should validate the full set of required variable names against the seed output, including names without the `test_` prefix, before starting psql.

The cleanup catalog query confirmed no temporary owner SET membership, no Worker executor membership, no executor schema CREATE, no direct Worker graph-table privileges and no Worker execution of private confirmation. Earlier owner fixtures passed their historical R00 assertions. The independent post-stop R00 query itself failed with SQLSTATE `42703` (`column "r" does not exist`) because its multiline SQL was truncated when passed via `-c`. The post-stop R00 fingerprint and full rollback-state comparison are **NOT VERIFIED**. Final security after 0044 and the cycle, duplicate-edge, graph/date and calendar/graph races are **NOT VERIFIED**. No contention or independent token evidence was collected in this run.

Cleanup rechecked the project, child ID, parent, name, expiration and non-default state before deletion. Neon returned HTTP 404 on the follow-up lookup for that child. Official Development was accessed read-only. This run changed only this verification record, so application lint, typecheck, tests and build were skipped.

**Technical NO-GO for official Development.** The next authorized rehearsal must verify the 0041 argument handoff, remaining fixtures, final catalog and R00 evidence, and all four races.

## Rehearsal stopped at the native psql probe

Neon returned HTTP 200 for the ready `development` branch `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`. The local SHA-256 values for 0036–0044 all matched the reviewed table in this report. Native PostgreSQL psql 18.7 was present. The Neon CLI reported native launch with `--ssl verify-full`. The owner session connected to `neondb` as `neondb_owner`, reported TLS 1.3, and began a read-only transaction.

The temporary file-mode probe failed at line 7 with SQLSTATE `42601`, `syntax error at or near ":"`. PostgreSQL showed the malformed statement `SELECT 1 / (:`. PowerShell split the assertion into two array items because the concatenation expression in the array lacked parentheses. Native psql stopped with exit 3 under `ON_ERROR_STOP=1`. This was a probe construction error. The read-only connection closed with its transaction open, so PostgreSQL discarded that transaction. No migration or fixture ran. The current run did not reach the direct Worker probe, the separate deliberate error probe, or the Development catalog comparison. The temporary probe and CA files were removed. No disposable child was created, so there was no branch to delete.

| Migration | Installation | Runtime fixture |
|---|---|---|
| 0036 | NOT VERIFIED | NOT VERIFIED (storage) |
| 0037 | NOT VERIFIED | NOT VERIFIED (confirmation and rollback) |
| 0038 | NOT VERIFIED | NOT VERIFIED (individual date guards) |
| 0039 | NOT VERIFIED | NOT VERIFIED (calendar apply) |
| 0040 | NOT VERIFIED | NOT VERIFIED (calendar reversal) |
| 0041 | NOT VERIFIED | NOT VERIFIED (four source associations, activity creation and viewer denial) |
| 0042 | NOT VERIFIED | NOT VERIFIED (three source associations and hierarchy moves) |
| 0043 | NOT VERIFIED | NOT VERIFIED (two source associations and subtree deletion) |
| 0044 | NOT VERIFIED | NOT VERIFIED (all four clone cases and clone R00) |

Cycle, duplicate, graph versus date, and calendar versus graph are each **NOT VERIFIED**. No contending sessions ran. Independent token checks, Worker least privilege, temporary grant cleanup assertions, and historical R00 comparison were also **NOT VERIFIED** in this run. Application lint, typecheck, tests, and build were skipped for this report-only change.

**Technical NO-GO for official Development.** The native file-mode gate must pass with the assertion written as a single literal line, followed by the full isolated run.

## Audited stage-date rehearsal stopped at read-only preflight

Neon CLI 9.7.2 confirmed project `rapid-mud-63974868` and its ready `development` branch `br-delicate-glitter-b6mj0051`. Native psql 18.7 passed owner and direct Worker read-only file probes with `--ssl verify-full` and a temporary Node public-root CA bundle. Both returned exit 0 and printed `probe_result=harmless-included`, confirming variable expansion, conditional flow, includes and `gset`. Client `conninfo` confirmed TLS 1.3. The deliberate SQL error returned SQLSTATE `22012` and exit 3. All nine SHA-256 values matched the reviewed migrations. Dependency storage and private confirmation were absent, as were temporary owner SET and executor schema CREATE privileges and Worker executor membership. The six historical R00 rows matched `9b6daa6196b11b3bee428a1d96fcd1c1`. Their dependency arrays were empty and the immutability trigger was enabled.

The 0041 owner audit gate requires four legacy `product_schedule_operation_links` rows for standalone Worker stage-date updates. The live `discipline_stages_dates_audited` BEFORE trigger inserts the stage-date ledger record. The nondeferrable `stage_date_changes_schedule_link` AFTER INSERT trigger fires inside that nested insert, before `discipline_stages_schedule_audit` creates the Living Schedule operation. `link_product_schedule_audit_source()` returns when it finds no operation. The later `product_schedule_operation_events_source_links` trigger matches the stage-date ledger record to the operation and writes `product_schedule_operation_source_events`. Migration 0037 explicitly writes legacy links for confirmed cascades. The seed calls the individual date writer, so the cascade path does not run. The 0042 and 0043 owner gates make the same legacy-table assumption.

The expected fixture failure is SQLSTATE `P0001` at the 0041 audit assertion, “Expected one stage event and one Living Schedule audit link for each audited stage-date operation.” This expectation comes from the installed definitions and migration sources. No fixture SQLSTATE, response payload or rollback was observed in this attempt. The proposed fixture correction is to verify the source-event link by workspace, product, operation ID, schedule version and the stage-date ledger event ID, retaining all date, actor, reason, transaction and cursor assertions.

| Migration | Installation | Runtime fixture |
|---|---|---|
| 0036 | NOT VERIFIED | NOT VERIFIED — storage postflight |
| 0037 | NOT VERIFIED | NOT VERIFIED — confirmation and rollback |
| 0038 | NOT VERIFIED | NOT VERIFIED — individual date guards |
| 0039 | NOT VERIFIED | NOT VERIFIED — calendar application |
| 0040 | NOT VERIFIED | NOT VERIFIED — calendar reversal |
| 0041 | NOT VERIFIED | NOT VERIFIED — activity creation and owner audit gate |
| 0042 | NOT VERIFIED | NOT VERIFIED — hierarchy moves |
| 0043 | NOT VERIFIED | NOT VERIFIED — subtree deletion |
| 0044 | NOT VERIFIED | NOT VERIFIED — four clone scenarios, source immutability and graph/R00 equivalence |

Cycle, duplicate-edge, graph versus date and calendar versus graph races, along with independent version-token checks, are **NOT VERIFIED**. No two-session blocking evidence was collected. Runtime authorization, clone remapping and audit/cursor results remain **NOT VERIFIED**. No child was created, so branch deletion was unnecessary. Temporary probe files and the public CA bundle were removed. Application lint, typecheck, build and tests were skipped because this attempt only adds a verification record.

**Technical NO-GO for official Development.** Correct and review the fixture assertions before isolated execution.


**2026-11-19 · NO-GO for official Development.** All nine migrations committed again. Calendar apply and reversal and activity creation passed. Integration stopped in the hierarchy audit collision fixture.

## Read-only Development evidence

- Neon returned project `rapid-mud-63974868`, branch `br-delicate-glitter-b6mj0051` (development, ready). The catalog session connected to `neondb` as `neondb_owner` with TLS `verify-full` and confirmed `transaction_read_only = on`.
- The dependency table and the dependency functions and triggers introduced by the prepared chain were absent. The product, stage and activity tables had the validated scoped keys needed by the edge foreign keys. The catalog showed six historical R00 rows, all with empty dependency arrays, and an enabled immutability trigger.
- The calendar apply function was owned by `jlproject_date_executor`, was `SECURITY DEFINER`, and granted execution to `jlproject_worker`. Its full definition had MD5 `6443b5bc00237cd856e3a60095bff5ea`. The executor roles lacked public-schema CREATE. The `cloud_admin` memberships for `neondb_owner` in the Worker, date executor and calendar executor roles had ADMIN enabled and INHERIT and SET disabled. The Worker had no date executor membership or direct UPDATE privilege on schedule dates or R00 columns.
- Exact function definitions and ACLs were fetched from `pg_proc`. The named source anchors checked on the installed individual date, reversal, creation, move, deletion and clone functions were present. Calendar apply's write-loop and end-date anchors each matched once. Its stale-check anchor matched zero times.

## Corrected source anchors

Migration `0039` now expects the two nullable planning fields using their installed null-safe comparisons.

```sql
       v_activity.working_day_duration IS DISTINCT FROM (v_item->>'workingDays')::integer OR
       v_activity.planning_calendar_version IS DISTINCT FROM (v_item->>'savedCalendarVersion')::bigint OR
```

The stale-check anchor retains the same null-safe semantics in both its expected source and replacement text. A fresh read-only Development query confirmed that the installed definition has these expressions. The write-loop, stale-check, and proposed-end anchors each match once in the installed function after the preceding `0038` call replacement. The active product lock and private reviewed-writer call are present, and no calendar dependency guard is already installed. The preflight source mismatch is resolved. [0039 anchor and guard](../../db/migrations/0039_guard_calendar_reschedule_apply.sql#L85) · [0038 replacement](../../db/migrations/0038_guard_individual_schedule_dates.sql#L178)

## Initial rehearsal attempt

| Migration | Result |
| --- | --- |
| 0036 | Not run |
| 0037 | Not run |
| 0038 | Not run |
| 0039 | Not run. Prior anchor blocker corrected and live source rechecked |
| 0040 | Not run |
| 0041 | Not run |
| 0042 | Not run |
| 0043 | Not run |
| 0044 | Not run |

No disposable branch was created, so no cleanup was required. PostgreSQL fixtures, two-session concurrency, confirmed cascade and rollback, post-migration privilege and audit checks, and clone/R00 equivalence remain pending. The historical R00 checks above apply to the current Development baseline. Lint, typecheck and build were skipped because this checkpoint only corrected a migration source anchor and its focused contract test.

The isolated rehearsal may proceed after approval of this correction. Official Development execution requires separate approval after a successful rehearsal.

## Resumed isolated rehearsal

The resumed read-only preflight confirmed the official Development branch `br-delicate-glitter-b6mj0051` in project `rapid-mud-63974868`, database `neondb`. The scoped keys and R00 constraint matched, and dependency storage and routines were absent. The source replacement checks matched in sequence, including the `0038` writer substitution before `0039`. The SHA-256 for `0039` was `B5566A30E4445F6B969C6BEAB6F6599600C014F68730B1085E823A674A72E876`.

All execution used `ON_ERROR_STOP=1` on child `br-autumn-lab-b689y6b7`, named `phase4b5-dependency-rehearsal-1795104166636`. Neon identified the branch as a non-default child of Development, with expiration `2026-11-19T20:02:55Z`.

| Migration | Child result |
| --- | --- |
| 0036 | Committed. Dependency table owned by `neondb_owner`. Worker edge table access denied. |
| 0037 | Committed. Date executor owns the read, confirm and receipt routines. Worker EXECUTE denied. |
| 0038 | Committed. Existing date writers and private guards had expected owner and Worker EXECUTE privileges. |
| 0039 | Committed. Calendar apply remained callable by the Worker and its guard remained private. Apply definition MD5 `3c7b5c0abd279e58f20e935dde83c3c3`. |
| 0040 | Committed. Calendar reversal remained callable by the Worker and the shared guard remained private. Reversal definition MD5 `8fa830b76afa0f1ac820266ba9c945d7`. |
| 0041 | Failed and rolled back at line 190. |
| 0042 | Blocked by 0041. |
| 0043 | Blocked by 0041. |
| 0044 | Blocked by 0041. |

Postflight queries after each commit confirmed temporary executor access was gone and the Worker had no direct edge table privileges. At `0041`, PostgreSQL returned `permission denied for function guard_activity_creation_before_insert`. The failed migration attempted to grant EXECUTE after resetting to `neondb_owner`, without the function owner's authority. A subsequent read-only query confirmed that both creation guard functions and the trigger were absent and the temporary role and schema privileges had rolled back. The prepared correction grants the privilege under the function owner role [before resetting](../../db/migrations/0041_guard_activity_creation_dependencies.sql#L187).

Official Development and the child had matching fingerprints for all six historical R00 rows (`423891da1ff2d4b32fbc1316a794e2df`), products, disciplines, stages, activities, audit operation headers and schedule cursor state. Development still had no dependency table. The integration fixtures, confirmed cascades, concurrent writes, runtime audit grouping and clone/R00 equivalence were blocked by `0041`. The migration transaction rollback was verified. The prior focused `0039` tests remain the applicable local test result. No new local tests, lint, typecheck or build ran because this attempt made no code changes.

Neon accepted deletion of the verified disposable child at 16:05 UTC. A subsequent branch listing confirmed the child was absent and the official Development branch was present.

## Migration 0041 grant correction prepared

The failed `GRANT EXECUTE` followed `RESET ROLE`, so its grantor was `neondb_owner`, while the trigger function was owned by `jlproject_date_executor`. The owner's membership with `SET TRUE` permits switching into the executor role; it does not make `neondb_owner` the function owner or grantor while its current role is reset. The same authority issue applied to the post-trigger revokes, which also ran as `neondb_owner`.

The prepared correction grants temporary EXECUTE on only `guard_activity_creation_before_insert()` while `jlproject_date_executor` is current, resets to `neondb_owner` to create the trigger, then switches back to the function owner to revoke the temporary grant and any owner grant on the private dependency helper. It resets again before removing temporary schema CREATE and role membership. Postflight now verifies that neither `jlproject_worker` nor `neondb_owner` can execute either guard. The private helper is never granted to `neondb_owner` or the Worker; only the trigger function receives the short-lived grant needed for trigger creation.

This source correction has not been applied to a database. The failed child was deleted after the rollback was verified; no replacement branch or migration execution has occurred. Focused migration contract tests and `git diff --check` are the local verification for this correction. The isolated rehearsal may be repeated after review; official Development remains NO-GO pending that rehearsal and separate authorization.

## Resumed rehearsal after 0041 correction

Fresh read-only preflight connected to project `rapid-mud-63974868`, Development branch `br-delicate-glitter-b6mj0051`, database `neondb`, as `neondb_owner`; `transaction_read_only` was `on`. Migration prerequisites matched: the dependency table and Phase 4B routines were absent, temporary executor membership and schema `CREATE` were absent, and the six R00 rows retained their empty dependency arrays and immutability trigger. The corrected `0041` SHA-256 matched the approved `385250D8ADA2BB9369DD561A4BC5E102F1F662A56A562C435D0AC5F48EB54998`. Role statements in 0042–0044 were reviewed; no matching owner-context grant/revoke defect was found.

The disposable child `br-young-voice-b6hjx7xc` (`phase4b5-0041-rehearsal-20261119-1619`) was created from the verified Development branch, marked non-default, and set to expire at `2026-11-19T22:30:00Z`. Each migration used `ON_ERROR_STOP=1` as `neondb_owner`.

| Migration | Result |
| --- | --- |
| 0036 | Committed. Read-only storage postflight passed; dependency table empty and inaccessible to Worker/date executor. |
| 0037 | Committed. Read/confirm routines owned by `jlproject_date_executor`; Worker and PUBLIC EXECUTE denied; executor privileges cleaned. |
| 0038 | Committed. Date guards and reviewed writers had expected owners, fixed search paths and private EXECUTE; Worker date-column updates denied. |
| 0039 | Committed. Calendar apply callable by Worker, guard private; apply definition MD5 `3c7b5c0abd279e58f20e935dde83c3c3`. |
| 0040 | Committed. Calendar reversal callable by Worker, shared guard private; reversal definition MD5 `8fa830b76afa0f1ac820266ba9c945d7`. |
| 0041 | Committed. Corrected grant/revoke sequence succeeded. Trigger enabled; both creation guards owned by the executor and not executable by Worker or `neondb_owner`; temporary membership/schema privilege cleaned. |
| 0042 | Committed. Reparent guard owned by executor and private; move writer remained Worker-callable; temporary privileges cleaned. |
| 0043 | Failed at its postflight with `Schedule deletion dependency guard privileges or writer integration are incorrect.` The transaction rolled back: both deletion guard functions are absent and executor membership/schema `CREATE` are absent. No migration retry or repair was attempted. |
| 0044 | Not run; blocked by 0043. |

Rollback verification compared Development with the child. Counts and full-row fingerprints matched for products (7), disciplines (40), stages (99), activities (191), activity audit events (18), stage audit events (4), operation headers (9), schedule cursors (7), and R00 snapshots (6). The R00 full-row fingerprint was `2edd50b7cb5176016287c3d8379c4c3b`; the ID/snapshot fingerprint was `4844ddc1c79842775503e32a5ac0383f`. All six snapshots still had empty dependency arrays. The failed migration's generic postflight did not identify which predicate failed; database integration fixtures, concurrent mutations, audit grouping and clone/R00 dependency equivalence were therefore not run.

The verified disposable child was deleted after preserving this evidence; Neon returned `404 branch not found` on verification, and the official Development branch remained ready. The Development database was queried read-only only; no migration was applied there. The project branch-list response used for the unique child-name check included Production branch metadata, but no Production endpoint connection or database query was made. **NO-GO for official Development:** migration 0043's postflight blocker must be diagnosed and separately reviewed before a fresh full-chain rehearsal. Migration 0044 and all Worker integration fixtures remain unverified.

## Migration 0043 postflight diagnosis

The saved migration output proves 0043 passed its preflight and source-install blocks, created both deletion guard functions, performed the temporary privilege cleanup statements, and then raised from the final postflight `DO`. The exception did not identify which OR term failed. The failed transaction rolled back and the disposable child was subsequently deleted, so no installed 0043 function definitions or postflight privilege state remain available. The earlier preflight and 0042 postflight confirm their checked baseline conditions, but they cannot establish the post-0043 function-body or privilege results.

The original generic postflight combined these 15 assertions: `dependency_stage_interval_after_deletion_owner`, `guard_schedule_deletion_dependencies_owner`, `preview_calls_deletion_guard`, `delete_calls_deletion_guard`, `delete_takes_workspace_lock`, `worker_cannot_execute_deletion_guard`, `worker_cannot_execute_stage_interval_helper`, `worker_can_execute_preview`, `worker_can_execute_delete`, `worker_cannot_update_activity_deleted_at`, `worker_cannot_update_stage_deleted_at`, `worker_cannot_update_discipline_deleted_at`, `worker_is_not_date_executor_member`, `owner_cannot_set_date_executor`, and `date_executor_has_no_public_create`. Available evidence does not isolate which assertion(s) caused the failure.

Migration 0043 is prepared with diagnostic-only postflight reporting: it retains every assertion, treats indeterminate Boolean results as failures, and includes all failed assertion names in the exception `DETAIL`. No deletion behavior, grants, or authorization checks were relaxed. SHA-256: `8135E8E9EFC389FF4A47F2106C084605E4FD22E64E01A7AE1BCBC227581BA983`. Focused verification passed: `tests/migration-0043.test.ts` (6/6) and `git diff --check`. At that checkpoint, the exact cause remained unconfirmed; the recommended next step was a fresh disposable child, apply 0036–0042 and diagnostic 0043, then capture `DETAIL` and stop without applying 0044. No Neon branch or database was accessed during that earlier diagnosis.

## 0043 isolated diagnostic run

The approved 0043 checksum matched `8135E8E9EFC389FF4A47F2106C084605E4FD22E64E01A7AE1BCBC227581BA983`. Fresh read-only Development preflight confirmed the target branch was ready, `neondb` was reached as `neondb_owner` with read-only mode enabled, the dependency schema/functions were absent, and temporary executor privileges were clean. Child `br-bold-leaf-b6backtn` (`phase4b5-0043-diagnostic-20261119-1653`) was a verified non-default child of Development, expiring at `2026-11-19T20:55:00Z`.

| Migration | Result |
| --- | --- |
| 0036 | Committed; read-only storage postflight passed. |
| 0037 | Committed; internal postflight passed. |
| 0038 | Committed; internal postflight passed. |
| 0039 | Committed; corrected source anchors matched. |
| 0040 | Committed; internal postflight passed. |
| 0041 | Committed; corrected role transition and postflight passed. |
| 0042 | Committed; hierarchy guard and postflight passed. |
| 0043 | Rolled back at postflight. 0044 was not run. |

Verbose PostgreSQL output captured the exact failure:

```text
SQLSTATE: P0001
MESSAGE: Schedule deletion dependency guard postflight failed.
DETAIL: delete_calls_deletion_guard
CONTEXT: PL/pgSQL function inline_code_block line 53 at RAISE
LOCATION: exec_stmt_raise, pl_exec.c:3925
```

The failed assertion is a false direct-call expectation. The migration injects `public.guard_schedule_deletion_dependencies(...)` into `preview_schedule_deletion`, then injects the `dependency_conflict` handling into `delete_schedule_subtree`, which calls the preview. It does not inject the guard call directly into the delete function. The postflight correctly checks that the preview calls the guard, but `delete_calls_deletion_guard` incorrectly also requires the delete function's definition to contain that direct call.

Read-only catalog checks after rollback confirmed both new deletion guard functions were absent, the date-executor membership and public-schema `CREATE` privilege were absent, and the original `delete_schedule_subtree` remained owned by `jlproject_date_executor` with MD5 `58dd6f62a53000a31911da8f75786d64`. Its definition contained the existing call to `preview_schedule_deletion` and the pre-migration status anchor, and did not contain a direct deletion-guard call. This matches the migration's intended indirect validation path and confirms the failure was the postflight assertion, not a function ownership or grant-order error.

Recommended minimal correction: replace `delete_calls_deletion_guard` with an assertion that `delete_schedule_subtree` still calls `preview_schedule_deletion` and handles a returned `dependency_conflict`; retain `preview_calls_deletion_guard` to verify the preview performs the actual check. No migration files were changed and no retry was attempted in this diagnostic task. The isolated child was deleted after recording this evidence; Development remains unchanged. **NO-GO for further chain testing until the assertion correction is separately approved and a new isolated run confirms 0043.**

## Migration 0043 postflight assertion correction prepared

The confirmed false direct-call assertion has been replaced. The postflight still requires `preview_schedule_deletion` to call `guard_schedule_deletion_dependencies`; it now requires `delete_schedule_subtree` to call that preview and verifies its dependency-conflict branch checks the fingerprint and returns the conflict before the audit insert and all three schedule-row updates. All other ownership, Worker permission, privilege-cleanup and integrity assertions remain in place. No database function body or deletion behavior was changed.

The focused test now covers these named assertions and their order relative to the audit and schedule writes. `tests/migration-0043.test.ts` passed (6/6), and `git diff --check` passed. Updated migration SHA-256: `FBE35B36EBAE927DDB4CE2A56B243CDCCCA7381C4C775A9809866808F1B21CD2`. The corrected migration has not been executed; it is prepared for review before another isolated rehearsal.
## Complete-chain isolated rehearsal

Read-only preflight verified project `rapid-mud-63974868`, Development branch `br-delicate-glitter-b6mj0051`, database `neondb`, and the prerequisite catalog. Approved 0043 SHA-256 matched `FBE35B36EBAE927DDB4CE2A56B243CDCCCA7381C4C775A9809866808F1B21CD2`. The only migration target was verified non-default child `br-mute-waterfall-b60z5swp`, expiring at 23:15 UTC. Each file ran with `ON_ERROR_STOP=1` and committed.

| Migration | PostgreSQL evidence |
| --- | --- |
| 0036 | Storage fixture passed. `neondb_owner` owns the edge table. |
| 0037 | Read, receipt and confirmation routines are executor-owned and private. |
| 0038 | Date writers are Worker-callable. Guards and reviewed writers are private. |
| 0039 | Calendar apply is Worker-callable. Its dependency helper is private. |
| 0040 | Calendar reversal is Worker-callable. Its dependency helper is private. |
| 0041 | The creation trigger and owner grant cleanup passed postflight. The Worker can call the existing creation writer. |
| 0042 | Hierarchy move is Worker-callable. The reparent helper is private. |
| 0043 | Corrected postflight passed. Preview and delete remain Worker-callable, and deletion helpers are private. |
| 0044 | Clone and R00 postflight passed. Existing clone writer remains owner-owned, its Worker entry point is executor-owned, and the R00 insert trigger function is private. |

Post-commit catalog checks for each migration found no direct Worker access to the edge table and no residual temporary executor membership or schema CREATE privilege. No dependency routes were activated.

- **Passed** `phase4b1-storage-postflight.sql`, `phase4b2-confirmation-rollback.sql` as the date executor within the fixture, and `phase4b3a-guard-date-writers.sql` through a direct Worker connection. The confirmation fixture verified cycle rejection, stale calendar rejection, an atomic two-activity cascade, rollback after an injected late failure, two distinct audit events linked to one operation, exactly one cursor advance, and replay. The date fixture verified dependency guard and stale-token behavior, authorization and an empty-graph edit.
- **Failed during calendar fixture setup**. The rehearsal setup called `change_workspace_calendar` as `neondb_owner` and received SQLSTATE `42501`, `permission denied for function change_workspace_calendar`, at inline PL/pgSQL block line 20 at IF (`aclcheck_error`, `aclchk.c:2793`). The seed transaction rolled back and its synthetic workspace was absent afterward. Both branches showed the function owned by `jlproject_calendar_executor`, with Worker EXECUTE allowed and owner EXECUTE denied. This setup error predates the migration chain. In a separately authorized rehearsal, commit the synthetic workspace seed before calling the calendar entry point as the Worker with an authorized actor.
- **Blocked by the stop rule**. Calendar apply and reversal, activity creation, hierarchy, subtree deletion, two-session contention, clone remapping and working graph/R00 equivalence, and the remaining cross-workspace cases were not run. No fixture retry occurred.

All six historical R00 rows still had empty dependency arrays and matched Development's full-row fingerprint `2edd50b7cb5176016287c3d8379c4c3b` after 0044. Runtime clone and R00 behavior remain unverified. Official Development still had no dependency table. **NO-GO for official Development pending the remaining runtime evidence.**

Neon accepted deletion of the verified child and returned HTTP 404 on the follow-up lookup. The approved 0043 hash matched again after cleanup. The project-level request made internally by the Neon CLI during branch creation returned no branch listing in the run output. No Production database connection was made.

## Follow-up PostgreSQL verification

Read-only Development catalog checks confirmed the expected baseline and matched the earlier writer fingerprints. The checked migration files matched their SHA-256 values at execution, including the approved 0043 hash. Native psql with TLS verification and `ON_ERROR_STOP=1` committed 0036, 0037, 0038, 0039, 0040, 0041, 0042, 0043 and 0044 in order on verified disposable child `br-old-boat-b6r53e6b`. The migrations' in-file postflights passed. A separate read-only owner session confirmed private dependency confirmation, no direct Worker edge access, no temporary executor role or schema privileges, and both R00 triggers enabled.

The role review confirmed Worker EXECUTE for calendar apply, reversal and calendar changes, and the expected version-column privilege for the reversal stale-row probe. Calendar provisioning now commits the synthetic membership before using the calendar API in a direct Worker session as an active synthetic workspace admin. Explicit stage dates were seeded through the audited Worker writer. The activity creation rollback fixture now shares an operation ID across successful changes on its linked product. At this rehearsal checkpoint, the clone fixture still assumed an administrator with SET ROLE access to the Worker, which the Development owner role lacks; the fixture split described below corrects that setup.

| Workflow | Result |
| --- | --- |
| Confirmation and individual dates | Prior passing evidence reused. |
| Calendar setup and apply | Passed as Worker, including stale inputs, derived conflict, valid and empty-graph batches, exactly one cursor advance, and injected late rollback. |
| Calendar reversal | Passed as Worker, including stale input, conflict rejection, late rollback, exactly one cursor advance, and preservation of original audit events. |
| Activity creation | Passed as Worker, including root and derived children, fixed and partial stages, viewer denial, direct trigger rejection, rejected-operation cursor preservation, and empty graph. |
| Hierarchy moves | Stopped at the late collision probe on SQLSTATE `23514`. Earlier assertions in that fixture completed. |
| Subtree deletion, concurrent graph/date mutation, cross-workspace cases, clone and new R00 equivalence | Blocked after the hierarchy failure. |

The first hierarchy setup call was rejected because the setup omitted the audit justification. The setup was corrected to pass the normal Worker metadata under the existing privileges. The actual hierarchy fixture then failed in `write_product_schedule_operation_event` with `A product transaction cannot contain multiple Living Schedule operations.` The fixture performed a successful move and attempted a different operation ID for the same product in that transaction, so the operation invariant fired before an audit-ID uniqueness collision could be reached. Read-only checks confirmed both inspected activities returned to their pre-fixture stage and order, and the valid product retained its two committed setup operation headers. The fixture now explicitly asserts this expected `23514` rejection and rollback. Six historical R00 rows still matched Development fingerprint `2edd50b7cb5176016287c3d8379c4c3b`.

Focused migration contract tests passed (18 tests), and `git diff --check` passed. Neon accepted deletion of the verified disposable child and returned HTTP 404 on the follow-up lookup. Official Development remains **NO-GO** until the outstanding runtime checks pass.

## Final integration fixture corrections prepared

The hierarchy fixture's late probe was named as an audit-ID collision, but on the observed path it is a second distinct Living Schedule operation for the same product in one transaction. The audit writer rejects it first with SQLSTATE `23514` and `A product transaction cannot contain multiple Living Schedule operations.` The fixture now expects that exact error, verifies the nested operation rollback against the activity and cursor snapshots, and generates its own distinct operation ID. It no longer claims to exercise a unique audit-ID collision.

The deletion fixture had two successful deletes on `test_fixed_product` in the same transaction. The complete-explicit and partial-explicit D065 cases now use separate products, so each product has at most one successful logical operation in the fixture transaction. The existing empty-product audit uniqueness probe remains a deliberate `unique_violation` negative case; its failed subtransaction is followed by one successful delete.

The clone verification is split into a read-only owner preflight, a direct `jlproject_worker` mutation session, and a separate read-only owner postflight. The Worker fixture passes a preprovisioned actor ID that is checked against active workspace membership, tests the editor's cross-workspace scope and viewer denial, emits clone IDs for the observer, and tests a partial remap on a target without an existing R00. The owner sessions preserve source fingerprints and verify clone graph/R00 equivalence and audit grouping.

At that checkpoint, two-session concurrency coverage was still pending. The clone Worker fixture contains the cross-workspace case.

Focused contract tests passed: `tests/migration-0042.test.ts`, `tests/migration-0043.test.ts`, and `tests/migration-0044.test.ts` (17 tests). `git diff --check` passed; Git emitted only its existing CRLF normalization warning for unrelated `docs/08-TESTS-AND-DECISIONS.md`. The added untracked fixture files were also checked for trailing whitespace and had none. Lint, typecheck, and build were not run because this checkpoint changes verification SQL, tests, and documentation only. The fixtures are prepared for a new isolated rehearsal; runtime deletion and clone postflights and concurrency remain unverified. Official Development remains **NO-GO** until the outstanding isolated evidence is collected.

## Two-session concurrency verification prepared

The [PostgreSQL concurrency procedure](PHASE-4B5-POSTGRESQL-CONCURRENCY.md) uses four synthetic products and the installed SQL entry points. It observes the blocking transaction with `pg_blocking_pids` before releasing the winning writer. In the cycle and duplicate races the contender must return `stale` with its original preview and `conflict` with a fresh preview. The date contender must reject a change against the newly committed edge even though its activity version is current. The calendar case holds the workspace lock and verifies that confirmation rejects the old calendar version. Additional calls vary only the schedule or calendar version to test each token independently. Full product snapshots check dates, edges, audit state and cursors after rejected transactions commit. The procedure records and cleans up temporary SET-only access for the two owner connections on the isolated child. The date and calendar writers use direct Worker connections.

The earlier explanation for using a Vigente source in the incomplete-remap probe was incorrect. Migration 0035 removed the archived-source restriction from the root helper and checks that the target is active, actor-owned and fresh in the current transaction. Migration 0044 preserves the root helper call and captures its returned ID. The Vigente source now isolates incomplete-map behavior. The normal archived clone case requires a source root edge and checks that both remapped endpoints remain roots and appear in the clone R00 alongside the matching working graph.

The concurrency and migration 0037, 0038 and 0044 contract tests passed (16 tests). `git diff --check` passed with the existing CRLF warning. Lint, typecheck and build were skipped for this verification-only checkpoint. PostgreSQL execution remains pending on a separately authorized child. Official Development remains **NO-GO** until the remaining runtime checks pass.

## Final isolated verification attempt

Read-only preflight confirmed `neondb` in project `rapid-mud-63974868` on Development branch `br-delicate-glitter-b6mj0051`. The catalog showed the expected scoped constraints, writer ownership, six R00 rows with empty dependency arrays, R00 immutability, and no dependency table. The nine local SHA-256 hashes matched the reviewed chain. Neon confirmed `br-raspy-sky-b65exde2` (`phase4b5-final-20261119-181919`) was a non-default child of Development with expiration `2026-11-19T21:19:19Z`.

Migrations 0036, 0037, 0038, 0039, 0040, 0041, 0042, 0043 and 0044 each committed on the child using native psql with `ON_ERROR_STOP=1`. The migration-local checks ran where present. After every commit the owner could not SET ROLE to the date executor, the date executor lacked schema CREATE, and the Worker was outside the executor role. The six historical R00 rows retained the child baseline fingerprint `a94c9366b721958881ac67ae2e613cc3` throughout, computed from comma-joined full JSON rows sorted by ID.

The run stopped at `db/verification/phase4b1-storage-postflight.sql:48`, SQLSTATE `P0001`, inline PL/pgSQL block line 31, with `The storage-only checkpoint must start empty with application access disabled.` The rehearsal runner invoked that fixture after 0044. Its 0036-only privilege assertion requires the date executor to lack edge access, which 0037 deliberately grants for private graph operations. The next rehearsal must run that fixture immediately after 0036 and use the later migrations' privilege checks for the full chain.

Hierarchy, subtree deletion, archived clone and working graph/R00 verification, and the four concurrency races were not reached. No blocking PIDs, runtime audit assertions, or cross-workspace outcomes were collected in this attempt. The concurrency grant was never issued. Official Development remains **NO-GO** pending runtime evidence. `git diff --check` passed with the existing CRLF warning. Focused regressions, lint, typecheck and build were skipped because this attempt changed only the verification record.

Cleanup matched the child ID, name, parent, project, expiration and non-default status before deletion. Neon returned HTTP 200 for deletion and HTTP 404 on the follow-up lookup.

## Stage-aware execution order prepared

The [stage-aware execution order](PHASE-4B5-EXECUTION-ORDER.md) now places `phase4b1-storage-postflight.sql` immediately after migration 0036 and before migration 0037. The fixture's no-access assertion is intentionally limited to that interval: 0037 grants `SELECT`, `INSERT`, and `DELETE` on dependency storage to the private date executor. Later checks instead require that Worker access remains closed except for the clone helper grant introduced by 0044.

The runbook orders the confirmation, date-writer, calendar apply, calendar reversal, activity-creation, hierarchy, deletion, clone/R00, final privilege, and four two-session race checks at the migration point that provides their required routines. It marks committed fixture setup, direct Worker sessions, owner read-only observations, rollback-only probes, and the clone fixture's separate preflight/mutation/postflight sessions. The concurrency procedure now uses bounded `lock_timeout` and `statement_timeout`, requires observed blocking before releasing a winner, and specifies cleanup after an `ON_ERROR_STOP` session failure.

Review found no remaining migration-stage permission contradiction. One operational setup prerequisite remains: the repository has no single SQL seeder for the 0038-0043 runtime fixtures. Their phase documents define synthetic fixture shapes and variables, so those rows and committed calendar histories must be provisioned and reviewed before the next rehearsal. The runbook calls this out instead of treating the scripts as self-seeding. The concurrency seed is self-contained and creates its four synthetic products only on the verified child.

Focused execution-order and concurrency-contract tests passed, and `git diff --check` passed. No Neon branch, migration, database, Worker runtime, or Production resource was accessed for this preparation. The sequence is ready for one complete isolated rehearsal once its separately committed fixture data is provisioned and rehearsal execution is authorized; official Development remains **NO-GO** pending runtime evidence.

## Deterministic setup seeds prepared

Prepared committed synthetic setup for the 0038-0043 runtime fixtures. The existing stage-specific owner seeders now have exact runbook placement. Added `phase4b3c3-schedule-deletion-seed-owner.sql` for the seven deletion scenarios and five dependency edges, plus `phase4b3c3-schedule-deletion-seed-worker.sql` to create the expected audit-ID collision through the authorized deletion preview and writer. The deletion seed keeps direct endpoints, descendant links, the sole-child missing boundary, a valid derived boundary, separate complete/partial explicit stages, and the empty-graph case in isolated products. The Worker collision history is a separate committed operation.

Reviewed the date-guard, calendar-apply, calendar-reversal, activity-creation, and hierarchy-move seed mappings against each runtime fixture's psql variables. Corrected the hierarchy owner seed's duplicate `\gset` alias and destination-discipline variable name; corrected the reversal seed's collision variable name; strengthened the shared edge seeder to verify the remapped endpoint IDs. Owner setup is guarded to a verified disposable child, fingerprints all six existing R00 rows before and after, and never writes R00. Dependency edges are added one at a time through audited confirmation transactions with temporary executor membership revoked before commit.

The execution-order runbook now names every setup script in execution order and documents role/session, commit, rollback, one-operation-per-product, and cleanup boundaries. Focused contract tests passed: `tests/phase4b5-deterministic-seeds.test.ts`, `tests/phase4b5-execution-order.test.ts`, and `tests/phase4b5-concurrency-fixture.test.ts` (16 tests). `git diff --check` passed. No database, branch, migration, Production resource, or application code was touched.

**Readiness:** the 0038-0043 seed prerequisite is prepared for review. The complete 0036-0044 isolated rehearsal is still **NO-GO** because the clone fixture has no checked-in source-product seeder for its required Vigente, Em estudo, Arquivado, and empty sources, R00 rows, memberships, and root dependency links. That setup must be prepared and reviewed before the full rehearsal; official Development remains unchanged and requires separate authorization.

## Migration 0044 clone fixture seed prepared

Prepared the missing deterministic 0044 clone source setup in checked-in SQL and updated the [execution-order runbook](PHASE-4B5-EXECUTION-ORDER.md). `phase4b3c4-clone-seed-owner.sql` creates the source/other workspaces and active editor/viewer memberships, then emits the original six-row R00 fingerprint. Direct Worker setup imports four independent source products through `import_initial_schedule`, sets complete and partial D065 dates through the audited stage-date routine, and creates the Vigente/Arquivado root pairs through the working-plan activity routine. A separate owner setup confirms nine source edges one transaction at a time through the approved audited dependency helper. A direct Worker status step transitions the Em estudo and Arquivado products after their links exist.

The runbook now carries the owner workspace/actor IDs, source IDs, root-edge IDs, historical R00 count/fingerprint, and exact role/session sequence through read-only clone preflight, direct Worker public clones, and read-only postflight. The postflight compares the original six historical R00 rows, requires four supported import-created source baselines plus four clone baselines, verifies every edge remap and graph/R00 equality, and checks root placement for each linked source with a root edge. Seed scripts do not write R00 directly or read the private dependency table from the Worker role. Stage date edits use separate transactions because the stage-date ledger operation ID is unique; root pairs share one logical operation per product.

Focused verification passed: 26 tests across `tests/migration-0044.test.ts`, `tests/phase4b5-deterministic-seeds.test.ts`, and `tests/phase4b5-execution-order.test.ts`; ESLint passed for those three test files; `npm.cmd run typecheck` passed; `git diff --check` passed with Git's existing CRLF normalization warning for unrelated `docs/08-TESTS-AND-DECISIONS.md`. Build was skipped because this checkpoint changes only verification SQL, tests, and documentation. No Neon branch, migration, database write, application logic, or Production resource was accessed.

**Readiness:** the deterministic 0044 clone source setup prerequisite is prepared for review. The complete isolated rehearsal is ready to proceed after separate execution authorization; its new SQL setup has not yet been exercised against PostgreSQL, so runtime migration and integration evidence remains uncollected. Official Development remains **NO-GO** pending that rehearsal and separate approval.

## Complete rehearsal attempt on 2026-11-19

Neon confirmed project `rapid-mud-63974868` and the ready Development branch `br-delicate-glitter-b6mj0051`. The `neondb_owner` catalog session used TLS `verify-full` and read-only mode. The expected scoped keys and immutable R00 trigger were present, dependency storage and routines were absent, and temporary executor access was absent. All nine local SHA-256 values matched the prior isolated execution record. The single verified child was `br-plain-cake-b62qjs9j`, named `phase4b5-complete-20261119-c6`, with expiration `2026-11-20T02:57:07Z`.

| Migration | Installation | PostgreSQL fixture |
| --- | --- | --- |
| 0036 | Committed | Storage and privilege postflight passed immediately after 0036 and before 0037. |
| 0037 | Committed | Controlled confirmation, negative assertions, audit and rollback fixture passed. |
| 0038 | Committed | Owner seed and direct Worker date guards passed. |
| 0039 | Committed | Owner seed, direct Worker calendar setup, and calendar apply fixture passed. |
| 0040 | Committed | Owner base seed, direct Worker calendar and reversal history, and owner dependency seed passed. The direct Worker reversal fixture failed its derived-stage conflict assertion. |
| 0041 | Blocked | Activity creation fixture not run. |
| 0042 | Blocked | Hierarchy move fixture not run. |
| 0043 | Blocked | Subtree deletion fixture not run. |
| 0044 | Blocked | Clone seed, all four clone scenarios, remapping, root placement, new R00 equivalence, source immutability, and failed-remap checks not run. |

Every migration command used native psql and `ON_ERROR_STOP=1`. The reversal fixture exited with psql status 3 at `db/verification/phase4b3b2-calendar-reversal.sql:138`, SQLSTATE `P0001`, with `The derived-stage reversal conflict was not detected.` PostgreSQL identified inline PL/pgSQL block line 52 at `RAISE`. The exception did not include the reversal return payload.

The read-only follow-up confirmed that the committed stage edge and successor start of 2026-11-12 were present. The predecessor activity still ended on 2026-11-11 at version 2, matching the apply ledger, and reversal would restore 2026-11-13. The workspace shutdown covers November 12 and 13. Applying the installed working-day rule to either finish gives the same earliest successor start, Monday November 16. That explains the inconsistent fixture expectation. The successor starts before the bound in both states, and the reversal guard rejects a pre-existing violation only when the projected change worsens it. The actual returned status was not captured. After the failed session, the product still had schedule cursor 3, one product creation, one calendar apply, one dependency confirmation, and zero reversal records for the blocked batch.

The six historical R00 rows matched fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1` from Development through the child checks. The final child observation confirmed no Worker graph SELECT, INSERT or UPDATE, no Worker EXECUTE on private confirmation, no Worker executor membership, no temporary owner SET access, and no executor CREATE on the public schema. Complete-chain privilege and audit checks were blocked. Cycle and duplicate-edge races, graph versus date, calendar versus graph, and independent schedule/calendar token checks are **NOT VERIFIED**. No concurrent test sessions, blocking PIDs, or concurrency grants were created.

Cleanup matched the child ID, project, name, parent, non-default state, and expiration. Neon returned HTTP 200 for deletion and HTTP 404 `branch not found` on the follow-up lookup. Local lint, typecheck, tests and build were not run because this attempt changed only the verification record.

**NO-GO for official Development.** Review the 0040 fixture dates against the seeded calendar so the blocked case exercises an actual increase in the finish-to-start violation. A complete isolated rehearsal remains necessary after that fixture correction.

## 0040 calendar reversal fixture correction prepared

The prior fixture had an applied predecessor finish of 2026-11-11 and a successor start of November 12. With a shutdown from November 12–13, both the current finish and the restored November 13 finish mapped to a November 16 earliest start. The correction changes only the synthetic shutdown start from November 12 to November 13; its end remains November 13. The existing predecessor plan (November 9 start, three working days) still recalculates to a November 11 finish, and the manual successor remains on November 12. Before reversal, November 12 is the first working start and the successor satisfies the FS constraint exactly. Reversal restores the predecessor finish to November 13; November 14–15 are weekend dates and November 15 is also Republic Day, so the first working start is Monday November 16. The unchanged successor is then four civil days before its required start, changing its constraint margin from zero to a four-day violation.

The Worker fixture now captures and asserts the returned JSON payload: `dependency_conflict`, reason `finish_to_start`, the deterministic dependency and predecessor/successor stage IDs, and the exact before/after predecessor finish, successor start, and earliest permitted start. It emits the full expected payload with `RAISE NOTICE` for rehearsal evidence. Before the call, it snapshots all activity rows (including dates and versions), the complete schedule-operation history returned by the authorized read API, and the schedule cursor. After the conflict it asserts all three snapshots are unchanged; a failed reversal therefore cannot add a reversal operation or audit detail.

Focused contract coverage now calculates the applied finish and both earliest starts from the existing working-day helper and the corrected seeded shutdown, and checks the payload assertions and rollback comparisons. This is fixture preparation only: no database, branch, migration, or application logic was changed. The corrected fixture has not yet been executed against PostgreSQL. **Ready for another separately authorized isolated rehearsal; official Development remains NO-GO until the full chain and integration checks pass.**

## Rehearsal paused at static preflight

The corrected 0040 case is consistent with the SQL calendar rule. A November 11 finish permits November 12. Restoring the November 13 finish skips the November 14–15 weekend and permits November 16. The fixed November 12 successor goes from zero days early to four civil days early. This remains a static result.

The review found a concrete 0044 fixture blocker in `db/verification/phase4b3c4-clone-seed-owner-dependencies.sql`. The root audit assertion counts every `stage_activities_created` event for the Vigente source and the source destined to be archived, then requires exactly four. Each source already has 41 stage activities inserted by `import_initial_schedule` and two root activities inserted by the Worker setup. The row-level `stage_activities_schedule_audit` trigger in 0029 records an insert event for every activity. The import operation type waives the date-change justification rule in that trigger and still records the creation event. The assertion therefore matches 86 events if setup reaches it, including 82 import events and four root events. Its exception would be `Root working-plan assumptions or source schedule audit grouping are incorrect.` This is a static prediction, with no PostgreSQL error observed in this attempt.

The root audit assertion should count the four expected root activity identities under the two intended `activity_created_with_dates` operations, keyed by workspace, product, and operation identity. The existing requirement of four root events should be retained.

The pre-execution gate stopped this attempt. Development catalog and checksum verification were skipped after the static blocker. No branch was created, and there was no branch to delete. Migrations and runtime fixtures 0036–0044 were blocked for this attempt. Clone and R00 checks, final permission and audit checks, and all four concurrency races are **NOT VERIFIED** in this attempt. Prior rehearsal evidence above remains applicable to the runs that produced it. **NO-GO for official Development.**

## 0044 clone seed audit assertion correction prepared

The owner seed now checks the two committed Worker root setup operations individually. The Vigente source uses operation `4b440000-0000-4000-8000-000000000311` and the source later archived uses `4b440000-0000-4000-8000-000000000312`. The query joins audit events to the parent operation by workspace, product, schedule version and operation ID, then verifies the expected actor, operation type and justification. Each operation must contain exactly two activity creation events tied by entity ID to two distinct live roots in that product, for four events total. The prior product-wide count also included 41 import events per source, yielding 86 events.

The seed still requires 41 imported stage activities per source, validates root working plans and dependency endpoints, and checks the historical R00 fingerprint. The clone preflight and postflight still include the source audit history in their fingerprint checks.

The 0044, deterministic seed, and execution order contracts passed (29 tests). Focused lint and typecheck passed. Build was skipped because the changes affect only verification SQL, tests and documentation. The fixture is ready for the next isolated rehearsal, where PostgreSQL execution will verify the corrected assertion. Official Development remains **NO-GO** pending integration results.

## Full rehearsal stopped at the 0041 viewer seed

The read-only catalog verified project `rapid-mud-63974868`, Development branch `br-delicate-glitter-b6mj0051`, database `neondb`, and session role `neondb_owner` with `transaction_read_only=on` and TLS `verify-full`. The scoped keys, writer catalog, immutable R00 trigger, six empty dependency arrays, and historical fingerprint matched the baseline. Dependency storage and the private confirmation routine were absent. Temporary owner SET and executor schema CREATE were absent. All nine local migration SHA-256 values matched the reviewed chain.

The only migration target was `br-lucky-snow-b637f5ns` (`phase4b5-full-1795134455847`), a verified non-default Development child expiring at `2026-11-20T03:27:35Z`. Native psql ran with `ON_ERROR_STOP=1` and verbose errors.

| Stage | Migration | Runtime and setup |
| --- | --- | --- |
| 0036 | PASS | Storage and privilege postflight PASS before 0037. |
| 0037 | PASS | Confirmation, cascade grouping, stale checks, replay and rollback PASS. |
| 0038 | PASS | Owner seed and direct Worker date guards PASS. |
| 0039 | PASS | Owner seed, direct Worker calendar setup and apply PASS. |
| 0040 | PASS | Owner seed, Worker history, dependency seed, and direct Worker reversal PASS. |
| 0041 | PASS | Owner seed FAIL before its write transaction. Worker activity creation BLOCKED. |
| 0042 | BLOCKED | Hierarchy seed and move fixture BLOCKED. |
| 0043 | BLOCKED | Deletion seeds and subtree fixture BLOCKED. |
| 0044 | BLOCKED | Clone seeds, scoped root audit assertion, all four clone cases, remapping and new R00 equivalence BLOCKED. |

The 0040 Worker fixture received `dependency_conflict` with reason `finish_to_start` for stage dependency `4b400000-0000-4000-8000-000000000201` (stage IDs ending `0001` and `0002`). PostgreSQL returned predecessor finish November 11, successor start November 12, and earliest start November 12 before reversal. It returned projected predecessor finish November 13, unchanged successor start November 12, and earliest start November 16 after reversal. The fixture passed its unchanged activity dates, versions, operation history and cursor comparisons. The positive reversal preserved original audit events, appended the two expected reversal detail links, and advanced the schedule cursor once. The stale-token, late-collision rollback and empty-graph cases passed.

The 0041 owner seed stopped at `db/verification/phase4b3c1-activity-creation-seed-owner.sql:34` with psql exit code 3 and the exact message `error: no rows returned for \gset`. This is a psql assertion following a SELECT, so there is no PostgreSQL SQLSTATE for it. The admin lookup at lines 29–31 succeeded. The viewer lookup at lines 32–34 found no active viewer membership for an auth identity distinct from that admin. The failure occurred before `BEGIN` at line 36, so this seed committed no writes. The hierarchy, deletion and clone seeds also require an existing distinct active viewer. The next rehearsal needs an approved viewer identity setup that meets those fixture preconditions on the disposable child.

Read-only checks on the child at the stop point returned six historical R00 rows and fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`. The Worker had no direct graph SELECT, INSERT, UPDATE or DELETE, no private confirmation EXECUTE, and no executor membership. Temporary owner SET and executor schema CREATE were absent. Final-chain permissions, clone/source audit preservation and cross-workspace clone isolation remain **NOT VERIFIED**. All four concurrency races (graph confirmation, graph versus date, calendar versus graph, and independent token validation) remain **NOT VERIFIED**. No two-session blocking evidence was collected.

Cleanup reverified the child ID, project, parent, name, expiration and non-default status. Neon returned HTTP 200 for deletion and HTTP 404 on the follow-up lookup. Only this report changed. Local lint, typecheck, tests and build were not rerun for the report-only edit. **NO-GO for official Development.**

## Viewer identity fixture correction prepared

The 0041 failure came from selecting a viewer only from `workspace_memberships`; no active viewer row distinct from the selected administrator existed on the disposable branch. The two required fixture identities must be valid rows in the installed `neon_auth."user"` provider table, with distinct UUIDs, before the owner seed can create its synthetic workspace memberships. The `workspace_memberships.auth_user_id` foreign key then validates the active admin and viewer memberships normally.

Neon documents a branch-scoped Auth user creation endpoint for `/projects/{project_id}/branches/{branch_id}/auth/users`; creating users through that provider API is supported and keeps identity changes on the disposable branch ([Neon Auth API](https://neon.com/docs/reference/api/auth/create-branch-neon-auth-new-user)). The prepared runbook uses branch-specific `example.invalid` emails, captures the provider UUIDs, and passes them to a shared owner preflight. That preflight checks both IDs and exact email-to-branch mapping against `neon_auth."user"`, requires the admin/viewer IDs to differ, and exits with an actionable psql diagnostic before persistent fixture writes. It does not insert Auth rows, modify real memberships, grant permissions, or create tokens.

Owner seeds for 0041, 0042, 0043, and 0044 now use the provider-issued synthetic identities rather than selecting incidental users by current workspace roles. They create active memberships only in their synthetic fixture workspaces. The 0041 Worker fixture now verifies the supplied viewer has an active viewer membership before exercising viewer denial; its existing successful administrator calls remain tied to the supplied admin ID. The 0042 hierarchy, 0043 deletion, and 0044 clone fixtures already retain explicit viewer-denial checks and now receive the same controlled identities. No SQL or application migrations changed, and no Neon branch, migration, or database write was performed during this preparation.

Focused identity-fixture, migration-contract, execution-order, and deterministic-seed tests passed (7 files, 50 tests). Focused ESLint and project typecheck passed. `git diff --check` passed; a targeted whitespace scan of all changed fixture, test, and verification files found no trailing whitespace. Build was not run because the changes are confined to SQL verification fixtures, tests, and documentation. The next authorized isolated rehearsal is ready to retry 0041 and continue; official Development remains **NO-GO** until the full 0036–0044 PostgreSQL integration and concurrency verification passes.

## Resumed full rehearsal stopped at identity preflight

Fresh Neon metadata confirmed project `rapid-mud-63974868`, official Development branch `br-delicate-glitter-b6mj0051`, and database `neondb`. The read-only catalog ran over TLS `verify-full` as `neondb_owner`; `transaction_read_only` was `on`. It confirmed the 0036 dependency table was absent, no public dependency-named routines existed, `workspace_memberships.auth_user_id` references `neon_auth."user"(id)`, and that Auth relation exposes UUID `id` and text `email`. The Development R00 baseline remained six rows with fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`. No read-only compute endpoint exists, so this preflight used the primary endpoint under an explicit read-only transaction.

The local 0036–0044 migration checksums were recorded before execution. Current values are:

| Migration | SHA-256 |
|---|---|
| 0036 | `9EA61A6550BCB7F04165D21106D8CB7D7EC0246B22D1EDF51B3608857BB2CA52` |
| 0037 | `FA0093B0452B7D0AC11CDFB518EA1A9F662C8C489AED7F6FA74F1A91AC78723B` |
| 0038 | `50F5479D077F7A0A29DBCA6F323D111A79E06966CDEBA1A7FA60044D29980C49` |
| 0039 | `B5566A30E4445F6B969C6BEAB6F6599600C014F68730B1085E823A674A72E876` |
| 0040 | `2A8657C04CF357CB9FFBAE137B6520C1807D77B7192C0227ECF241DED1522B00` |
| 0041 | `385250D8ADA2BB9369DD561A4BC5E102F1F662A56A562C435D0AC5F48EB54998` |
| 0042 | `A59EC689C267A7CE4E9F343029016D184536BC63154C26D5ECBE18478DBC6524` |
| 0043 | `FBE35B36EBAE927DDB4CE2A56B243CDCCCA7381C4C775A9809866808F1B21CD2` |
| 0044 | `A7D4DECF9096507164439B8AD42708D66E41D3EAD92AA59D1CD001200C8AE2C2` |

The corrected 0039, 0041, and 0043 values match their individually approved checksums. The previous isolated-chain report recorded all nine files matching the reviewed chain; the files were unchanged since that check. No migration file was edited during this rehearsal.

The only child was `br-dawn-wildflower-b6a2ac2x` (`phase4b5-resume-20261120-0056`), parent `br-delicate-glitter-b6mj0051`, non-default, with expiry `2026-11-20T06:56:15Z`. Two branch-targeted Neon Auth create calls returned HTTP 201:

| Actor | Provider ID | Synthetic email | Result |
|---|---|---|---|
| Admin | `2dcdddce-a9e4-467d-80a0-cfd69c25af0e` | `jlproject-phase4b5-admin-br-dawn-wildflower-b6a2ac2x@example.invalid` | Created and matched child Auth row |
| Viewer | `77464553-5ef4-46ce-a889-2660ba544a73` | `jlproject-phase4b5-viewer-br-dawn-wildflower-b6a2ac2x@example.invalid` | Created and matched child Auth row |

A read-only query of Development found zero matching IDs or emails, verifying branch isolation. The shared `phase4b5-seed-auth-identities-owner.sql` preflight was then invoked with all three documented `-v` variables, but Neon CLI's embedded TypeScript psql reported `Missing psql variable phase4b5_branch_id. Provision identities on the verified disposable child first.` and stopped before membership seeding. The wrapper process returned exit code 0 despite the script's `\quit 3`. A separate read-only `-c` probe on the same wrapper showed the branch variable was present in that command mode. The `-f`/included-script discrepancy and exit-code behavior are not explained by the current evidence; no fixture or production logic was altered to work around it.

Final read-only child checks showed dependency storage absent, zero 0041–0044 fixture workspaces, and the six historical R00 rows still at fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`. No membership, schedule, dependency, audit, or migration writes occurred. The only child writes were the two authorized Neon Auth identity creations. The child was deleted by exact project/branch ID; deletion returned HTTP 200 and a follow-up GET returned HTTP 404.

| Stage | Status | Evidence |
|---|---|---|
| Development preflight and identity schema | PASS | Read-only catalog passed; parent Dev has no dependency table/routines; Auth FK and columns verified. |
| Child creation and isolation | PASS | Child parent/name/expiry verified; synthetic identities matched child rows and were absent from parent. |
| Shared identity preflight | BLOCKED | `-f` invocation did not expose `phase4b5_branch_id`; explicit failure occurred before membership writes. |
| Migrations 0036–0044 | NOT VERIFIED | None executed; stop gate held. |
| 0036 storage postflight | NOT VERIFIED | Not run. |
| 0037 confirmation/rollback | NOT VERIFIED | Not run. |
| 0038 individual date guards | NOT VERIFIED | Not run. |
| 0039 calendar apply | NOT VERIFIED | Not run. |
| 0040 calendar reversal | NOT VERIFIED | Not run. |
| 0041 activity creation | NOT VERIFIED | Owner seed stopped before transaction; Worker fixture not run. |
| 0042 hierarchy moves | NOT VERIFIED | Not run. |
| 0043 subtree deletion | NOT VERIFIED | Not run. |
| 0044 clone/R00 scenarios | NOT VERIFIED | Not run. |
| Four PostgreSQL concurrency races | NOT VERIFIED | Not run; no blocking evidence collected. |
| Branch cleanup | PASS | Delete HTTP 200; follow-up GET HTTP 404. |

This rehearsal is **NO-GO for official Development**. Before another authorized rehearsal, diagnose and correct the shared preflight invocation/embedded psql file-mode variable handling, then rerun the focused contract checks. Do not bypass the shared preflight or proceed with membership seeding until it succeeds. Official Development received no writes or migrations; Production was not accessed.

## Embedded psql `-f` preflight correction prepared

The reproduction used Neon CLI 9.7.2. `psql` was absent from `PATH`, so the Neon CLI selected its embedded TypeScript psql implementation. The sanitized invocation passed `-v phase4b5_branch_id=br-probe-synthetic` before `-f <temporary-read-only-script>`. Direct `-f` and separate `-c` probes both observed the supplied value; no variable loss from argument parsing or script assignment was found. The defect was the embedded file-mode conditional interpreter: it printed both the true and else messages for `\if :{?phase4b5_branch_id}`, then returned process code 0 for `\quit 3`. This is why the old helper falsely reported a missing variable.

The tested command shape was `npx neon@latest --no-analytics psql br-delicate-glitter-b6mj0051 --project-id rapid-mud-63974868 --role-name neondb_owner --database-name neondb -- -X -v ON_ERROR_STOP=1 -v phase4b5_branch_id=br-probe-synthetic -f <temporary-script.sql>`. The `-c` comparison used the same target and flags with a harmless `\echo` command. No database password, Neon API key, or credential string was included in the command or output.

A second temporary parent-file probe and the 0041 owner seed with its child flag explicitly false both stopped at `\i` with `\i: syntax error at or near "\"`, exit 3. Embedded `-f` treats the include command as SQL, so it did not execute the included file or alter its variables. This is a separate limitation from the incorrect conditional flow; owner seed includes require native psql.

The shared identity preflight now uses `BEGIN READ ONLY`, SQL validation, and explicit `RAISE EXCEPTION` failures for invalid branch IDs, malformed or identical UUIDs, wrong execution role, and absent or branch-mismatched provider rows. Actor aliases are exposed only after both real `neon_auth."user"` rows match. The shared disposable-child preflight now validates its required flag with SQL as well. Both avoid psql conditional/quit flow and rely on `ON_ERROR_STOP=1` to propagate a genuine SQL error.

Read-only embedded `-f` probes produced these process results:

| Case | Result |
|---|---|
| Harmless `BEGIN READ ONLY`, variable substitution, and `ROLLBACK` | PASS, exit 0 |
| Missing required branch variable | Rejected at SQL parsing, exit 3 |
| Malformed branch ID | Explicit preflight exception, exit 3 |
| Malformed Auth UUID | Explicit input exception, exit 3 |
| Valid-format but absent/mismatched Auth identities | Explicit admin identity mismatch exception, exit 3 |
| Disposable-child flag set to `false` | Explicit child gate exception, exit 3 |
| 0041 owner seed with child flag false through embedded `-f` | Stopped at unsupported `\i` before any seed write, exit 3 |
| Deliberate SQL division-by-zero with `ON_ERROR_STOP=1` | SQL error stops the file, exit 3 |
| `-c` variable probe | Variable visible; exit 0 |
| Old `-f` `\if`/`\else` plus `\quit 3` probe | Both branches printed; exit 0 (reproduced defect) |

The live positive identity match was not run: doing so requires a disposable child with provider-created Auth rows, and branch creation was explicitly out of scope. The success-path SQL structure and retained branch-specific row checks are covered by contract tests. No branch, identity, membership, migration, or database object was created or changed. The read-only failure probes used fake UUIDs and transaction-scoped/session-scoped preflight values only.

The focused identity contract passed (7 tests), focused ESLint passed, and project typecheck passed. Build was not run because the changes are verification SQL, tests, and documentation only. `git diff --check` and whitespace checks are recorded after this report update. The six historical R00 rows and the untracked production-baseline SQL were not modified.

The identity and shared child preflights are ready for a future disposable-child test when run by native psql. The complete runbook is **not ready to execute through this embedded psql fallback**: owner seeds require `\i`, and other verification fixtures also rely on native conditional psql guards (0037 confirmation, 0040 calendar setup, 0044 clone setup, one-edge setup, and concurrency seeds). Verify a native psql executable is on `PATH` and the Neon CLI does not enter fallback mode before creating the next rehearsal branch. Official Development remains **NO-GO** for migrations.

## Native psql rehearsal stopped at the 0041 owner seed

Neon CLI 9.7.2 launched native `C:\Program Files\PostgreSQL\18\bin\psql.exe` 18.7 for the read-only probes, migrations and fixtures. The harmless `-f` probe verified variable expansion, conditional flow, includes and `\gset` with exit 0. The deliberate division by zero exited 3. The default libpq root file was absent and `sslrootcert=system` failed certificate verification. A temporary bundle from Node's bundled public TLS roots, selected through `PGSSLROOTCERT`, passed with `--ssl verify-full`. The temporary probe and CA files were removed.

Read-only checks confirmed `neondb` on project `rapid-mud-63974868`, Development branch `br-delicate-glitter-b6mj0051`. The dependency table and routines were absent, the expected scoped keys and immutable R00 trigger were present, and the six historical R00 rows matched fingerprint `9b6daa6196b11b3bee428a1d96fcd1c1`. All nine SHA-256 values matched the reviewed table above.

The sole child was `br-proud-math-b6meta2k` (`phase4b5-native-1795140840`), verified as a non-default child of Development with expiry `2026-11-20T06:14:00Z`. The branch-scoped Auth API returned HTTP 201 for both synthetic users. The corrected SQL preflight verified the exact provider UUID and email pairs against the child's `neon_auth."user"` rows. A read-only check confirmed neither the IDs nor the emails existed on Development. The shared child-safety helper passed after 0036, the first point at which its required dependency table existed, and before any fixture seed that uses it.

| Migration | Installation | Runtime fixture result |
|---|---|---|
| 0036 | PASS | Storage and initial role grants passed before 0037. |
| 0037 | PASS | Confirmation fixture passed, including cascade audit grouping, staleness, replay, Worker denial and atomic rollback. |
| 0038 | PASS | Owner setup and direct Worker date guards passed. |
| 0039 | PASS | Owner setup, direct Worker calendar setup and apply passed. |
| 0040 | PASS | Owner setup, direct Worker history, dependency setup and reversal passed. |
| 0041 | PASS | Owner seed failed at its stage insert. Worker activity creation and viewer denial **NOT VERIFIED**. |
| 0042 | NOT VERIFIED | Hierarchy setup and runtime fixture not reached. |
| 0043 | NOT VERIFIED | Subtree deletion setup and runtime fixture not reached. |
| 0044 | NOT VERIFIED | Clone setup, all four clone scenarios, source immutability and new R00 equivalence not reached. |

0040 returned `dependency_conflict` with `finish_to_start` on edge `4b400000-0000-4000-8000-000000000201`. The predecessor finish would move from November 11 to November 13, 2026, and the earliest permitted successor start from November 12 to November 16. The successor stayed on November 12. The fixture passed the unchanged dates, versions, audit history and cursor checks for rejection. Its successful reversal preserved the original audit and advanced the schedule cursor once.

Native psql exited 3 at `db/verification/phase4b3c1-activity-creation-seed-owner.sql:78` with SQLSTATE `23514`, `Stage dates must be created through the audited operation.` PostgreSQL reported `public.guard_discipline_stage_date_update()` line 9 at `RAISE`. Line 78 ends the multirow stage insert beginning on line 69. Four rows have a non-null `planned_start` or `planned_end`. The installed trigger rejects such direct inserts on its `INSERT` branch before consulting audit settings. The fixture's `product_created` settings therefore cannot authorize that statement. This is a fixture setup incompatibility with the existing enforced stage date workflow. Prepare the explicit dates through the supported audited stage operations in a separate fixture correction, preserving the operation-per-product transaction rule.

A separate read-only session found zero 0041 fixture workspaces, memberships, products, stages, activities, edges and schedule operations. All six historical R00 rows matched the original aggregate fingerprint. Worker direct graph privileges, private confirmation execution and executor membership were absent. Temporary owner SET membership and executor schema CREATE were absent as well. Complete-chain privileges, 0041 viewer denial, clone cross-workspace isolation and clone audit checks remain **NOT VERIFIED**.

The four concurrency scenarios (cycle, duplicate edge, graph versus date, and calendar versus graph) and independent token checks are **NOT VERIFIED**. No contending sessions were opened and no `pg_blocking_pids` evidence was collected.

Cleanup verified the child's project, ID, parent, name, expiration and non-default status. Deletion returned HTTP 200 and the follow-up lookup returned HTTP 404 `branch not found`. Official Development was queried read-only. Production was outside the execution targets. Repository changes in this attempt are confined to this evidence record. Application lint, typecheck, tests and build were skipped because the rehearsal did not change application or fixture code.

At the time of this rehearsal, the 0041 owner fixture correction and full isolated integration verification remained outstanding. The fixture correction is now prepared below; full PostgreSQL verification remains required. Official Development remains **NO-GO**.

## Stage-date source-event assertion correction prepared

The trigger implementation confirms the stage-date association sequence. `stage_date_changes.event_id` is the immutable source-ledger event identity. The `stage_date_changes_schedule_link` AFTER INSERT trigger calls `link_product_schedule_audit_source()` before the schedule mutation trigger creates its `product_schedule_operations` row; when no operation exists in the current transaction, that function returns before inserting either legacy or source-event links. Later, the `product_schedule_operation_events_source_links` AFTER INSERT trigger matches stage ledger rows by workspace, product and operation ID, then writes `product_schedule_operation_source_events` with `source_ledger='stage_date_changes'`, the ledger operation ID, ledger `event_id`, schedule operation ID/version, and `link_kind='audit_detail'`. The operation event has a separate bigint `event_id`; the stage ledger UUID must not be compared to that identity.

The 0041, 0042 and 0043 owner assertions now verify this authoritative source-event association. They require exactly four, three and two successful stage-date associations respectively, and join each to the expected workspace, product, stage-date operation, schedule version, actor, Living Schedule operation type/justification, stage entity and `discipline_stages_dates_changed` event. Exact source ledger, source operation ID, source event UUID and link kind are checked. Additional counts detect missing, duplicate or misassociated source rows for the fixture operation IDs. Existing exact date, audit ledger, stage version, per-operation transaction, cursor advancement, role cleanup and historical R00 assertions remain. Legacy `product_schedule_operation_links` checks were removed only from these standalone stage-date paths; other workflow assertions that rely on legacy links remain unchanged.

Focused tests passed: 23 tests across `phase4b5-deterministic-seeds.test.ts` and `migration-0030.test.ts`; targeted ESLint and TypeScript typecheck passed. `git diff --check` found no whitespace errors (it emitted the repository's existing CRLF-to-LF warning for `docs/08-TESTS-AND-DECISIONS.md`). No migration, application code, trigger, permission or database object was changed. No database write or branch creation occurred. The corrected fixtures are prepared for review; they remain unexecuted on PostgreSQL, so the next authorized isolated rehearsal is still required. Official Development remains **NO-GO**.

## Audited stage-date fixture correction prepared

The 0041 failure was caused by direct insertion of four non-null stage date intervals. The installed `guard_discipline_stage_date_update()` rejects every dated `discipline_stages` insert; `product_created` audit context does not authorize those stage dates. The owner seed now inserts all stages with both date fields `NULL`, commits structural setup, and retains its historical R00 baseline for the later owner verification.

A direct `jlproject_worker` setup calls the existing `change_discipline_stage_dates()` function four times through `phase4b5-seed-one-stage-date.sql`. Each call uses a distinct operation ID, version-1 token, synthetic admin actor and explicit justification, and commits in its own transaction. The resulting version-2 intervals are: complete `2026-11-03`–`2026-11-05`, partial `NULL`–`2026-11-05`, fixed successor `2026-11-06`–`2026-11-10`, and violation successor `2026-11-06`–`2026-11-10`. Derived stages remain undated at version 1. The linked product cursor advances three times; the violation product cursor advances once. A separate owner verification checks exact stage-date ledger before/after values, actor and reason, Living Schedule operation type and justification, event/link identities, distinct transactions, cursor values, and the original six-row R00 fingerprint before adding edges.

Targeted review of the later seed scripts found the same blocked direct-stage-date insert pattern in 0042's fixed D065 stages and 0043's complete/partial D065 stages. These fixtures now also insert undated stages, establish explicit/partial intervals through the same audited Worker helper in three and two separate transactions respectively, verify their audit and cursor state under a temporary owner SET grant that is revoked before commit, then add dependency edges. The 0043 deletion collision Worker setup remains after edge confirmation. The 0044 clone fixture already imports source schedules through `import_initial_schedule()` and sets stage dates through `change_discipline_stage_dates()`; no stage-date direct-write correction was needed there. Direct dated activity inserts in the 0041–0043 owner seeds remain initial schedule rows under the existing `product_created` operation, before dependency links are created; they do not set guarded stage-date columns.

This correction is fixture-only. No migration, application code, database object, branch, membership, or business data was changed. The revised execution runbook separates owner structural setup, direct Worker stage-date operations, owner audit/edge setup, and subsequent Worker fixtures. The seed scripts assert the resulting D065 values, stage versions, audit state, cursor advances, and historical R00 preservation. Focused tests passed: 48 tests across the deterministic seed, execution-order, and migration 0041–0044 contract files; focused ESLint passed; TypeScript typecheck passed; `git diff --check` reported no whitespace errors (it emitted only the repository's existing CRLF-to-LF warning for `docs/08-TESTS-AND-DECISIONS.md`). The fixtures remain unexecuted on PostgreSQL; the next isolated rehearsal must verify their runtime behavior before the chain is considered ready for official Development. Official Development remains **NO-GO**.
