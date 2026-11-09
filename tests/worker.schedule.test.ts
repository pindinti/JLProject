// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import { assembleHierarchy, type ScheduleRepository } from "../worker/schedule-repository";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const ws = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWs = "d441363c-bdde-4422-93d6-59b3868d29f4";
const product = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const discipline = "d4444444-4444-4444-8444-444444444444";
const stage = "a5555555-5555-4555-8555-555555555555";
const activity = "a6666666-6666-4666-8666-666666666666";
const targetId = "f7777777-7777-4777-8777-777777777777";
const base = `https://app.test/api/workspaces/${ws}/products/${product}`;
const disciplines = `${base}/disciplines`;
const stages = `${disciplines}/${discipline}/stages`;
const activities = `${stages}/${stage}/activities`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const d = { id: discipline, productId: product, name: "Arquitetura", shortCode: "ARQ",
  color: "#112233", displayOrder: 0, description: null, version: 1 };
const s = { id: stage, disciplineId: discipline, code: "EC", color: "#445566",
  displayName: "Estudo conceitual", displayOrder: 0, version: 1, derivedStart: null, derivedEnd: null };
const a = { id: activity, stageId: stage, name: "Tarefa sintética", activityType: null,
  plannedStart: "2026-11-01", plannedEnd: "2026-11-05", displayOrder: 0, notes: null, version: 1 };

function repository(): ScheduleRepository {
  return {
    listStageDefinitions: vi.fn(async () => [{ id: "a9999999-9999-4999-8999-999999999999", code: "EC", color: "#445566" }]),
    updateStageDefinitionColor: vi.fn(async (_workspaceId, definitionId, _expectedColor, color) => ({
      status: "ok" as const, value: { id: definitionId, code: "EC", color }
    })),
    productExists: vi.fn(async () => true), disciplineExists: vi.fn(async () => true),
    stageExists: vi.fn(async () => true), activityExists: vi.fn(async () => true),
    listDisciplines: vi.fn(async () => [d]), createDiscipline: vi.fn(async () => ({ status: "ok" as const, value: d })),
    updateDiscipline: vi.fn(async () => ({ status: "ok" as const, value: { ...d, version: 2 } })),
    listStages: vi.fn(async () => [s]), createStage: vi.fn(async () => ({ status: "ok" as const, value: s })),
    updateStage: vi.fn(async () => ({ status: "ok" as const, value: { ...s, version: 2 } })),
    listActivities: vi.fn(async () => [a]), createActivity: vi.fn(async () => ({ status: "ok" as const, value: a })),
    updateActivity: vi.fn(async () => ({ status: "ok" as const, value: { ...a, version: 2 } })),
    changeActivityDates: vi.fn(async () => ({ status: "updated" as const,
      activity: { ...a, plannedStart: "2026-11-02", version: 2 } })),
    listActivityDateHistory: vi.fn(async () => []),
    getHierarchy: vi.fn(async () => ({ productId: product, disciplines: [{ ...d, stages: [{ ...s, activities: [a] }] }] })),
    listTargets: vi.fn(async () => [{ id: "f7777777-7777-4777-8777-777777777777", name: "Meta sintética",
      description: null, color: "#AA4557", targetDate: "2026-11-08", operationalDate: null, displayOrder: 0, version: 1 }]),
    createTarget: vi.fn(async (_ws, _product, _actor, input) => ({ status: "ok" as const,
      value: { id: "f8888888-8888-4888-8888-888888888888", ...input, operationalDate: null, displayOrder: 1, version: 1 } })),
    updateTarget: vi.fn(async (_ws, _product, id, _actor, input) => ({ status: "ok" as const,
      value: { id, ...input, operationalDate: null, displayOrder: 0, version: 2 } })),
    deleteTarget: vi.fn(async () => ({ status: "ok" as const,
      value: { id: "f7777777-7777-4777-8777-777777777777" } as never }))
  };
}
function membership(role: WorkspaceRole | null, active = true): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => !!role && active,
    findMembership: async (id, workspaceId) => id === actor && workspaceId === ws && role
      ? { workspaceId: ws, role, active } : null
  };
}
function request(path: string, method = "GET", data?: unknown): Request {
  return new Request(path, { method, ...(data === undefined ? {} : {
    headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  }) });
}
async function call(input: Request, role: WorkspaceRole | null, repo = repository(), active = true) {
  return handleRequest(input, environment, async () => ({ subject: actor }),
    () => membership(role, active), undefined, undefined, () => repo);
}

describe("schedule hierarchy API", () => {
  it("scopes read-only targets to an authenticated product member", async () => {
    const repo = repository();
    const path = `${base}/targets`;
    const listed = await call(request(path), "viewer", repo);
    expect(listed.status).toBe(200);
    await expect(listed.json()).resolves.toMatchObject({ targets: [{ targetDate: "2026-11-08" }] });
    expect(repo.listTargets).toHaveBeenCalledWith(ws, product);
    expect((await call(request(path, "POST", {}), "admin", repo)).status).toBe(400);
    expect((await call(request(path.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect((await call(request(path), "admin", repo, false)).status).toBe(403);
    expect((await call(request(path), "admin", { ...repo, productExists: async () => false })).status).toBe(404);
    const anonymous = await handleRequest(request(path), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
  });

  it("creates, edits, and soft-deletes targets only for active editors with scoped identities", async () => {
    const repo = repository();
    const path = `${base}/targets`;
    const input = { name: "Synthetic milestone", description: "Synthetic description",
      targetDate: "2026-11-09", color: "#336699" };
    expect((await call(request(path, "POST", input), "viewer", repo)).status).toBe(403);
    const created = await call(request(path, "POST", input), "editor", repo);
    expect(created.status).toBe(201);
    expect(repo.createTarget).toHaveBeenCalledWith(ws, product, actor, input);
    const updated = await call(request(`${path}/${targetId}`, "PATCH", {
      ...input, name: "Renamed synthetic milestone", targetDate: "2026-11-10",
      version: 1, reason: "Synthetic date correction"
    }), "admin", repo);
    expect(updated.status).toBe(200);
    expect(repo.updateTarget).toHaveBeenCalledWith(ws, product, targetId, actor,
      { ...input, name: "Renamed synthetic milestone", targetDate: "2026-11-10" }, 1,
      "Synthetic date correction", expect.any(String));
    expect((await call(request(`${path}/${targetId}`, "DELETE", { version: 2 }), "editor", repo)).status).toBe(200);
    expect(repo.deleteTarget).toHaveBeenCalledWith(ws, product, targetId, actor, 2, expect.any(String));
    expect((await call(request(`${path}/${targetId}`, "PATCH", input), "viewer", repo)).status).toBe(403);
    expect((await call(request(`${path}/${targetId}`, "DELETE", { version: 1 }), "admin", repo, false)).status).toBe(403);
    expect((await call(request(`${path}/${targetId}`.replace(ws, otherWs), "PATCH", input), "admin", repo)).status).toBe(403);
  });

  it("validates target input and hides persistence errors", async () => {
    const repo = repository();
    const path = `${base}/targets`;
    for (const value of [
      { name: " ", targetDate: "2026-11-09", color: "#112233" },
      { name: "Synthetic", targetDate: "2026-02-30", color: "#112233" },
      { name: "Synthetic", targetDate: "2026-11-09", color: "red" },
      { name: "Synthetic", targetDate: "2026-11-09", color: "#112233", userId: actor }
    ]) expect((await call(request(path, "POST", value), "admin", repo)).status).toBe(400);
    expect(repo.createTarget).not.toHaveBeenCalled();
    expect((await call(request(`${path}/bad`, "PATCH", {}), "admin", repo)).status).toBe(400);
    const failed = await call(request(`${path}/${targetId}`, "PATCH", {
      name: "Synthetic", description: null, targetDate: "2026-11-09", color: "#112233",
      version: 1, reason: null
    }), "admin", { ...repo, updateTarget: async () => { throw new Error("private sql detail"); } });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private sql detail");
  });
  it("reads lists and the complete hierarchy for active viewers", async () => {
    const repo = repository();
    for (const [path, key] of [[disciplines, "disciplines"], [stages, "stages"],
      [activities, "activities"], [`${base}/hierarchy`, "hierarchy"]] as const) {
      const response = await call(request(path), "viewer", repo);
      expect(response.status).toBe(200);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      expect(await response.json()).toHaveProperty(key);
    }
    expect(repo.productExists).toHaveBeenCalledWith(ws, product, false);
    expect(repo.disciplineExists).toHaveBeenCalledWith(ws, product, discipline, false);
    expect(repo.stageExists).toHaveBeenCalledWith(ws, product, discipline, stage, false);
  });

  it("lists workspace stage definitions without granting catalog writes", async () => {
    const repo = repository();
    const path = `https://app.test/api/workspaces/${ws}/stage-definitions`;
    const listed = await call(request(path), "viewer", repo);
    expect(listed.status).toBe(200);
    await expect(listed.json()).resolves.toMatchObject({ stageDefinitions: [{ code: "EC", color: "#445566" }] });
    expect(repo.listStageDefinitions).toHaveBeenCalledWith(ws);
    expect((await call(request(path, "POST", {}), "admin", repo)).status).toBe(405);
    expect((await call(request(path.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
  });

  it("updates only a workspace-scoped shared stage color for active editors and admins", async () => {
    const repo = repository();
    const definitionId = "a9999999-9999-4999-8999-999999999999";
    const path = `https://app.test/api/workspaces/${ws}/stage-definitions/${definitionId}`;
    const input = { expectedColor: "#445566", color: "#AA5577" };

    for (const role of ["admin", "editor"] as const) {
      const response = await call(request(path, "PATCH", input), role, repo);
      expect(response.status).toBe(200);
      await expect(response.json()).resolves.toMatchObject({ stageDefinition: { id: definitionId, code: "EC", color: "#AA5577" } });
    }
    expect(repo.updateStageDefinitionColor).toHaveBeenCalledWith(ws, definitionId, "#445566", "#AA5577");
    expect(repo.updateStage).not.toHaveBeenCalled();
    expect(repo.changeActivityDates).not.toHaveBeenCalled();
    expect((await call(request(path, "PATCH", input), "viewer", repo)).status).toBe(403);
    expect((await call(request(path, "PATCH", input), null, repo)).status).toBe(403);
    expect((await call(request(path, "PATCH", input), "editor", repo, false)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs), "PATCH", input), "admin", repo)).status).toBe(403);
    expect((await call(request(path.replace(definitionId, "bad"), "PATCH", input), "admin", repo)).status).toBe(400);
    expect((await call(request(path, "PATCH", { ...input, color: "blue" }), "admin", repo)).status).toBe(400);
    expect((await call(request(path, "PATCH", { ...input, unexpected: true }), "admin", repo)).status).toBe(400);
    expect((await call(request(path, "POST", input), "admin", repo)).status).toBe(405);

    const anonymous = await handleRequest(request(path, "PATCH", input), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
  });

  it("returns safe stale, missing, and persistence errors for shared color edits", async () => {
    const definitionId = "a9999999-9999-4999-8999-999999999999";
    const path = `https://app.test/api/workspaces/${ws}/stage-definitions/${definitionId}`;
    const input = { expectedColor: "#445566", color: "#AA5577" };
    for (const [result, status] of [[{ status: "stale" }, 409], [{ status: "not_found" }, 404]] as const) {
      const response = await call(request(path, "PATCH", input), "editor", {
        ...repository(), updateStageDefinitionColor: async () => result
      });
      expect(response.status).toBe(status);
      expect(await response.text()).not.toContain("SQL");
    }
    const failed = await call(request(path, "PATCH", input), "admin", {
      ...repository(), updateStageDefinitionColor: async () => { throw new Error("private SQL detail"); }
    });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });

  it("creates each level only for an editor or admin and uses verified identity", async () => {
    const repo = repository();
    const disciplineInput = { name: "Arquitetura", shortCode: "ARQ", color: "#112233", displayOrder: 0 };
    const stageInput = { code: "EC", color: "#445566", displayName: "Estudo conceitual", displayOrder: 0 };
    const activityInput = { name: "Tarefa sintética", plannedStart: "2026-11-01", plannedEnd: "2026-11-05", displayOrder: 0 };
    expect((await call(request(disciplines, "POST", disciplineInput), "admin", repo)).status).toBe(201);
    expect(repo.createDiscipline).toHaveBeenCalledWith(ws, product, actor, { ...disciplineInput, description: null });
    expect((await call(request(stages, "POST", stageInput), "editor", repo)).status).toBe(201);
    expect(repo.createStage).toHaveBeenCalledWith(ws, product, discipline, actor, stageInput);
    expect((await call(request(activities, "POST", activityInput), "editor", repo)).status).toBe(201);
    expect(repo.createActivity).toHaveBeenCalledWith(ws, product, discipline, stage, actor,
      { ...activityInput, activityType: null, notes: null });
  });

  it("rejects unauthenticated, inactive, viewer writes, and cross-workspace access", async () => {
    const repo = repository();
    const unauthenticated = await handleRequest(request(disciplines), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(unauthenticated.status).toBe(401);
    expect((await call(request(disciplines), null, repo)).status).toBe(403);
    expect((await call(request(disciplines), "admin", repo, false)).status).toBe(403);
    expect((await call(request(disciplines, "POST", {}), "viewer", repo)).status).toBe(403);
    expect((await call(request(disciplines.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect(repo.createDiscipline).not.toHaveBeenCalled();
  });

  it("rejects foreign or unknown parents before touching children", async () => {
    const repo = repository();
    expect((await call(request(stages), "admin", { ...repo, disciplineExists: async () => false })).status).toBe(404);
    expect((await call(request(activities), "admin", { ...repo, stageExists: async () => false })).status).toBe(404);
    expect((await call(request(disciplines), "admin", { ...repo, productExists: async () => false })).status).toBe(404);
    expect((await call(request(`${base.replace(product, "bad")}/hierarchy`), "admin", repo)).status).toBe(400);
    expect(repo.listStages).not.toHaveBeenCalled();
    expect(repo.listActivities).not.toHaveBeenCalled();
  });

  it("validates civil dates and forbids any update to planned dates", async () => {
    const repo = repository();
    for (const dates of [
      { plannedStart: "2026-02-30", plannedEnd: "2026-03-01" },
      { plannedStart: "2026-11-05", plannedEnd: "2026-11-01" },
      { plannedStart: "2026-11-01", plannedEnd: null }
    ]) {
      expect((await call(request(activities, "POST", { name: "Teste", displayOrder: 0, ...dates }), "editor", repo)).status).toBe(400);
    }
    expect((await call(request(`${activities}/${activity}`, "PATCH", {
      name: "Teste", displayOrder: 0, plannedStart: "2026-11-02", version: 1
    }), "editor", repo)).status).toBe(400);
    expect(repo.updateActivity).not.toHaveBeenCalled();
  });

  it("audits valid date edits through a verified actor and rejects stale or unchanged results safely", async () => {
    const repo = repository();
    const path = `${activities}/${activity}/dates`;
    const input = { plannedStart: "2026-11-02", plannedEnd: "2026-11-06",
      reason: "Synthetic schedule correction", version: 1 };
    const changed = await call(request(path, "PATCH", { ...input, actorId: "forged" }), "editor", repo);
    expect(changed.status).toBe(400);
    const valid = await call(request(path, "PATCH", input), "editor", repo);
    expect(valid.status).toBe(200);
    await expect(valid.json()).resolves.toMatchObject({ changed: true, activity: { plannedStart: "2026-11-02" } });
    expect(repo.changeActivityDates).toHaveBeenCalledWith(ws, product, discipline, stage, activity, actor,
      input.plannedStart, input.plannedEnd, input.reason, 1, expect.any(String));
    const stale = await call(request(path, "PATCH", input), "admin", {
      ...repo, changeActivityDates: async () => ({ status: "stale" }) });
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("database");
    const unchanged = await call(request(path, "PATCH", { ...input, reason: null }), "admin", {
      ...repo, changeActivityDates: async () => ({ status: "unchanged", activity: a }) });
    expect(unchanged.status).toBe(200);
    await expect(unchanged.json()).resolves.toMatchObject({ changed: false });
  });

  it("validates date and reason inputs without calling the date operation", async () => {
    const repo = repository();
    const path = `${activities}/${activity}/dates`;
    for (const input of [
      { plannedStart: "2026-02-30", plannedEnd: "2026-03-01", reason: "Synthetic correction", version: 1 },
      { plannedStart: "2026-11-06", plannedEnd: "2026-11-01", reason: "Synthetic correction", version: 1 },
      { plannedStart: "2026-11-02", plannedEnd: "2026-11-06", reason: "short", version: 1 },
      { plannedStart: "2026-11-02", plannedEnd: "2026-11-06", reason: "Synthetic correction", version: 0 },
      { plannedStart: "2026-11-02", plannedEnd: "2026-11-06", reason: "Synthetic correction", version: 1,
        operationId: "forged" }
    ]) expect((await call(request(path, "PATCH", input), "admin", repo)).status).toBe(400);
    expect(repo.changeActivityDates).not.toHaveBeenCalled();
    const missingReason = await call(request(path, "PATCH", {
      plannedStart: "2026-11-02", plannedEnd: "2026-11-06", version: 1
    }), "admin", { ...repo, changeActivityDates: async () => ({ status: "invalid" }) });
    expect(missingReason.status).toBe(400);
  });

  it("scopes date writes and history to active workspace membership and activity ownership", async () => {
    const repo = repository();
    const path = `${activities}/${activity}/dates`;
    const history = `${activities}/${activity}/date-history`;
    const input = { plannedStart: "2026-11-02", plannedEnd: "2026-11-06",
      reason: "Synthetic correction", version: 1 };
    expect((await call(request(path, "PATCH", input), "viewer", repo)).status).toBe(403);
    expect((await call(request(path, "PATCH", input), "admin", repo, false)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs), "PATCH", input), "admin", repo)).status).toBe(403);
    expect((await call(request(path, "PATCH", input), "admin", {
      ...repo, activityExists: async () => false })).status).toBe(404);
    expect((await call(request(history), "viewer", repo)).status).toBe(200);
    expect(repo.listActivityDateHistory).toHaveBeenCalledWith(ws, product, discipline, stage, activity);
    expect((await call(request(history), "admin", { ...repo, activityExists: async () => false })).status).toBe(404);
    expect((await call(request(history.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect((await call(request(history, "POST", {}), "admin", repo)).status).toBe(405);
    const anonymous = await handleRequest(request(path, "PATCH", input), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect(repo.changeActivityDates).toHaveBeenCalledTimes(0);
  });

  it("returns a generic service error if the atomic date operation fails", async () => {
    const repo = repository();
    const path = `${activities}/${activity}/dates`;
    const failed = await call(request(path, "PATCH", { plannedStart: "2026-11-02",
      plannedEnd: "2026-11-06", reason: "Synthetic correction", version: 1 }), "admin", {
      ...repo, changeActivityDates: async () => { throw new Error("private audit constraint detail"); }
    });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private audit constraint detail");
  });

  it("checks versions on metadata updates and reports stale results", async () => {
    const repo = repository();
    const input = { name: "Arquitetura", shortCode: "ARQ", color: "#112233", displayOrder: 0, version: 1 };
    expect((await call(request(`${disciplines}/${discipline}`, "PATCH", input), "editor", repo)).status).toBe(200);
    expect(repo.updateDiscipline).toHaveBeenCalledWith(ws, product, discipline, actor,
      { name: "Arquitetura", shortCode: "ARQ", color: "#112233", displayOrder: 0, description: null }, 1);
    expect((await call(request(`${stages}/${stage}`, "PATCH", {
      code: "EC", color: "#445566", displayName: "Estudo", displayOrder: 0, version: 1
    }), "editor", repo)).status).toBe(200);
    expect((await call(request(`${activities}/${activity}`, "PATCH", {
      name: "Nova tarefa", displayOrder: 1, version: 1
    }), "editor", repo)).status).toBe(200);
    const stale = await call(request(`${activities}/${activity}`, "PATCH", {
      name: "Nova tarefa", displayOrder: 1, version: 1
    }), "editor", { ...repo, updateActivity: async () => ({ status: "stale" }) });
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("database");
  });

  it("keeps errors generic and forbids unsupported or destructive methods", async () => {
    const repo = repository();
    const failed = await call(request(disciplines), "admin", {
      ...repo, listDisciplines: async () => { throw new Error("private database detail"); }
    });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private database detail");
    expect((await call(request(`${activities}/${activity}`, "DELETE"), "admin", repo)).status).toBe(405);
  });
});

describe("hierarchy assembly", () => {
  it("derives stage dates from ordered activities and leaves empty stages undated", () => {
    const baseRow = { disciplineId: discipline, disciplineName: "Arquitetura", disciplineCode: "ARQ",
      disciplineColor: "#112233", disciplineOrder: 0, disciplineDescription: null, disciplineVersion: 1,
      stageId: stage, stageCode: "EC", stageColor: "#445566", stageName: "Estudo", stageOrder: 0,
      stageVersion: 1, activityType: null, activityNotes: null, activityVersion: 1 };
    const rows = [
      { ...baseRow, activityId: activity, activityName: "Primeira", activityOrder: 0,
        plannedStart: "2026-11-05", plannedEnd: "2026-11-12" },
      { ...baseRow, activityId: "a7777777-7777-4777-8777-777777777777", activityName: "Segunda",
        activityOrder: 1, plannedStart: "2026-11-01", plannedEnd: "2026-11-08" },
      { ...baseRow, stageId: "a8888888-8888-4888-8888-888888888888", stageCode: "EP",
        stageName: "Anteprojeto", stageOrder: 1, activityId: null }
    ];
    const tree = assembleHierarchy(product, rows);
    expect(tree?.disciplines[0].stages[0].activities.map((item) => item.name)).toEqual(["Primeira", "Segunda"]);
    expect(tree?.disciplines[0].stages[0]).toMatchObject({ derivedStart: "2026-11-01", derivedEnd: "2026-11-12" });
    expect(tree?.disciplines[0].stages[1]).toMatchObject({ derivedStart: null, derivedEnd: null, activities: [] });
    expect(assembleHierarchy(product, [{ disciplineId: null }])).toEqual({ productId: product, disciplines: [] });
  });
});
