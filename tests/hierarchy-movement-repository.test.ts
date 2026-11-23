import { beforeEach, describe, expect, it, vi } from "vitest";

const database = vi.hoisted(() => {
  const calls: string[] = [];
  const query = vi.fn(async (strings: TemplateStringsArray): Promise<Array<{ result: {
    status?: string; version?: number; conflict?: unknown
  } }>> => {
    calls.push(strings.join(" "));
    return [{ result: { status: "moved", version: 4 } }];
  });
  return { calls, query };
});

vi.mock("@neondatabase/serverless", () => ({ neon: () => database.query }));

import { createScheduleRepository } from "../worker/schedule-repository";

const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const actorId = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const activityId = "a6666666-6666-4666-8666-666666666666";
const operationId = "a1111111-1111-4111-8111-111111111111";

describe("hierarchy movement repository", () => {
  beforeEach(() => {
    database.calls.length = 0;
    database.query.mockReset();
    database.query.mockImplementation(async (strings: TemplateStringsArray) => {
      database.calls.push(strings.join(" "));
      return [{ result: { status: "moved", version: 4 } }];
    });
  });

  it("delegates the entire move and audit transaction to one database function", async () => {
    const repository = createScheduleRepository({ DATABASE_URL: "postgresql://localhost/neondb" });
    await expect(repository.moveHierarchyItem(workspaceId, productId, actorId, operationId, {
      kind: "activity", targetId: activityId, expectedVersion: 3, reason: "Synthetic move reason",
      destinationDisciplineId: null, destinationStageId: null, destinationIndex: 0,
      expectedSourceOrder: [activityId], expectedDestinationOrder: []
    })).resolves.toEqual({ status: "moved", operationId, version: 4 });
    expect(database.calls).toHaveLength(1);
    expect(database.calls[0]).toContain("public.move_schedule_item");
    expect(database.calls[0]).toContain("jlproject.schedule_operation_id");
    expect(database.calls[0]).toContain("jlproject.schedule_justification");
    expect(database.calls[0]).not.toMatch(/UPDATE\s+public\./i);
    expect(database.calls[0]).not.toMatch(/INSERT\s+INTO\s+public\./i);
  });

  it("rejects an unknown database status", async () => {
    database.query.mockResolvedValueOnce([{ result: { status: "partial", version: 0 } }]);
    const repository = createScheduleRepository({ DATABASE_URL: "postgresql://localhost/neondb" });
    await expect(repository.moveHierarchyItem(workspaceId, productId, actorId, operationId, {
      kind: "discipline", targetId: activityId, expectedVersion: 1, reason: "Synthetic move reason",
      destinationDisciplineId: null, destinationStageId: null, destinationIndex: 0,
      expectedSourceOrder: [activityId], expectedDestinationOrder: [activityId]
    })).rejects.toThrow("Unexpected hierarchy movement result");
  });

  it("returns verified final-state dependency conflicts from the atomic database move", async () => {
    const conflict = { dependencyId: "b5555555-5555-4555-8555-555555555555", reason: "finish_to_start",
      predecessor: { id: "b6666666-6666-4666-8666-666666666666", kind: "stage" },
      successor: { id: "b7777777-7777-4777-8777-777777777777", kind: "stage" },
      before: { predecessorFinish: "2026-11-09", successorStart: "2026-11-10", earliestStart: "2026-11-10" },
      after: { predecessorFinish: "2026-11-10", successorStart: "2026-11-10", earliestStart: "2026-11-11" } };
    database.query.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict } }]);
    const repository = createScheduleRepository({ DATABASE_URL: "postgresql://localhost/neondb" });
    await expect(repository.moveHierarchyItem(workspaceId, productId, actorId, operationId, {
      kind: "activity", targetId: activityId, expectedVersion: 3, reason: "Synthetic move reason",
      destinationDisciplineId: null, destinationStageId: null, destinationIndex: 0,
      expectedSourceOrder: [activityId], expectedDestinationOrder: []
    })).resolves.toEqual({ status: "dependency_conflict", conflict });
    expect(database.query).toHaveBeenCalledTimes(1);
    expect(database.query.mock.calls[0]?.[0]?.join(" ")).toContain("public.move_schedule_item");
  });
});
