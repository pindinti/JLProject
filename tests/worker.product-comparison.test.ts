// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { scheduleStageInterval } from "../domain/schedule-workspace";
import { handleRequest } from "../worker/index";
import type { WorkspaceMembership } from "../worker/authorization";
import { comparisonEntityLimit, type ProductComparison } from "../worker/product-comparison";

const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const foreignWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const leftId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const rightId = "d5555555-5555-4555-8555-555555555555";
const endpoint = `https://app.test/api/workspaces/${workspace}/product-comparison`;
const url = `${endpoint}?leftProductId=${leftId}&rightProductId=${rightId}`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.test", DATABASE_URL: "postgresql://worker:test@db.example.test/neondb" };
const viewer: WorkspaceMembership = { workspaceId: workspace, role: "viewer", active: true };

function request(options: { request?: Request; membership?: WorkspaceMembership | null; authenticated?: boolean } = {}) {
  return handleRequest(options.request ?? new Request(url), environment,
    async () => options.authenticated === false ? null : { subject: actor }, () => ({
      hasAnyActiveMembership: async () => true,
      findMembership: async () => options.membership === undefined ? viewer : options.membership
    }));
}

type Row = Record<string, string | number | boolean | null>;
function raw(rows: Row[]) {
  const fields = Object.entries(rows[0] ?? {}).map(([name, value]) => ({ name,
    dataTypeID: typeof value === "boolean" ? 16 : typeof value === "number" ? 23 : 25 }));
  return { fields, rows: rows.map((row) => fields.map(({ name }) => {
    const value = row[name];
    return value == null ? null : typeof value === "boolean" ? value ? "t" : "f" : String(value);
  })) };
}

function product(id: string, active = true, planningClassification = "vigente") {
  return { id, active, planningClassification, workspaceId: workspace, name: `Product ${id}`,
    description: null, version: 4, scheduleVersion: "7", historyWatermark: "9007199254740993",
    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-02-01T00:00:00Z" };
}

const empty = [{ disciplineId: null }];
const activity = { id: "root", stageId: null, name: "Root activity", activityType: null, notes: null,
  plannedStart: "2026-03-01", plannedEnd: "2026-03-04", displayOrder: 0, colorOverride: null, version: 3,
  planningMode: "working_days", workingDayDuration: 3, planningCalendarVersion: 4 };
const stageRow = { disciplineId: "discipline", disciplineName: "Discipline", disciplineCode: "D", disciplineColor: "#778899",
  disciplineOrder: 0, disciplineDescription: null, disciplineVersion: 1,
  stageId: "stage", stageCode: "S", stageColor: "#778899", stageName: "Stage", stageOrder: 0, stageVersion: 1,
  stagePlannedStart: "2026-03-02", stagePlannedEnd: null, activityId: "nested", activityName: "Nested activity",
  activityNotes: null, activityType: null, plannedStart: "2026-03-01", plannedEnd: "2026-03-04", activityOrder: 0,
  activityColorOverride: null, activityVersion: 1, planningMode: "manual", workingDayDuration: null, planningCalendarVersion: null };
const target = { id: "target", name: "Target", description: null, color: "#778899", targetDate: "2026-03-10",
  operationalDate: null, displayOrder: 0, version: 2 };

function mockBatch(results: Row[][]) {
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(Response.json({ results: results.map(raw) }));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => vi.unstubAllGlobals());

describe("product comparison Worker API", () => {
  it("returns both schedules and cursors through one read-only repeatable-read batch", async () => {
    const fetchMock = mockBatch([[product(rightId, false), product(leftId)], [stageRow], [activity], [target], empty, [], []]);
    const response = await request();
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const { comparison }: { comparison: ProductComparison } = await response.json();
    expect(comparison.left.product).toMatchObject({ id: leftId, name: `Product ${leftId}`, status: "vigente", version: 4 });
    expect(comparison.left.cursor).toEqual({ scheduleVersion: "7", historyWatermark: "9007199254740993" });
    expect(comparison.left.hierarchy.rootActivities).toEqual([activity]);
    expect(comparison.left.targets).toEqual([target]);
    const stage = comparison.left.hierarchy.disciplines[0].stages[0];
    expect(stage).toMatchObject({ plannedStart: "2026-03-02", plannedEnd: null, derivedStart: "2026-03-01", derivedEnd: "2026-03-04" });
    expect(scheduleStageInterval(stage)).toEqual({ start: "2026-03-02", end: null, source: "planned" });
    expect(comparison.right.product).toMatchObject({ id: rightId, status: "arquivado", version: 4 });
    expect(comparison.right.hierarchy).toEqual({ productId: rightId, disciplines: [], rootActivities: [] });
    expect(comparison.right.targets).toEqual([]);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const init = fetchMock.mock.calls[0]?.[1];
    expect(new Headers(init?.headers).get("Neon-Batch-Isolation-Level")).toBe("RepeatableRead");
    expect(new Headers(init?.headers).get("Neon-Batch-Read-Only")).toBe("true");
    const { queries }: { queries: { query: string; params: (string | number)[] }[] } = JSON.parse(String(init?.body));
    expect(queries).toHaveLength(7);
    expect(queries[0].query).toContain("read_product_schedule_cursor");
    expect(queries[0].params).toEqual([actor, workspace, leftId, rightId]);
    for (const [index, query] of queries.entries()) {
      expect(query.query).toMatch(/^SELECT\b/);
      expect(query.query).not.toMatch(/\b(insert|update|delete|truncate|set_config|for\s+update)\b/i);
      if (index > 0) {
        expect(query.params.map(String)).toEqual([workspace, index <= 3 ? leftId : rightId, String(comparisonEntityLimit + 1)]);
        expect(query.query).toContain("deleted_at IS NULL");
      }
    }
  });

  it("supports studies and keeps derived stage dates available when both explicit dates are absent", async () => {
    mockBatch([[product(leftId, true, "em_estudo"), product(rightId)],
      [{ ...stageRow, stagePlannedStart: null }], [], [], empty, [], []]);
    const response = await request();
    expect(response.status).toBe(200);
    const { comparison }: { comparison: ProductComparison } = await response.json();
    expect(comparison.left.product.status).toBe("em_estudo");
    expect(scheduleStageInterval(comparison.left.hierarchy.disciplines[0].stages[0]))
      .toEqual({ start: "2026-03-01", end: "2026-03-04", source: "derived" });
  });

  it("rejects unauthenticated, inactive, and foreign workspace access and non-GET requests", async () => {
    const fetchMock = mockBatch([]);
    for (const [options, status] of [
      [{ authenticated: false }, 401], [{ membership: null }, 403],
      [{ membership: { ...viewer, active: false } }, 403],
      [{ membership: { ...viewer, workspaceId: foreignWorkspace } }, 403],
      [{ request: new Request(url, { method: "POST" }) }, 405],
      [{ request: new Request(url.replace(rightId, leftId.toUpperCase())) }, 400],
      [{ request: new Request(`${url}&rightProductId=${rightId}`) }, 400],
      [{ request: new Request(url.replace(rightId, "invalid")) }, 400]
    ] as const) {
      const response = await request(options);
      expect(response.status).toBe(status);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("returns the same 404 for a missing product and a product outside the supplied workspace", async () => {
    for (const products of [[product(leftId)], [product(leftId), { ...product(rightId), workspaceId: foreignWorkspace }]]) {
      mockBatch([products, empty, [], [], [], [], []]);
      const response = await request();
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "Produto não encontrado." });
    }
  });

  it.each(["combined", "one collection", "nested hierarchy"])("rejects an oversized %s without a partial response", async (kind) => {
    const length = kind === "combined" ? comparisonEntityLimit : kind === "one collection" ?
      comparisonEntityLimit + 1 : comparisonEntityLimit - 2;
    const roots = Array.from({ length },
      (_, index) => ({ ...activity, id: `root-${index}` }));
    mockBatch([[product(leftId), product(rightId)], kind === "nested hierarchy" ? [stageRow] : empty,
      roots, [], empty, [], kind === "combined" ? [target] : []]);
    const response = await request();
    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ code: "comparison_too_large",
      error: "Os cronogramas excedem o limite de tamanho para comparação.", maxEntities: comparisonEntityLimit });
  });

  it("returns all entities at the exact limit", async () => {
    const roots = Array.from({ length: comparisonEntityLimit }, (_, index) => ({ ...activity, id: `root-${index}` }));
    mockBatch([[product(leftId), product(rightId)], empty, roots, [], empty, [], []]);
    const response = await request();
    expect(response.status).toBe(200);
    const { comparison }: { comparison: ProductComparison } = await response.json();
    expect(comparison.left.hierarchy.rootActivities).toHaveLength(comparisonEntityLimit);
  });
});
