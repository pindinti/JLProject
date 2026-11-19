import assert from "node:assert/strict";
import console from "node:console";
import { randomInt, randomUUID } from "node:crypto";
import { registerHooks } from "node:module";
import process from "node:process";
import { setTimeout as delay } from "node:timers/promises";
import { URL } from "node:url";
import { Client, neon, neonConfig } from "@neondatabase/serverless";

// Run only against a verified disposable Development child. Synthetic fixtures commit.
const endpoint = process.env.PHASE3_ISOLATED_ENDPOINT;
const { AbortSignal, Headers, Request, Response } = globalThis;
const branch = process.env.PHASE3_ISOLATED_BRANCH;
const parent = process.env.PHASE3_ISOLATED_PARENT;
assert.match(branch ?? "", /^br-[a-z0-9-]+$/);
assert.equal(parent, "br-delicate-glitter-b6mj0051");
assert.notEqual(branch, parent);
assert.match(endpoint ?? "", /^ep-[a-z0-9-]+$/);
function connection(variable, role) {
  const url = URL.parse(process.env[variable] ?? "");
  assert.ok(url?.hostname.startsWith(`${endpoint}.`) && url.username === role && url.pathname === "/neondb",
    "Expected the explicitly verified disposable compute and database role.");
  return url.toString();
}

const ownerUrl = connection("PHASE3_ISOLATED_OWNER_URL", "neondb_owner");
const workerUrl = connection("PHASE3_ISOLATED_WORKER_URL", "jlproject_worker");
const owner = neon(ownerUrl);
const worker = neon(workerUrl);
const workspace = randomUUID();
const foreignWorkspace = randomUUID();
const [left, right, archived, foreign] = Array.from({ length: 4 }, randomUUID);
const [leftActivity, rightActivity] = Array.from({ length: 2 }, randomUUID);
const initialEnd = "2032-02-29";
const start = "2032-02-28";

const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier.startsWith(".") && context.parentURL?.endsWith(".ts") && !/\.[a-z]+$/i.test(specifier)) {
    return nextResolve(`${specifier}.ts`, context);
  }
  return nextResolve(specifier, context);
} });

try {
  const { handleRequest } = await import("../../worker/index.ts");
  hooks.deregister();
  const [writerIdentity, viewerIdentity] = await owner`
    SELECT DISTINCT auth_user_id::text AS id FROM public.workspace_memberships WHERE active ORDER BY id LIMIT 2`;
  assert.ok(writerIdentity && viewerIdentity, "Two existing auth identities are required for synthetic memberships.");
  const writerId = writerIdentity.id;
  const viewerId = viewerIdentity.id;
  await owner.transaction([
    owner`INSERT INTO public.workspaces (id, name) VALUES
      (${workspace}::uuid, 'Synthetic Phase 3 snapshot workspace'), (${foreignWorkspace}::uuid, 'Synthetic Phase 3 foreign workspace')`,
    owner`INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active) VALUES
      (${workspace}::uuid, ${writerId}::uuid, 'admin', true), (${workspace}::uuid, ${viewerId}::uuid, 'viewer', true),
      (${foreignWorkspace}::uuid, ${writerId}::uuid, 'admin', true)`,
    owner`INSERT INTO public.products (id, workspace_id, name, active, planning_classification, created_by, updated_by) VALUES
      (${left}::uuid, ${workspace}::uuid, 'Synthetic left', true, 'vigente', ${writerId}::uuid, ${writerId}::uuid),
      (${right}::uuid, ${workspace}::uuid, 'Synthetic right', true, 'em_estudo', ${writerId}::uuid, ${writerId}::uuid),
      (${archived}::uuid, ${workspace}::uuid, 'Synthetic archived', false, 'vigente', ${writerId}::uuid, ${writerId}::uuid),
      (${foreign}::uuid, ${foreignWorkspace}::uuid, 'Synthetic foreign', true, 'vigente', ${writerId}::uuid, ${writerId}::uuid)`,
    owner`INSERT INTO public.stage_activities (id, workspace_id, product_id, name, planned_start, planned_end,
      display_order, created_by, updated_by) VALUES
      (${leftActivity}::uuid, ${workspace}::uuid, ${left}::uuid, 'Synthetic left activity',
        ${start}::date, ${initialEnd}::date, 0, ${writerId}::uuid, ${writerId}::uuid),
      (${rightActivity}::uuid, ${workspace}::uuid, ${right}::uuid, 'Synthetic right activity',
        ${start}::date, ${initialEnd}::date, 0, ${writerId}::uuid, ${writerId}::uuid)`
  ]);

  const environment = { DATABASE_URL: workerUrl, NEON_AUTH_BASE_URL: "https://identity.example.invalid" };
  const api = (rightId = right, subject = viewerId, method = "GET") => handleRequest(new Request(
    `https://app.example.invalid/api/workspaces/${workspace}/product-comparison?leftProductId=${left}&rightProductId=${rightId}`,
    { method }), environment, async () => ({ subject }));
  async function readPair() {
    const response = await api();
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const { comparison } = await response.json();
    assert.equal(comparison.left.product.status, "vigente");
    assert.equal(comparison.right.product.status, "em_estudo");
    return comparison;
  }
  const ends = (pair) => [pair.left, pair.right].map((side) => side.hierarchy.rootActivities[0].plannedEnd);
  const cursors = (pair) => [pair.left.cursor, pair.right.cursor];
  const baseline = await readPair();
  assert.deepEqual(ends(baseline), [initialEnd, initialEnd]);
  assert.equal((await api(foreign)).status, 404);
  assert.equal((await api(right, randomUUID())).status, 403);
  assert.equal((await api(right, viewerId, "POST")).status, 405);
  const archiveResponse = await api(archived);
  assert.equal(archiveResponse.status, 200);
  assert.equal((await archiveResponse.json()).comparison.right.product.status, "arquivado");
  const [permissions] = await worker`SELECT current_user AS role,
    has_table_privilege(current_user, 'public.product_schedule_state', 'SELECT') AS direct_audit_read,
    has_table_privilege(current_user, 'public.initial_schedule_revisions', 'UPDATE,DELETE') AS r00_write`;
  assert.deepEqual(permissions, { role: "jlproject_worker", direct_audit_read: false, r00_write: false });
  console.log("Live viewer, all statuses, foreign product denial, method denial, and Worker grants passed.");

  async function concurrentRead(before, end, expectedVersion, negativeControl = false) {
    const lock = randomInt(1, 2 ** 31);
    const writer = new Client({ connectionString: workerUrl, connectionTimeoutMillis: 10_000, query_timeout: 20_000 });
    let observedSettings;
    let probeCount = 0;
    let reader;
    await writer.connect();
    try {
      await writer.query("BEGIN");
      await writer.query("SELECT pg_advisory_xact_lock($1::bigint)", [lock]);
      const originalFetch = neonConfig.fetchFunction;
      const send = originalFetch ?? globalThis.fetch;
      neonConfig.fetchFunction = async (input, init) => {
        const body = JSON.parse(init.body);
        if (!body.queries?.[0]?.query.includes("read_product_schedule_cursor")) return send(input, init);
        assert.equal(body.queries.length, 7);
        assert.ok(body.queries.every(({ query }) => /^SELECT\b/.test(query)));
        const headers = new Headers(init.headers);
        assert.equal(headers.get("Neon-Batch-Isolation-Level"), "RepeatableRead");
        assert.equal(headers.get("Neon-Batch-Read-Only"), "true");
        if (negativeControl) headers.set("Neon-Batch-Isolation-Level", "ReadCommitted");
        probeCount++;
        // Pause immediately after the real product/cursor read, before all six schedule reads.
        body.queries.splice(1, 0, { query: "SELECT pg_advisory_xact_lock($1::bigint), " +
          "current_setting('transaction_isolation'), current_setting('transaction_read_only')", params: [String(lock)] });
        const response = await send(input, { ...init, headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
        if (!response.ok) return response;
        const data = await response.json();
        observedSettings = data.results.splice(1, 1)[0].rows[0].slice(1);
        return Response.json(data);
      };
      try {
        reader = readPair().then((pair) => ({ pair }), () => ({ failed: true }));
        let waiting = false;
        for (let attempt = 0; attempt < 30 && !waiting; attempt++) {
          const [row] = await worker`SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_locks
            WHERE locktype = 'advisory' AND classid = 0 AND objid = ${lock}::oid AND objsubid = 1 AND NOT granted) AS waiting`;
          waiting = row.waiting;
          if (!waiting) await delay(150);
        }
        assert.ok(waiting, "The comparison transaction never reached the lock after the cursor query.");
        for (const [product, activity] of [[left, leftActivity], [right, rightActivity]]) {
          const { rows } = await writer.query(
            `SELECT public.change_activity_planning($1::uuid, $2::uuid, NULL, NULL, $3::uuid, $4::uuid,
              $5::uuid, 'manual', $6::date, $7::date, NULL, NULL, $8, $9::bigint) AS result`,
            [workspace, product, activity, writerId, randomUUID(), start, end, "Synthetic concurrent date change", expectedVersion]);
          assert.equal(rows[0]?.result?.status, "updated", "The audited synthetic date change must succeed.");
        }
        await writer.query("COMMIT");
        const outcome = await reader;
        assert.ok(outcome.pair, "The comparison endpoint did not return a successful integrated response.");
        assert.equal(probeCount, 1);
        assert.deepEqual(observedSettings, [negativeControl ? "read committed" : "repeatable read", "on"]);
        assert.deepEqual(cursors(outcome.pair), cursors(before));
        assert.deepEqual(ends(outcome.pair), negativeControl ? [end, end] : ends(before));
      } finally {
        neonConfig.fetchFunction = originalFetch;
      }
    } finally {
      await writer.end();
      if (reader) await reader;
    }
    const after = await readPair();
    assert.deepEqual(ends(after), [end, end]);
    for (const [index, cursor] of cursors(after).entries()) {
      assert.equal(BigInt(cursor.scheduleVersion), BigInt(cursors(before)[index].scheduleVersion) + 1n);
      assert.ok(BigInt(cursor.historyWatermark) > BigInt(cursors(before)[index].historyWatermark));
    }
    return after;
  }

  const after = await concurrentRead(baseline, "2032-03-01", 1);
  console.log("REPEATABLE READ / READ ONLY preserved both old cursors and date rows across an observed writer commit; the next read saw both updates.");
  await concurrentRead(after, "2032-03-02", 2, true);
  console.log("READ COMMITTED negative control reproduced the mixed old-cursor/new-date snapshot.");
} catch (error) {
  // Raw driver errors can contain credentials or business data.
  const detail = error instanceof assert.AssertionError ? error.message.split("\n")[0] : "Database or runner operation failed";
  const code = typeof error?.code === "string" && /^[0-9A-Z]{5}$/.test(error.code) ? ` (SQLSTATE ${error.code})` : "";
  console.error(`${detail}${code}`);
  process.exitCode = 1;
}
