# Phase 4B.5 PostgreSQL concurrency procedure

Run after authorized installation of 0036–0044 on a verified, expiring Development child. Use two native psql sessions with `-X -v ON_ERROR_STOP=1`. Use the seed output only within the rehearsal. It creates a fresh workspace and four products with no edges. It assigns the separately provisioned branch-scoped synthetic admin to that workspace.

## Sessions and permissions

Run `db/verification/phase4b5-concurrency-seed.sql` as `neondb_owner` via the checked-in runner with `phase4b5_disposable_branch_verified=true`, the verified child ID and the two verified Auth UUID bindings from the manifest. Set `workspace`, `actor`, `product`, `early`, and `late` as psql variables in both sessions for each case using the matching seed row. Check that the owner can read the audit tables used by the state script.

Graph confirmation and snapshot reads are private to `jlproject_date_executor`. For this rehearsal the two owner connections need a shared, temporary SET-only membership on the child. Obtain approval for this verification-only grant when authorizing execution. Leave all Worker grants intact. First run `phase4b5-concurrency-role-check.sql` via the checked-in runner in a fresh, read-only owner session with `phase4b5_expect_owner_set=false`. Require the sole pre-existing executor membership for `neondb_owner` to be granted by `cloud_admin`, with ADMIN true, INHERIT false and SET false.

```sql
-- Run as owner on the verified child only, in the same session through COMMIT.
BEGIN;
GRANT jlproject_date_executor TO neondb_owner
  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
COMMIT;
```

Check `phase4b5-concurrency-role-check.sql` again through a fresh owner connection with `phase4b5_expect_owner_set=true`. Require both catalog rows with the expected grantors and options and effective SET access. The prior rehearsal observed a successful standalone GRANT command without persistent access. A command tag is insufficient evidence, and its discrepancy remains unexplained. Stop if the committed grant is absent or has an unexpected shape.

For graph calls open `BEGIN ISOLATION LEVEL READ COMMITTED;`, then `SET LOCAL ROLE jlproject_date_executor;`. In every active test transaction set bounded timeouts: `SET LOCAL lock_timeout = '90s'; SET LOCAL statement_timeout = '2min';`. This leaves time to observe the blocker and release the winning transaction while ensuring a lost operator session cannot wait indefinitely. Always use a direct `jlproject_worker` connection for the date and calendar writers. Their actor parameter comes from the synthetic admin membership. The fixture requires no Worker access to graph tables or private confirmation functions. Before starting, verify that the owner observer can see the two test backend PIDs and a nonempty `pg_blocking_pids` result; do not grant broader monitoring access as a test workaround.

## Synchronization

Record both backend PIDs before submitting the contending statement. Keep session A's winning transaction open. Submit session B's call and run the following in A with B's PID assigned to the psql variable `b_pid`. Reissue the query until `blocked_by_a` is true or the bounded timeout expires. A false result before B starts is normal. A result from B before the lock is observed fails the concurrency case. Commit A only after the wait is observed. Match both sessions to the same verified branch and database. Do not use sleeps as synchronization.

```sql
SELECT pg_backend_pid();
SELECT pg_backend_pid() = ANY(pg_blocking_pids(:'b_pid'::int)) AS blocked_by_a;
```

The graph writer takes workspace and membership share locks before the product update lock. Individual date writers lock the workspace and then the active product before testing current edges. The calendar writer takes an exclusive workspace row lock, so its confirmation contender waits at the workspace boundary. A timeout is a test failure. Record the two PIDs, the observed wait and both outcomes.

## Graph versus graph

Use the `cycle` product first, then repeat with `duplicate`. In A as owner, capture the baseline with the state script and `\set baseline_state :fixture_state`. Start both executor transactions and capture the same preview in each before A writes. Use this snippet whenever the procedure calls for a fresh snapshot.

```sql
SELECT public.read_schedule_dependencies(:'workspace', :'product', :'actor', false)::text AS preview \gset
SELECT 1 / COALESCE((:'preview'::jsonb->>'status' = 'ok'), false)::int;
SELECT :'preview'::jsonb#>>'{snapshot,scheduleVersion}' AS schedule_version,
       :'preview'::jsonb#>>'{snapshot,calendar,version}' AS calendar_version,
       :'preview'::jsonb->>'fingerprint' AS fingerprint \gset
```

For each new confirmation generate fresh IDs using `SELECT gen_random_uuid() AS operation, gen_random_uuid() AS edge \gset`. Set `from_id`, `to_id` and `expected_status` with psql `\set` and include `\i db/verification/phase4b5-concurrency-confirm.sql`.

1. A submits Early → Late and expects `applied`. Keep the transaction open. In A, `RESET ROLE;`, include `\i db/verification/phase4b5-concurrency-state.sql`, then copy the value using `\set winner_state :fixture_state`.
2. B submits Late → Early in the cycle case or Early → Late with a distinct edge ID in the duplicate case. B uses its original preview and expects `stale`. Observe B waiting, commit A, then let B finish and commit B. Committing the rejected result allows the observer to detect any unintended writes.
3. A includes the state script again and asserts equality using `SELECT 1 / (:'winner_state'::jsonb = :'fixture_state'::jsonb)::int;`. Inspect `winner_state` against the initial preview. Exactly one Early → Late edge exists, the dates and date ledger are unchanged, and the winner has one operation, one dependency event and a schedule version increment of one.
4. In a fresh executor transaction retry B's same endpoints with fresh IDs and a fresh preview. Expect `conflict` for both the cycle and duplicate cases. Commit the rejected call and repeat the complete winner-state equality assertion. Use a distinct ID even for the duplicate so this tests endpoint duplication.
5. With a fresh fingerprint and calendar version, decrement only the captured schedule version by one. Submit a fresh Early → Late request and expect `stale`, which must precede duplicate detection. Commit and repeat the state equality assertion.

In A use the following to check the winning delta. A's `edge` and `operation` variables must still identify its winning call.

```sql
WITH states AS (SELECT :'baseline_state'::jsonb AS before, :'winner_state'::jsonb AS after)
SELECT 1 / COALESCE((
  after->'activities' = before->'activities'
  AND after->'date_ledger' = before->'date_ledger'
  AND after->'source_events' = before->'source_events'
  AND jsonb_array_length(after->'edges') = 1
  AND after->'edges' @> jsonb_build_array(jsonb_build_object('id', :'edge',
    'predecessor_activity_id', :'early', 'successor_activity_id', :'late'))
  AND (after#>>'{cursor,schedule_version}')::bigint = (before#>>'{cursor,schedule_version}')::bigint + 1
  AND jsonb_array_length(after->'operations') = jsonb_array_length(before->'operations') + 1
  AND after->'operations' @> jsonb_build_array(jsonb_build_object('operation_id', :'operation'))
  AND jsonb_array_length(after->'events') = jsonb_array_length(before->'events') + 1
  AND after->'events' @> jsonb_build_array(jsonb_build_object(
    'operation_id', :'operation', 'entity_id', :'edge', 'change_type', 'dependency_added'))
), false)::int AS expected_winning_delta FROM states;
```

## Graph versus date

Use the `date` product. In B, connected directly as Worker, begin a READ COMMITTED transaction and capture Early's current row version. In A, run Early → Late as above, expect `applied`, capture the winner state after resetting role, and hold the transaction open. In B run the following using the original activity version. The edit would be allowed on the original empty graph and would move Early's finish to the successor's start.

```sql
SELECT version AS row_version FROM public.stage_activities
WHERE workspace_id = :'workspace' AND product_id = :'product' AND id = :'early' \gset
SELECT public.change_activity_dates(:'workspace', :'product', NULL, NULL, :'early',
  :'actor', gen_random_uuid(), DATE '2026-11-09', DATE '2026-11-11',
  'Synthetic date contender after graph confirmation', :'row_version')::text AS date_result \gset
SELECT 1 / COALESCE((:'date_result'::jsonb->>'status' = 'dependency_preview_required'
  AND :'date_result'::jsonb->>'direction' = 'outbound'), false)::int;
```

Observe B waiting before A commits. Confirm the date rejection, commit B, and repeat A's full winner-state equality check. The graph operation leaves the activity row version unchanged, so rejection must come from the current edge rather than a stale row token.

## Calendar versus graph

Use the `calendar` product. A connects directly as Worker. B starts as owner, captures the state with the state script and uses `\set winner_state :fixture_state`, then opens a transaction, assumes the executor role and captures the current preview. Run this case last because the calendar version is shared by all four products.

In A, begin and call the same entry point used by the calendar setup fixture, keeping the transaction open.

```sql
SELECT public.change_workspace_calendar(:'workspace', :'actor', gen_random_uuid(), 0,
  'create', NULL, 'company_shutdown', NULL, NULL, 'Synthetic concurrent closure',
  DATE '2026-11-30', DATE '2026-11-30')::text AS calendar_result \gset
SELECT 1 / COALESCE((:'calendar_result'::jsonb->>'status' = 'created'), false)::int;
```

B attempts Early → Late with its original preview and expects `stale`. Observe B waiting, commit A, then commit B after rejection. On B, capture a fresh preview as executor and confirm that the calendar version moved from 0 to 1 and the schedule version stayed the same. With that fresh fingerprint and schedule version, pass only the old calendar version (0) and expect `stale` again. Commit and compare the full product state with the pre-calendar state as owner. The calendar write must not produce a product schedule mutation.

## Cleanup and evidence

On success or failure, close or roll back both test transactions before role cleanup. If `ON_ERROR_STOP` closes a psql session, reconnect to the same verified child and confirm no test transaction remains open. Remove only the grant issued by `neondb_owner`. Run `phase4b5-concurrency-role-check.sql` in a fresh read-only session with `phase4b5_expect_owner_set=false` to verify the temporary grant is gone, effective SET is false, and the original `cloud_admin` row remains intact. Never issue an unqualified revoke or a revoke with CASCADE. [PostgreSQL REVOKE grantor semantics](https://www.postgresql.org/docs/18/sql-revoke.html)

```sql
BEGIN;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner RESTRICT;
COMMIT;
```

Record winner edge and version deltas, expected statuses, state equality, and privilege cleanup before deleting the verified child. Treat any unexpected status, missing wait, state delta, or permission difference as a failed rehearsal. If SQL or role cleanup verification is blocked, record the failure and still discard the verified child and confirm its absence.
