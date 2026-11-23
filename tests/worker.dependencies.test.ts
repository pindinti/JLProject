// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import type { DependencyEntity, DependencySnapshot, FinishToStartDependency } from "../domain/schedule-dependencies";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import { handleDependencyRequest } from "../worker/dependency-api";
import type { DependencyRepository } from "../worker/dependency-repository";
import { handleRequest } from "../worker/index";

const workspaceId = "10000000-0000-0000-0000-000000000001";
const productId = "20000000-0000-0000-0000-000000000002";
const actor = { subject: "30000000-0000-0000-0000-000000000003" };
const other = { subject: "30000000-0000-0000-0000-000000000004" };
const a = "40000000-0000-0000-0000-000000000001";
const b = "40000000-0000-0000-0000-000000000002";
const c = "40000000-0000-0000-0000-000000000003";
const missing = "40000000-0000-0000-0000-000000000004";
const edgeId = "50000000-0000-0000-0000-000000000001";
const route = `https://jlproject.example/api/workspaces/${workspaceId}/products/${productId}/dependencies`;
const environment = { DEPENDENCY_PREVIEW_SIGNING_KEY: "Synthetic-only signing key for dependency tests" };
const justification = "Confirmed dependency scheduling impact";
const fingerprint = "a".repeat(64);
const expectedVersion = "9007199254740993";
const endpoint = (id: string) => ({ kind: "activity" as const, id });
const edge = (predecessor: string, successor: string): FinishToStartDependency => ({ id: edgeId,
  predecessor: { ...endpoint(predecessor), productId }, successor: { ...endpoint(successor), productId } });
const add = (predecessor = a, successor = b) => ({ kind: "add_dependency", predecessor: endpoint(predecessor), successor: endpoint(successor) });

function activity(id: string, date: string): DependencyEntity {
  return { ...endpoint(id), productId, version: 1, dates: { start: date, end: date }, stageId: null, planning: { mode: "manual" } };
}

function fixture(role: WorkspaceRole = "editor", active = true) {
  const snapshot: DependencySnapshot = { productId, scheduleVersion: expectedVersion, calendar: { version: 1, exceptions: [] },
    entities: [activity(a, "2026-11-12"), activity(b, "2026-11-10"), activity(c, "2026-11-11")],
    dependencies: [edge(b, c)], targets: [] };
  const graph: Awaited<ReturnType<DependencyRepository["readGraph"]>> = { status: "ok", graph: {
    productId, status: "vigente", cursor: { scheduleVersion: expectedVersion, historyWatermark: "12" }, edges: [edge(b, c)] } };
  const repository = {
    readGraph: vi.fn<DependencyRepository["readGraph"]>().mockResolvedValue(graph),
    readSnapshot: vi.fn<DependencyRepository["readSnapshot"]>().mockResolvedValue({ status: "ok", snapshot, fingerprint }),
    readReceipt: vi.fn<DependencyRepository["readReceipt"]>().mockResolvedValue({ status: "missing" }),
    confirm: vi.fn<DependencyRepository["confirm"]>().mockImplementation(async (_, operation) =>
      ({ status: "applied", operationId: operation.operationId, scheduleVersion: "9007199254740994" })),
  };
  const memberships: MembershipRepository = { hasAnyActiveMembership: vi.fn(),
    findMembership: vi.fn().mockResolvedValue({ workspaceId, role, active }) };
  const request = (action = "", payload?: unknown, identity: typeof actor | null = actor, origin?: string, url = route) =>
    handleDependencyRequest(new Request(`${url}${action}`, { method: action ? "POST" : "GET",
      headers: { "Content-Type": "application/json", ...(origin ? { Origin: origin } : {}) },
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }) }), identity, memberships, environment, () => repository);
  const preview = (edit: unknown = add(), entityVersion?: number) => request("/preview", { edit, scheduleVersion: expectedVersion,
    ...(entityVersion === undefined ? {} : { entityVersion }) });
  return { repository, snapshot, graph, request, preview };
}

describe("dormant dependency backend", () => {
  it("keeps every dependency route closed at the deployed Worker entry point", async () => {
    const authenticate = vi.fn().mockResolvedValue(actor);
    for (const [method, suffix] of [["GET", ""], ["POST", "/preview"], ["POST", "/confirm"]]) {
      const response = await handleRequest(new Request(`${route}${suffix}`, { method }), { NEON_AUTH_BASE_URL: "https://auth.example" }, authenticate);
      expect(response.status).toBe(404);
    }
    expect(authenticate).not.toHaveBeenCalled();
  });

  it("allows a viewer to read the scoped archived graph and rejects missing authentication, inactive membership and a foreign origin", async () => {
    const f = fixture("viewer");
    f.repository.readGraph.mockResolvedValue({ ...f.graph, graph: { ...f.graph.graph, status: "arquivado" } });
    const read = await f.request();
    expect(read.status).toBe(200);
    expect(read.headers.get("Cache-Control")).toBe("no-store");
    expect(await read.json()).toMatchObject({ graph: { status: "arquivado", productId } });
    expect(f.repository.readGraph).toHaveBeenCalledWith({ workspaceId, productId, actorId: actor.subject });
    expect((await f.request("", undefined, null)).status).toBe(401);
    expect((await f.request("", undefined, actor, "https://different.example")).status).toBe(403);
    expect((await fixture("editor", false).request()).status).toBe(403);
    expect((await f.preview()).status).toBe(403);
    expect(f.repository.readSnapshot).not.toHaveBeenCalled();
  });

  it("bounds payloads and rejects out-of-scope products and archived mutations", async () => {
    const f = fixture();
    f.repository.readGraph.mockResolvedValue({ status: "not_found" });
    expect((await f.request()).status).toBe(404);
    f.repository.readSnapshot.mockResolvedValue({ status: "archived" });
    expect((await f.preview()).status).toBe(409);
    expect((await f.request("/preview", { edit: "x".repeat(9000), scheduleVersion: expectedVersion })).status).toBe(400);
    expect((await f.preview({ ...add(), predecessor: { ...endpoint(a), productId: "other" } })).status).toBe(400);
    expect(f.repository.confirm).not.toHaveBeenCalled();
  });

  it("reports duplicate, cyclic, mixed and missing endpoints with no confirmation token", async () => {
    const f = fixture();
    for (const [edit, code] of [
      [add(b, c), "duplicate_dependency"], [add(c, b), "cycle"], [add(a, a), "self_link"], [add(a, missing), "invalid_endpoint"],
    ] as const) {
      const res = await f.preview(edit);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.preview).toMatchObject({ status: "blocked", blockers: [expect.objectContaining({ code })] });
      expect(body).not.toHaveProperty("token");
    }
    f.repository.readSnapshot.mockResolvedValue({ status: "ok", fingerprint, snapshot: { ...f.snapshot,
      entities: [...f.snapshot.entities, { kind: "stage", id: missing, productId, version: 1, dates: { start: null, end: null } }] } });
    const mixed = await f.preview({ ...add(), successor: { kind: "stage", id: missing } });
    expect(await mixed.json()).toMatchObject({ preview: { blockers: [{ code: "mixed_endpoints" }] } });
    expect(f.repository.confirm).not.toHaveBeenCalled();
  });

  it("recomputes an add and sends all cascading date updates with the edge in one database call", async () => {
    const f = fixture("admin");
    const { preview, token } = await (await f.preview()).json();
    expect(preview.status).toBe("ready");
    expect(f.repository.confirm).not.toHaveBeenCalled();
    const response = await f.request("/confirm", { token, justification });
    expect(await response.json()).toMatchObject({ status: "applied", scheduleVersion: "9007199254740994" });
    expect(f.repository.readSnapshot).toHaveBeenCalledTimes(2);
    expect(f.repository.confirm).toHaveBeenCalledExactlyOnceWith({ workspaceId, productId, actorId: actor.subject },
      expect.objectContaining({ scheduleVersion: expectedVersion, calendarVersion: 1, justification, fingerprint,
        dependencyChange: preview.dependencyChange, dateChanges: [
          expect.objectContaining({ source: "cascade", entity: endpointWithProduct(b), expectedVersion: 1,
            before: { start: "2026-11-10", end: "2026-11-10" }, after: { start: "2026-11-13", end: "2026-11-13" } }),
          expect.objectContaining({ source: "cascade", entity: endpointWithProduct(c), expectedVersion: 1,
            before: { start: "2026-11-11", end: "2026-11-11" }, after: { start: "2026-11-16", end: "2026-11-16" } }),
        ] }));
  });

  it("confirms removal without moving dates and previews unrelated date edits as direct only", async () => {
    const f = fixture();
    const { token } = await (await f.preview({ kind: "remove_dependency", dependencyId: edgeId })).json();
    expect((await f.request("/confirm", { token, justification })).status).toBe(200);
    expect(f.repository.confirm.mock.calls[0][1]).toMatchObject({ dependencyChange: { kind: "remove", dependency: edge(b, c) }, dateChanges: [] });
    const edit = { kind: "edit_dates", entity: endpoint(a), dates: { start: "2026-11-13", end: "2026-11-13" } };
    expect((await f.preview(edit, 2)).status).toBe(409);
    expect(await (await f.preview(edit, 1)).json()).toMatchObject({ preview: { status: "ready", dateChanges: [
      { entity: endpointWithProduct(a), source: "direct" },
    ] } });
  });

  it("rejects forged tokens, wrong actors, wrong products, and invalid justification before any write", async () => {
    const f = fixture();
    const { token } = await (await f.preview()).json();
    expect((await f.request("/confirm", { token: `${token}bad`, justification })).status).toBe(409);
    expect((await f.request("/confirm", { token, justification }, other)).status).toBe(409);
    expect((await f.request("/confirm", { token, justification }, actor, undefined,
      route.replace(productId, "20000000-0000-0000-0000-000000000099"))).status).toBe(409);
    expect((await f.request("/confirm", { token, justification: "short" })).status).toBe(400);
    expect((await f.request("/confirm", { token, justification: "Invalid\u0000confirmation reason" })).status).toBe(400);
    expect(f.repository.readReceipt).not.toHaveBeenCalled();
    expect(f.repository.confirm).not.toHaveBeenCalled();
  });

  it("expires a preview token before checking receipts or attempting writes", async () => {
    const f = fixture();
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      vi.setSystemTime(new Date("2026-11-19T12:00:00Z"));
      const { token } = await (await f.preview()).json();
      vi.setSystemTime(new Date("2026-11-19T12:05:01Z"));
      expect((await f.request("/confirm", { token, justification })).status).toBe(409);
      expect(f.repository.readReceipt).not.toHaveBeenCalled();
      expect(f.repository.confirm).not.toHaveBeenCalled();
    } finally { vi.useRealTimers(); }
  });

  it("rejects a stale schedule, calendar, graph or result after the preview was issued", async () => {
    const f = fixture();
    const { token } = await (await f.preview()).json();
    for (const [snapshot, tag] of [
      [{ ...f.snapshot, scheduleVersion: "9007199254740994" }, fingerprint],
      [{ ...f.snapshot, calendar: { version: 2, exceptions: [] } }, fingerprint],
      [{ ...f.snapshot, dependencies: [] }, "b".repeat(64)],
      [{ ...f.snapshot, entities: [activity(a, "2026-11-13"), ...f.snapshot.entities.slice(1)] }, fingerprint],
    ] as const) {
      f.repository.readSnapshot.mockResolvedValue({ status: "ok", snapshot, fingerprint: tag });
      expect((await f.request("/confirm", { token, justification })).status).toBe(409);
    }
    expect(f.repository.confirm).not.toHaveBeenCalled();
  });

  it("honors a concurrent database winner and recognizes an identical retry without another write", async () => {
    const f = fixture();
    const first = await (await f.preview()).json();
    const second = await (await f.preview()).json();
    let committed: string | null = null;
    f.repository.confirm.mockImplementation(async (_, operation) => {
      if (committed) return { status: "stale" };
      committed = operation.operationId;
      return { status: "applied", operationId: committed, scheduleVersion: "9007199254740994" };
    });
    const results = await Promise.all([f.request("/confirm", { token: first.token, justification }),
      f.request("/confirm", { token: second.token, justification })]);
    expect(results.map(({ status }) => status).sort()).toEqual([200, 409]);
    const winner = results[0].status === 200 ? first : second;
    f.repository.readReceipt.mockResolvedValue({ status: "replayed", operationId: committed!, scheduleVersion: "9007199254740994" });
    expect(await (await f.request("/confirm", { token: winner.token, justification })).json()).toMatchObject({ status: "replayed" });
    expect(f.repository.confirm).toHaveBeenCalledTimes(2);
  });

  it("fails closed on an atomic database error and does not split or retry the write", async () => {
    const f = fixture();
    const { token } = await (await f.preview()).json();
    f.repository.confirm.mockRejectedValue(new Error("Synthetic audit failure"));
    const response = await f.request("/confirm", { token, justification });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Serviço indisponível." });
    expect(f.repository.confirm).toHaveBeenCalledTimes(1);
  });
});

function endpointWithProduct(id: string) { return { ...endpoint(id), productId }; }
