// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import { assembleHierarchy, type ScheduleRepository } from "../worker/schedule-repository";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import type { CalendarRepository } from "../worker/calendar-repository";
import type { CalendarException } from "../domain/working-calendar";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const ws = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWs = "d441363c-bdde-4422-93d6-59b3868d29f4";
const product = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const discipline = "d4444444-4444-4444-8444-444444444444";
const stage = "a5555555-5555-4555-8555-555555555555";
const activity = "a6666666-6666-4666-8666-666666666666";
const rootActivity = "a7777777-7777-4777-8777-777777777777";
const targetId = "f7777777-7777-4777-8777-777777777777";
const base = `https://app.test/api/workspaces/${ws}/products/${product}`;
const disciplines = `${base}/disciplines`;
const stages = `${disciplines}/${discipline}/stages`;
const activities = `${stages}/${stage}/activities`;
const rootActivities = `${base}/root-activities`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const d = { id: discipline, productId: product, name: "Arquitetura", shortCode: "ARQ",
  color: "#112233", displayOrder: 0, description: null, version: 1 };
const s = { id: stage, disciplineId: discipline, code: "EC", color: "#445566",
  displayName: "Estudo conceitual", displayOrder: 0, version: 1, derivedStart: null, derivedEnd: null };
const a = { id: activity, stageId: stage, name: "Tarefa sintética", activityType: null,
  plannedStart: "2026-11-01", plannedEnd: "2026-11-05", displayOrder: 0, notes: null, version: 1,
  colorOverride: null, planningMode: "manual" as const, workingDayDuration: null, planningCalendarVersion: null };

const rootA = { ...a, id: rootActivity, stageId: null, name: "Root activity",
  plannedStart: "2026-11-03", plannedEnd: "2026-11-07", colorOverride: null };

function repository(): ScheduleRepository {
  return {
    moveHierarchyItem: vi.fn(async (_ws, _product, _actor, operationId, input) => ({
      status: "moved" as const, operationId, version: input.expectedVersion + 1
    })),
    previewDeletion: vi.fn(async () => ({ status: "ok" as const,
      fingerprint: "a".repeat(32), counts: { disciplines: 1, stages: 2, activities: 3 } })),
    deleteSubtree: vi.fn(async (_ws, _product, _actor, operationId) => ({ status: "deleted" as const,
      operationId, counts: { disciplines: 1, stages: 2, activities: 3 } })),
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
    listActivities: vi.fn(async () => [a]), listRootActivities: vi.fn(async () => []),
    createActivity: vi.fn(async () => ({ status: "ok" as const, value: a })),
    listWorkingPlans: vi.fn(async () => []),
    applyCalendarReschedule: vi.fn(async (_ws, _product, _actor, operationId, _calendarVersion,
      _reason, proposals) => ({ status: "updated" as const, count: proposals.length, operationId })),
    reverseCalendarReschedule: vi.fn(async (_ws, _product, _actor, originalOperationId,
      operationId) => ({ status: "reversed" as const, count: 2, originalOperationId, operationId })),
    listCalendarRescheduleHistory: vi.fn(async () => ({ status: "ok" as const, operations: [{
      operationId: "a1111111-1111-4111-8111-111111111111", changedAt: "2026-11-10T12:00:00.000Z",
      actorName: "Synthetic Actor", reason: "Synthetic original justification", status: "eligible" as const,
      reversal: null, activities: [{ activityId: activity, name: "Synthetic activity",
        previousStart: "2026-11-01", previousEnd: "2026-11-03", newStart: "2026-11-01", newEnd: "2026-11-04",
        currentStart: "2026-11-01", currentEnd: "2026-11-04" }]
    }] })),
    listProductChangeHistory: vi.fn(async () => ({ status: "ok" as const, events: [{
      id: `activity-date:${targetId}`, occurredAt: "2026-11-10T12:00:00.000000Z",
      actorId: actor, actorName: "Synthetic Actor", eventType: "activity_dates_changed" as const,
      item: { kind: "activity", id: activity, name: "Synthetic activity",
        hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
      justification: "Synthetic date adjustment", before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-03" },
      after: { plannedStart: "2026-11-01", plannedEnd: "2026-11-04" }, affectedItems: []
    }], nextCursor: { occurredAt: "2026-11-10T12:00:00.000000Z", eventId: `activity-date:${targetId}` } })),
    updateActivity: vi.fn(async () => ({ status: "ok" as const, value: { ...a, version: 2 } })),
    changeActivityDates: vi.fn(async () => ({ status: "updated" as const,
      activity: { ...a, plannedStart: "2026-11-02", version: 2 } })),
    createWorkingActivity: vi.fn(async (_ws, _product, _discipline, _stage, _actor, input) => ({
      status: "ok" as const, value: { ...a, plannedStart: input.plannedStart, plannedEnd: input.plannedEnd,
        planningMode: "working_days" as const, workingDayDuration: input.workingDays,
        planningCalendarVersion: input.calendarVersion }
    })),
    changeActivityWorkingPlan: vi.fn(async (_ws, _product, _discipline, _stage, _activity, _actor,
      start, end, workingDays, calendarVersion) => ({ status: "updated" as const, activity: {
        ...a, plannedStart: start, plannedEnd: end, planningMode: "working_days" as const,
        workingDayDuration: workingDays, planningCalendarVersion: calendarVersion, version: 2
      } })),
    listActivityDateHistory: vi.fn(async () => []),
    getHierarchy: vi.fn(async () => ({ productId: product, rootActivities: [],
      disciplines: [{ ...d, stages: [{ ...s, activities: [a] }] }] })),
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
function calculationCalendar(version = 2, exceptions: CalendarException[] = []): CalendarRepository {
  return {
    read: vi.fn(async () => ({ version, exceptions: [] })),
    readForCalculation: vi.fn(async () => ({ version, exceptions })),
    history: vi.fn(async () => ({ entries: [], nextBeforeVersion: null })),
    change: vi.fn(async () => ({ status: "unchanged" as const, version }))
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
async function call(input: Request, role: WorkspaceRole | null, repo = repository(), active = true,
  calendarRepo: CalendarRepository = calculationCalendar()) {
  return handleRequest(input, environment, async () => ({ subject: actor }),
    () => membership(role, active), undefined, undefined, () => repo, undefined, undefined, () => calendarRepo);
}

describe("schedule hierarchy API", () => {
  const movePath = `${base}/hierarchy/moves`;
  const moveBody = { kind: "activity", targetId: activity, expectedVersion: 1,
    destinationDisciplineId: null, destinationStageId: null, destinationIndex: 0,
    expectedSourceOrder: [activity], expectedDestinationOrder: [] };

  it("moves a hierarchy item atomically with server-derived actor and operation IDs", async () => {
    const repo = repository();
    const result = await call(request(movePath, "POST", moveBody), "editor", repo);
    expect(result.status).toBe(200);
    await expect(result.json()).resolves.toMatchObject({ changed: true, version: 2,
      operationId: expect.any(String) });
    expect(repo.moveHierarchyItem).toHaveBeenCalledWith(ws, product, actor, expect.any(String), moveBody);
  });

  it("rejects unauthorized, malformed, stale, conflicting, and failed hierarchy moves", async () => {
    const repo = repository();
    expect((await call(request(movePath, "POST", moveBody), "viewer", repo)).status).toBe(403);
    expect((await call(request(movePath, "POST", { ...moveBody, actorId: actor }), "admin", repo)).status).toBe(400);
    expect((await call(request(movePath, "POST", { ...moveBody,
      destinationDisciplineId: discipline }), "admin", repo)).status).toBe(400);
    expect((await call(request(movePath, "POST", { ...moveBody,
      expectedSourceOrder: [activity, activity] }), "admin", repo)).status).toBe(400);
    expect(repo.moveHierarchyItem).not.toHaveBeenCalled();
    vi.mocked(repo.moveHierarchyItem).mockResolvedValueOnce({ status: "stale" });
    expect((await call(request(movePath, "POST", moveBody), "admin", repo)).status).toBe(409);
    vi.mocked(repo.moveHierarchyItem).mockResolvedValueOnce({ status: "conflict" });
    expect((await call(request(movePath, "POST", moveBody), "admin", repo)).status).toBe(409);
    vi.mocked(repo.moveHierarchyItem).mockRejectedValueOnce(new Error("private movement detail"));
    const failed = await call(request(movePath, "POST", moveBody), "admin", repo);
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private movement detail");
  });

  const previewPath = `${base}/hierarchy/deletion-preview?kind=discipline&targetId=${discipline}`;
  const deletePath = `${base}/hierarchy/deletions`;
  const deletionBody = { kind: "discipline", targetId: discipline,
    fingerprint: "a".repeat(32), reason: "Synthetic hierarchy deletion" };

  it("previews a scoped subtree without exposing affected identifiers", async () => {
    const repo = repository();
    const result = await call(request(previewPath), "editor", repo);
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ fingerprint: "a".repeat(32),
      counts: { disciplines: 1, stages: 2, activities: 3 } });
    expect(repo.previewDeletion).toHaveBeenCalledWith(ws, product, actor, "discipline", discipline);
    expect(repo.deleteSubtree).not.toHaveBeenCalled();
  });

  it("returns root activities as a top-level hierarchy collection", async () => {
    const repo = repository();
    vi.mocked(repo.getHierarchy).mockResolvedValue({ productId: product, rootActivities: [rootA],
      disciplines: [{ ...d, stages: [{ ...s, activities: [a] }] }] });
    const response = await call(request(`${base}/hierarchy`), "viewer", repo);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ hierarchy: {
      rootActivities: [{ id: rootActivity, stageId: null }],
      disciplines: [{ stages: [{ activities: [{ id: activity, stageId: stage }] }] }]
    } });
  });

  it("uses the existing deletion operation for a root activity without inventing parents", async () => {
    const repo = repository();
    const path = `${base}/hierarchy/deletion-preview?kind=activity&targetId=${rootActivity}`;
    const response = await call(request(path), "editor", repo);
    expect(response.status).toBe(200);
    expect(repo.previewDeletion).toHaveBeenCalledWith(ws, product, actor, "activity", rootActivity);
    const deletion = await call(request(`${base}/hierarchy/deletions`, "POST", {
      kind: "activity", targetId: rootActivity, fingerprint: "a".repeat(32),
      reason: "Synthetic root activity deletion"
    }), "editor", repo);
    expect(deletion.status).toBe(200);
    expect(repo.deleteSubtree).toHaveBeenCalledWith(ws, product, actor, expect.any(String),
      "activity", rootActivity, "a".repeat(32), "Synthetic root activity deletion");
  });

  it("requires an authenticated active editor or admin for preview and deletion", async () => {
    const repo = repository();
    const anonymous = await handleRequest(request(deletePath, "POST", deletionBody), environment,
      async () => null, () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    for (const role of ["viewer", null] as const) {
      expect((await call(request(previewPath), role, repo)).status).toBe(403);
      expect((await call(request(deletePath, "POST", deletionBody), role, repo)).status).toBe(403);
    }
    expect((await call(request(deletePath, "POST", deletionBody), "editor", repo, false)).status).toBe(403);
    expect((await call(request(deletePath.replace(ws, otherWs), "POST", deletionBody), "admin", repo)).status).toBe(403);
    expect(repo.deleteSubtree).not.toHaveBeenCalled();
  });

  it("deletes only an explicitly identified subtree using the authenticated actor", async () => {
    const repo = repository();
    const result = await call(request(deletePath, "POST", deletionBody), "admin", repo);
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({ counts: { activities: 3 } });
    expect(repo.deleteSubtree).toHaveBeenCalledWith(ws, product, actor,
      expect.any(String), "discipline", discipline, "a".repeat(32), deletionBody.reason);
  });

  it("rejects malformed, forged, stale, and failed deletion requests safely", async () => {
    const repo = repository();
    for (const invalid of [{ ...deletionBody, reason: "short" },
      { ...deletionBody, actorId: actor }, { ...deletionBody, targetId: "bad" },
      { ...deletionBody, fingerprint: "bad" }, { ...deletionBody, kind: "product" }])
      expect((await call(request(deletePath, "POST", invalid), "admin", repo)).status).toBe(400);
    expect((await call(request(`${base}/hierarchy/deletion-preview?kind=stage&targetId=bad`),
      "admin", repo)).status).toBe(400);
    expect(repo.deleteSubtree).not.toHaveBeenCalled();
    vi.mocked(repo.deleteSubtree).mockResolvedValueOnce({ status: "stale" });
    expect((await call(request(deletePath, "POST", deletionBody), "admin", repo)).status).toBe(409);
    vi.mocked(repo.deleteSubtree).mockRejectedValueOnce(new Error("private SQL detail"));
    const failed = await call(request(deletePath, "POST", deletionBody), "admin", repo);
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });
  const applyPath = `${base}/calendar-impact/apply`;
  const originalOperationId = "a1111111-1111-4111-8111-111111111111";
  const reversePath = `${base}/calendar-reschedules/${originalOperationId}/reverse`;
  const selection = { activityId: activity, version: 3 };
  const planned = { id: activity, disciplineId: discipline, stageId: stage, version: 3,
    planningMode: "working_days" as const, plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
    workingDayDuration: 2, planningCalendarVersion: 1 };
  const closure: CalendarException = { id: "e1111111-1111-4111-8111-111111111111",
    kind: "company_shutdown", name: null, municipality: null, description: "Synthetic closure",
    startDate: "2026-11-10", endDate: "2026-11-10", version: 1 };

  it("applies only explicit recalculated date changes with a server identity and reason", async () => {
    const repo = repository();
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([planned]);
    const result = await call(request(applyPath, "POST", { calendarVersion: 2,
      reason: "Synthetic calendar adjustment", selections: [selection] }), "editor", repo,
    true, calculationCalendar(2, [closure]));
    expect(result.status).toBe(200);
    await expect(result.json()).resolves.toMatchObject({ changedCount: 1 });
    expect(repo.applyCalendarReschedule).toHaveBeenCalledWith(ws, product, actor,
      expect.any(String), 2, "Synthetic calendar adjustment", [{
        activityId: activity, disciplineId: discipline, stageId: stage, expectedVersion: 3,
        startDate: "2026-11-09", currentEndDate: "2026-11-10",
        proposedEndDate: "2026-11-11", workingDays: 2, savedCalendarVersion: 1
      }]);
  });

  it("denies unauthenticated, viewer, inactive, and foreign-workspace apply requests", async () => {
    const repo = repository();
    const payload = { calendarVersion: 2, reason: "Synthetic calendar adjustment", selections: [selection] };
    const anonymous = await handleRequest(request(applyPath, "POST", payload), environment,
      async () => null, () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect((await call(request(applyPath, "POST", payload), "viewer", repo)).status).toBe(403);
    expect((await call(request(applyPath, "POST", payload), "editor", repo, false)).status).toBe(403);
    expect((await call(request(applyPath.replace(ws, otherWs), "POST", payload), "admin", repo)).status).toBe(403);
    expect(repo.applyCalendarReschedule).not.toHaveBeenCalled();
  });

  it("rejects invalid selections, stale versions, calendars, and version-only proposals", async () => {
    const repo = repository();
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([planned]);
    const payload = { calendarVersion: 2, reason: "Synthetic calendar adjustment", selections: [selection] };
    for (const invalid of [
      { ...payload, reason: "short" }, { ...payload, selections: [] },
      { ...payload, selections: [selection, selection] },
      { ...payload, selections: [{ ...selection, actorId: actor }] },
      { ...payload, selections: [{ ...selection, activityId: "bad" }] }
    ]) expect((await call(request(applyPath, "POST", invalid), "admin", repo)).status).toBe(400);
    expect((await call(request(applyPath, "POST", { ...payload, calendarVersion: 1 }),
      "admin", repo)).status).toBe(409);
    expect((await call(request(applyPath, "POST", { ...payload, selections: [{ ...selection, version: 2 }] }),
      "admin", repo)).status).toBe(409);
    expect((await call(request(applyPath, "POST", payload), "admin", repo)).status).toBe(409);
    expect(repo.applyCalendarReschedule).not.toHaveBeenCalled();
  });

  it("does not submit a partial batch when one selected activity is manual or stale", async () => {
    const repo = repository();
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([planned]);
    const payload = { calendarVersion: 2, reason: "Synthetic calendar adjustment",
      selections: [selection, { activityId: targetId, version: 1 }] };
    const result = await call(request(applyPath, "POST", payload), "admin", repo,
      true, calculationCalendar(2, [closure]));
    expect(result.status).toBe(409);
    expect(repo.applyCalendarReschedule).not.toHaveBeenCalled();
  });

  it("returns conflict for concurrent database edits and hides write failures", async () => {
    const repo = repository();
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([planned]);
    const payload = { calendarVersion: 2, reason: "Synthetic calendar adjustment", selections: [selection] };
    vi.mocked(repo.applyCalendarReschedule).mockResolvedValueOnce({ status: "stale" });
    const conflict = await call(request(applyPath, "POST", payload), "admin", repo,
      true, calculationCalendar(2, [closure]));
    expect(conflict.status).toBe(409);
    vi.mocked(repo.applyCalendarReschedule).mockRejectedValueOnce(new Error("private SQL detail"));
    const failed = await call(request(applyPath, "POST", payload), "admin", repo,
      true, calculationCalendar(2, [closure]));
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });

  it("reverses one explicit operation with the verified actor and a justification", async () => {
    const repo = repository();
    const result = await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "editor", repo);
    expect(result.status).toBe(200);
    await expect(result.json()).resolves.toMatchObject({ reversedCount: 2,
      originalOperationId, operationId: expect.any(String) });
    expect(repo.reverseCalendarReschedule).toHaveBeenCalledWith(ws, product, actor,
      originalOperationId, expect.any(String), "Synthetic reversal reason");
    expect((await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "admin", repo)).status)
      .toBe(200);
  });

  it("denies unauthenticated, viewer, inactive, and cross-workspace reversal", async () => {
    const repo = repository();
    const payload = { reason: "Synthetic reversal reason" };
    const anonymous = await handleRequest(request(reversePath, "POST", payload), environment,
      async () => null, () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect((await call(request(reversePath, "POST", payload), "viewer", repo)).status).toBe(403);
    expect((await call(request(reversePath, "POST", payload), "editor", repo, false)).status).toBe(403);
    expect((await call(request(reversePath.replace(ws, otherWs), "POST", payload), "admin", repo)).status).toBe(403);
    expect(repo.reverseCalendarReschedule).not.toHaveBeenCalled();
  });

  it("validates reversal input and distinguishes missing, stale, and duplicate operations", async () => {
    const repo = repository();
    for (const invalid of [{}, { reason: "short" }, { reason: "Synthetic reversal reason", actorId: actor }])
      expect((await call(request(reversePath, "POST", invalid), "admin", repo)).status).toBe(400);
    expect((await call(request(reversePath.replace(originalOperationId, "bad"), "POST",
      { reason: "Synthetic reversal reason" }), "admin", repo)).status).toBe(400);
    expect(repo.reverseCalendarReschedule).not.toHaveBeenCalled();
    vi.mocked(repo.reverseCalendarReschedule).mockResolvedValueOnce({ status: "not_found" })
      .mockResolvedValueOnce({ status: "stale", activityId: activity })
      .mockResolvedValueOnce({ status: "already_reversed" });
    expect((await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "admin", repo)).status).toBe(404);
    const stale = await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "admin", repo);
    expect(stale.status).toBe(409);
    await expect(stale.json()).resolves.toMatchObject({ code: "activity_changed", activityId: activity });
    const duplicate = await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "admin", repo);
    expect(duplicate.status).toBe(409);
    await expect(duplicate.json()).resolves.toMatchObject({ code: "already_reversed" });
  });

  it("hides database details when reversal fails", async () => {
    const repo = repository();
    vi.mocked(repo.reverseCalendarReschedule).mockRejectedValueOnce(new Error("private SQL detail"));
    const failed = await call(request(reversePath, "POST", { reason: "Synthetic reversal reason" }), "admin", repo);
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });
  it("returns scoped rescheduling history to active members without accepting actor claims", async () => {
    const repo = repository();
    const historyPath = `${base}/calendar-reschedules/history`;
    const result = await call(request(historyPath), "viewer", repo);
    expect(result.status).toBe(200);
    expect(result.headers.get("Cache-Control")).toBe("no-store");
    await expect(result.json()).resolves.toMatchObject({ operations: [{
      operationId: originalOperationId, actorName: "Synthetic Actor", status: "eligible",
      reason: "Synthetic original justification", activities: [{ activityId: activity,
        previousEnd: "2026-11-03", newEnd: "2026-11-04" }]
    }] });
    expect(repo.listCalendarRescheduleHistory).toHaveBeenCalledWith(ws, product, actor);
    expect(repo.reverseCalendarReschedule).not.toHaveBeenCalled();
    expect((await call(request(`${historyPath}?actorId=${actor}`), "admin", repo)).status).toBe(400);
  });

  it("denies anonymous, inactive, and cross-workspace rescheduling history reads", async () => {
    const repo = repository();
    const historyPath = `${base}/calendar-reschedules/history`;
    const anonymous = await handleRequest(request(historyPath), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect((await call(request(historyPath), null, repo)).status).toBe(403);
    expect((await call(request(historyPath), "viewer", repo, false)).status).toBe(403);
    expect((await call(request(historyPath.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect(repo.listCalendarRescheduleHistory).not.toHaveBeenCalled();
  });

  it("maps database history authorization and failure results to safe responses", async () => {
    const repo = repository();
    const historyPath = `${base}/calendar-reschedules/history`;
    vi.mocked(repo.listCalendarRescheduleHistory).mockResolvedValueOnce({ status: "forbidden" });
    expect((await call(request(historyPath), "admin", repo)).status).toBe(403);
    vi.mocked(repo.listCalendarRescheduleHistory).mockRejectedValueOnce(new Error("private SQL detail"));
    const failed = await call(request(historyPath), "admin", repo);
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });

  it("returns the normalized product change feed with stable pagination to active viewers", async () => {
    const repo = repository();
    const path = `${base}/change-history?limit=1`;
    const first = await call(request(path), "viewer", repo);
    expect(first.status).toBe(200);
    expect(first.headers.get("Cache-Control")).toBe("no-store");
    const firstPage = await first.json() as { events: Array<Record<string, unknown>>; nextCursor: string | null };
    expect(firstPage.events).toMatchObject([{
      eventType: "activity_dates_changed", actorId: actor, actorName: "Synthetic Actor",
      item: { kind: "activity", id: activity, hierarchy: {
        discipline: "Synthetic discipline", stage: "Synthetic stage"
      } }, justification: "Synthetic date adjustment",
      before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-03" },
      after: { plannedStart: "2026-11-01", plannedEnd: "2026-11-04" }
    }]);
    expect(firstPage.nextCursor).toBeTruthy();
    expect(repo.listProductChangeHistory).toHaveBeenCalledWith(ws, product, actor, 1, null);

    const next = await call(request(`${base}/change-history?limit=1&cursor=${encodeURIComponent(firstPage.nextCursor!)}`),
      "viewer", repo);
    expect(next.status).toBe(200);
    expect(repo.listProductChangeHistory).toHaveBeenLastCalledWith(ws, product, actor, 1,
      { occurredAt: "2026-11-10T12:00:00.000000Z", eventId: `activity-date:${targetId}` });
  });

  it("serves hierarchy movement events through the same viewer-authorized history cursor", async () => {
    const repo = repository();
    const eventId = `hierarchy-movement:${activity}`;
    const occurredAt = "2026-11-11T18:14:22.000000Z";
    vi.mocked(repo.listProductChangeHistory).mockResolvedValueOnce({ status: "ok", events: [{
      id: eventId, occurredAt, actorId: actor, actorName: "Synthetic Actor", eventType: "hierarchy_moved",
      item: { kind: "activity", id: activity, name: "Synthetic activity",
        hierarchy: { scope: "product_root" } }, justification: null,
      before: { parent: { scope: "stage", discipline: "Synthetic discipline", stage: "Synthetic stage" }, position: 2 },
      after: { parent: { scope: "product_root" }, position: 1 }, affectedItems: []
    }], nextCursor: { occurredAt, eventId } });

    const result = await call(request(`${base}/change-history?limit=1`), "viewer", repo);
    expect(result.status).toBe(200);
    const page = await result.json() as { events: Array<Record<string, unknown>>; nextCursor: string };
    expect(page.events).toMatchObject([{ id: eventId, eventType: "hierarchy_moved", actorId: actor,
      item: { kind: "activity", id: activity, hierarchy: { scope: "product_root" } },
      before: { parent: { stage: "Synthetic stage" }, position: 2 }, after: { parent: { scope: "product_root" }, position: 1 } }]);
    expect(page.nextCursor).toBe(`${occurredAt}~${eventId}`);
    expect(repo.listProductChangeHistory).toHaveBeenCalledWith(ws, product, actor, 1, null);
  });

  it("rejects malformed pagination and client actor claims before querying history", async () => {
    const repo = repository();
    for (const suffix of ["?limit=0", "?limit=101", `?actorId=${actor}`,
      "?cursor=not-a-cursor", "?limit=01&limit=02"]) {
      expect((await call(request(`${base}/change-history${suffix}`), "admin", repo)).status).toBe(400);
    }
    expect(repo.listProductChangeHistory).not.toHaveBeenCalled();
  });

  it("denies anonymous, inactive, and cross-workspace product history reads", async () => {
    const repo = repository();
    const path = `${base}/change-history`;
    const anonymous = await handleRequest(request(path), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect((await call(request(path), null, repo)).status).toBe(403);
    expect((await call(request(path), "viewer", repo, false)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect(repo.listProductChangeHistory).not.toHaveBeenCalled();
  });

  it("returns scoped read-only calendar impacts to active members", async () => {
    const repo = repository();
    const calendar = calculationCalendar(2, [{
      id: "e1111111-1111-4111-8111-111111111111", kind: "company_shutdown",
      name: null, municipality: null, description: "Synthetic closure",
      startDate: "2026-11-10", endDate: "2026-11-10", version: 1
    }]);
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([
      { id: activity, disciplineId: discipline, stageId: stage, version: 3,
        planningMode: "working_days", plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
        workingDayDuration: 2, planningCalendarVersion: 1 },
      { id: targetId, disciplineId: discipline, stageId: stage, version: 1,
        planningMode: "manual", plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
        workingDayDuration: null, planningCalendarVersion: null }
    ]);
    const path = `${base}/calendar-impact`;
    const result = await call(request(path), "viewer", repo, true, calendar);
    expect(result.status).toBe(200);
    expect(result.headers.get("Cache-Control")).toBe("no-store");
    await expect(result.json()).resolves.toMatchObject({ calendarVersion: 2, impacts: [{
      activityId: activity, impact: "date_change", currentEndDate: "2026-11-10",
      proposedEndDate: "2026-11-11", savedCalendarVersion: 1,
      skippedDates: [{ date: "2026-11-10" }]
    }] });
    expect(repo.listWorkingPlans).toHaveBeenCalledWith(ws, product);
    expect(calendar.readForCalculation).toHaveBeenCalledWith(ws);
    expect(repo.changeActivityDates).not.toHaveBeenCalled();
    expect(repo.changeActivityWorkingPlan).not.toHaveBeenCalled();
  });

  it("includes root working plans in impacts and passes null parent pairs to rescheduling", async () => {
    const repo = repository();
    const rootPlan = { id: rootActivity, disciplineId: null, stageId: null, version: 3,
      planningMode: "working_days" as const, plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
      workingDayDuration: 2, planningCalendarVersion: 1 };
    vi.mocked(repo.listWorkingPlans).mockResolvedValue([rootPlan]);
    const calendar = calculationCalendar(2, [{ id: "e1111111-1111-4111-8111-111111111111",
      kind: "company_shutdown", name: null, municipality: null, description: "Synthetic closure",
      startDate: "2026-11-10", endDate: "2026-11-10", version: 1 }]);
    const impact = await call(request(`${base}/calendar-impact`), "viewer", repo, true, calendar);
    expect(impact.status).toBe(200);
    await expect(impact.json()).resolves.toMatchObject({ impacts: [{ activityId: rootActivity,
      disciplineId: null, stageId: null, proposedEndDate: "2026-11-11" }] });

    const applied = await call(request(`${base}/calendar-impact/apply`, "POST", {
      calendarVersion: 2, reason: "Synthetic root calendar reschedule",
      selections: [{ activityId: rootActivity, version: 3 }]
    }), "editor", repo, true, calendar);
    expect(applied.status).toBe(200);
    expect(repo.applyCalendarReschedule).toHaveBeenCalledWith(ws, product, actor, expect.any(String), 2,
      "Synthetic root calendar reschedule", [expect.objectContaining({ activityId: rootActivity,
        disciplineId: null, stageId: null, proposedEndDate: "2026-11-11" })]);
  });

  it("denies unauthenticated, inactive, foreign, invalid, and unknown-product impact reads", async () => {
    const path = `${base}/calendar-impact`;
    const repo = repository();
    const anonymous = await handleRequest(request(path), environment, async () => null,
      () => membership("admin"), undefined, undefined, () => repo);
    expect(anonymous.status).toBe(401);
    expect((await call(request(path), null, repo)).status).toBe(403);
    expect((await call(request(path), "viewer", repo, false)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs)), "admin", repo)).status).toBe(403);
    expect((await call(request(path.replace(product, "bad")), "admin", repo)).status).toBe(400);
    expect((await call(request(path), "admin", { ...repo, productExists: async () => false })).status).toBe(404);
    expect((await call(request(`${path}?actorId=${actor}`), "admin", repo)).status).toBe(400);
    expect((await call(request(path, "POST", {}), "admin", repo)).status).toBe(405);
    expect(repo.listWorkingPlans).not.toHaveBeenCalled();
  });

  it("hides calendar impact calculation and repository failures", async () => {
    const path = `${base}/calendar-impact`;
    const repo = repository();
    const failed = await call(request(path), "editor", {
      ...repo, listWorkingPlans: async () => { throw new Error("private SQL detail"); }
    });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private SQL detail");
  });

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

  it("lists and creates product-scoped root activities with optional color overrides", async () => {
    const repo = repository();
    vi.mocked(repo.listRootActivities).mockResolvedValue([rootA]);
    const listed = await call(request(rootActivities), "viewer", repo);
    expect(listed.status).toBe(200);
    await expect(listed.json()).resolves.toMatchObject({ rootActivities: [{ id: rootActivity,
      stageId: null, colorOverride: null }] });

    const input = { name: "Root activity", plannedStart: "2026-11-03", plannedEnd: "2026-11-07",
      displayOrder: 0, colorOverride: "#aa5577" };
    const created = await call(request(rootActivities, "POST", input), "editor", repo);
    expect(created.status).toBe(201);
    expect(repo.createActivity).toHaveBeenCalledWith(ws, product, null, null, actor,
      { ...input, colorOverride: "#AA5577", activityType: null, notes: null });
    expect((await call(request(rootActivities, "POST", { ...input, colorOverride: "red" }),
      "editor", repo)).status).toBe(400);
    expect((await call(request(rootActivities, "POST", input), "viewer", repo)).status).toBe(403);
    expect((await call(request(rootActivities, "POST", input), "editor", {
      ...repo, productExists: async () => false
    })).status).toBe(404);
  });

  it("creates working-day root activities through the controlled function with null parents", async () => {
    const repo = repository();
    const calendarRepo = calculationCalendar(3, [{ id: "b7777777-7777-4777-8777-777777777777",
      kind: "company_shutdown", name: null, municipality: null, description: "Synthetic closure",
      startDate: "2026-11-06", endDate: "2026-11-06", version: 1 }]);
    const input = { name: "Root working activity", displayOrder: 0, planningMode: "working_days",
      plannedStart: "2026-11-05", workingDays: 2, calendarVersion: 3, colorOverride: "#aa5577" };
    const response = await call(request(rootActivities, "POST", input), "editor", repo, true, calendarRepo);
    expect(response.status).toBe(201);
    expect(repo.createWorkingActivity).toHaveBeenCalledWith(ws, product, null, null, actor,
      expect.objectContaining({ plannedEnd: "2026-11-09", workingDays: 2,
        calendarVersion: 3, colorOverride: "#AA5577" }));
  });

  it("edits root metadata and colors with optimistic concurrency and workspace isolation", async () => {
    const repo = repository();
    const path = `${rootActivities}/${rootActivity}`;
    const input = { name: "Renamed root activity", displayOrder: 1, colorOverride: null, version: 4 };
    expect((await call(request(path, "PATCH", input), "editor", repo)).status).toBe(200);
    expect(repo.updateActivity).toHaveBeenCalledWith(ws, product, null, null, rootActivity, actor,
      { name: input.name, activityType: null, displayOrder: 1, notes: null, colorOverride: null }, 4);
    expect((await call(request(path, "PATCH", input), "viewer", repo)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs), "PATCH", input), "editor", repo)).status).toBe(403);
    const stale = await call(request(path, "PATCH", input), "editor", {
      ...repo, updateActivity: async () => ({ status: "stale" })
    });
    expect(stale.status).toBe(409);
    expect(await stale.text()).not.toContain("database");
  });

  it("routes root date edits and history through audited, workspace-scoped operations", async () => {
    const repo = repository();
    const path = `${rootActivities}/${rootActivity}/dates`;
    const input = { plannedStart: "2026-11-04", plannedEnd: "2026-11-08",
      reason: "Synthetic root date adjustment", version: 1 };
    const changed = await call(request(path, "PATCH", input), "editor", repo);
    expect(changed.status).toBe(200);
    expect(repo.activityExists).toHaveBeenCalledWith(ws, product, null, null, rootActivity, true);
    expect(repo.changeActivityDates).toHaveBeenCalledWith(ws, product, null, null, rootActivity, actor,
      input.plannedStart, input.plannedEnd, input.reason, 1, expect.any(String));
    expect((await call(request(`${rootActivities}/${rootActivity}/date-history`), "viewer", repo)).status).toBe(200);
    expect(repo.listActivityDateHistory).toHaveBeenCalledWith(ws, product, null, null, rootActivity);
    expect((await call(request(path, "PATCH", input), "editor", {
      ...repo, activityExists: async () => false
    })).status).toBe(404);
  });

  it("edits a root working-day plan with current calendar and activity versions", async () => {
    const repo = repository();
    const calendarRepo = calculationCalendar(3);
    const input = { startDate: "2026-11-05", workingDays: 3, calendarVersion: 3,
      reason: "Synthetic root plan change", version: 1 };
    const response = await call(request(`${rootActivities}/${rootActivity}/working-plan`, "PATCH", input),
      "editor", repo, true, calendarRepo);
    expect(response.status).toBe(200);
    expect(repo.activityExists).toHaveBeenCalledWith(ws, product, null, null, rootActivity, true);
    expect(repo.changeActivityWorkingPlan).toHaveBeenCalledWith(ws, product, null, null, rootActivity,
      actor, "2026-11-05", "2026-11-09", 3, 3, input.reason, 1, expect.any(String));
    expect((await call(request(`${rootActivities}/${rootActivity}/working-plan`, "PATCH", input), "viewer",
      repo, true, calendarRepo)).status).toBe(403);
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

  it("creates working-day activities from the authoritative calendar and persists the calendar version", async () => {
    const repo = repository();
    const closure: CalendarException = { id: "b7777777-7777-4777-8777-777777777777",
      kind: "company_shutdown", name: null, municipality: null, description: "Synthetic closure",
      startDate: "2026-11-06", endDate: "2026-11-06", version: 1 };
    const calendarRepo = calculationCalendar(3, [closure]);
    const input = { name: "Synthetic working activity", displayOrder: 1,
      planningMode: "working_days", plannedStart: "2026-11-05", workingDays: 2, calendarVersion: 3 };
    const created = await call(request(activities, "POST", input), "editor", repo, true, calendarRepo);
    expect(created.status).toBe(201);
    await expect(created.json()).resolves.toMatchObject({ activity: {
      plannedStart: "2026-11-05", plannedEnd: "2026-11-09", planningMode: "working_days",
      workingDayDuration: 2, planningCalendarVersion: 3
    } });
    expect(calendarRepo.readForCalculation).toHaveBeenCalledWith(ws);
    expect(repo.createWorkingActivity).toHaveBeenCalledWith(ws, product, discipline, stage, actor,
      expect.objectContaining({ plannedEnd: "2026-11-09", workingDays: 2, calendarVersion: 3 }));
    expect(repo.createActivity).not.toHaveBeenCalled();
    const racedCalendar = await call(request(activities, "POST", input), "editor", {
      ...repo, createWorkingActivity: async () => ({ status: "stale_calendar" })
    }, true, calendarRepo);
    expect(racedCalendar.status).toBe(409);
    await expect(racedCalendar.json()).resolves.toMatchObject({ code: "stale_calendar" });
    const invalid = await call(request(activities, "POST", input), "editor", {
      ...repo, createWorkingActivity: async () => ({ status: "invalid" })
    }, true, calendarRepo);
    expect(invalid.status).toBe(400);
    await expect(invalid.json()).resolves.toMatchObject({ error: expect.stringMatching(/dias úteis inválidos/) });
  });

  it("recalculates edited plans server-side, requires a current calendar, and preserves role boundaries", async () => {
    const repo = repository();
    const path = `${activities}/${activity}/working-plan`;
    const closure: CalendarException = { id: "b7777777-7777-4777-8777-777777777777",
      kind: "company_shutdown", name: null, municipality: null, description: "Synthetic closure",
      startDate: "2026-11-06", endDate: "2026-11-06", version: 1 };
    const input = { startDate: "2026-11-05", workingDays: 3, calendarVersion: 3,
      reason: "Synthetic working plan", version: 1 };
    const calendarRepo = calculationCalendar(3, [closure]);
    const updated = await call(request(path, "PATCH", input), "editor", repo, true, calendarRepo);
    expect(updated.status).toBe(200);
    await expect(updated.json()).resolves.toMatchObject({ activity: {
      plannedStart: "2026-11-05", plannedEnd: "2026-11-10", workingDayDuration: 3,
      planningCalendarVersion: 3
    }, calculation: { endDate: "2026-11-10" } });
    expect(repo.changeActivityWorkingPlan).toHaveBeenCalledWith(ws, product, discipline, stage,
      activity, actor, "2026-11-05", "2026-11-10", 3, 3, "Synthetic working plan", 1, expect.any(String));
    expect((await call(request(path, "PATCH", input), "viewer", repo, true, calendarRepo)).status).toBe(403);
    expect((await call(request(path, "PATCH", input), "editor", repo, false, calendarRepo)).status).toBe(403);
    expect((await call(request(path.replace(ws, otherWs), "PATCH", input), "editor", repo, true, calendarRepo)).status).toBe(403);
    const staleCalendar = calculationCalendar(4, [closure]);
    const stale = await call(request(path, "PATCH", input), "editor", repo, true, staleCalendar);
    expect(stale.status).toBe(409);
    await expect(stale.json()).resolves.toMatchObject({ code: "calendar_conflict" });
    for (const invalid of [
      { ...input, workingDays: 0 }, { ...input, startDate: "2026-02-30" },
      { ...input, reason: "short" }, { ...input, plannedEnd: "2026-11-09" },
      { ...input, startDate: "2100-12-31", workingDays: 2 }
    ]) expect((await call(request(path, "PATCH", invalid), "editor", repo, true, calendarRepo)).status).toBe(400);
    expect(repo.changeActivityWorkingPlan).toHaveBeenCalledTimes(1);
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

  it("validates, normalizes, and resets individual activity color overrides", async () => {
    const repo = repository();
    const path = `${activities}/${activity}`;
    const baseInput = { name: "Nova tarefa", displayOrder: 1, version: 1 };
    expect((await call(request(path, "PATCH", { ...baseInput, colorOverride: "#aa5577" }), "editor", repo)).status).toBe(200);
    expect(repo.updateActivity).toHaveBeenLastCalledWith(ws, product, discipline, stage, activity, actor,
      { name: "Nova tarefa", activityType: null, displayOrder: 1, notes: null, colorOverride: "#AA5577" }, 1);
    expect((await call(request(path, "PATCH", { ...baseInput, colorOverride: null }), "admin", repo)).status).toBe(200);
    expect(repo.updateActivity).toHaveBeenLastCalledWith(ws, product, discipline, stage, activity, actor,
      { name: "Nova tarefa", activityType: null, displayOrder: 1, notes: null, colorOverride: null }, 1);
    expect((await call(request(path, "PATCH", { ...baseInput, colorOverride: "red" }), "editor", repo)).status).toBe(400);
    expect((await call(request(path, "PATCH", { ...baseInput, colorOverride: "#112233" }), "viewer", repo)).status).toBe(403);
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
      stageVersion: 1, activityType: null, activityNotes: null, activityColorOverride: null, activityVersion: 1 };
    const rows = [
      { ...baseRow, activityId: activity, activityName: "Primeira", activityOrder: 0,
        plannedStart: "2026-11-05", plannedEnd: "2026-11-12" },
      { ...baseRow, activityId: "a7777777-7777-4777-8777-777777777777", activityName: "Segunda",
        activityOrder: 1, plannedStart: "2026-11-01", plannedEnd: "2026-11-08", activityColorOverride: "#AA5577" },
      { ...baseRow, stageId: "a8888888-8888-4888-8888-888888888888", stageCode: "EP",
        stageName: "Anteprojeto", stageOrder: 1, activityId: null }
    ];
    const tree = assembleHierarchy(product, rows);
    expect(tree?.disciplines[0].stages[0].activities.map((item) => item.name)).toEqual(["Primeira", "Segunda"]);
    expect(tree?.disciplines[0].stages[0].activities.map((item) => item.colorOverride)).toEqual([null, "#AA5577"]);
    expect(tree?.disciplines[0].stages[0]).toMatchObject({ derivedStart: "2026-11-01", derivedEnd: "2026-11-12" });
    expect(tree?.disciplines[0].stages[1]).toMatchObject({ derivedStart: null, derivedEnd: null, activities: [] });
    expect(assembleHierarchy(product, [{ disciplineId: null }])).toEqual({
      productId: product, rootActivities: [], disciplines: []
    });
  });

  it("keeps root activities in a separate collection with no stage parent", () => {
    const rootRows = [{ id: rootActivity, stageId: null, name: "Root activity", activityType: null,
      plannedStart: "2026-11-03", plannedEnd: "2026-11-07", displayOrder: 0, notes: null,
      colorOverride: null, version: 1, planningMode: "manual", workingDayDuration: null,
      planningCalendarVersion: null }];
    const hierarchy = assembleHierarchy(product, [{ disciplineId: null }], rootRows);
    expect(hierarchy?.rootActivities).toEqual([expect.objectContaining({ id: rootActivity,
      stageId: null, colorOverride: null, plannedStart: "2026-11-03" })]);
    expect(hierarchy?.disciplines).toEqual([]);
  });
});
