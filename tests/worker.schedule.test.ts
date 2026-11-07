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
    productExists: vi.fn(async () => true), disciplineExists: vi.fn(async () => true),
    stageExists: vi.fn(async () => true),
    listDisciplines: vi.fn(async () => [d]), createDiscipline: vi.fn(async () => ({ status: "ok" as const, value: d })),
    updateDiscipline: vi.fn(async () => ({ status: "ok" as const, value: { ...d, version: 2 } })),
    listStages: vi.fn(async () => [s]), createStage: vi.fn(async () => ({ status: "ok" as const, value: s })),
    updateStage: vi.fn(async () => ({ status: "ok" as const, value: { ...s, version: 2 } })),
    listActivities: vi.fn(async () => [a]), createActivity: vi.fn(async () => ({ status: "ok" as const, value: a })),
    updateActivity: vi.fn(async () => ({ status: "ok" as const, value: { ...a, version: 2 } })),
    getHierarchy: vi.fn(async () => ({ productId: product, disciplines: [{ ...d, stages: [{ ...s, activities: [a] }] }] }))
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
