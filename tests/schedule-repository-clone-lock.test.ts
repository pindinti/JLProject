import { beforeEach, describe, expect, it, vi } from "vitest";

const database = vi.hoisted(() => {
  const calls: string[] = [];
  const query = vi.fn(async (strings: TemplateStringsArray) => {
    calls.push(strings.join(" "));
    return [];
  });
  return { calls, query };
});

vi.mock("@neondatabase/serverless", () => ({ neon: () => database.query }));

import { createScheduleRepository } from "../worker/schedule-repository";

const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const actorId = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const repository = () => createScheduleRepository({ DATABASE_URL: "postgresql://localhost/neondb" });

describe("product row locks for clone consistency", () => {
  beforeEach(() => {
    database.calls.length = 0;
    database.query.mockReset();
    database.query.mockImplementation(async (strings: TemplateStringsArray) => {
      database.calls.push(strings.join(" "));
      return [];
    });
  });

  it("locks the active product before every direct hierarchy or target write", async () => {
    const schedules = repository();
    await schedules.createDiscipline(workspaceId, productId, actorId, {
      name: "Synthetic", shortCode: "SYN", color: "#336699", displayOrder: 0, description: null
    });
    await schedules.updateDiscipline(workspaceId, productId, "f3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      actorId, { name: "Synthetic", shortCode: "SYN", color: "#336699", displayOrder: 0, description: null }, 1);
    await schedules.createActivity(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      "a3aa998a-a2c3-4376-9105-90af0d1dbfe3", actorId, {
        name: "Synthetic activity", activityType: null, plannedStart: "2026-11-10", plannedEnd: "2026-11-11",
        displayOrder: 0, notes: null
      });
    await schedules.createActivity(workspaceId, productId, null, null, actorId, {
      name: "Synthetic root activity", activityType: null, plannedStart: "2026-11-10", plannedEnd: "2026-11-11",
      displayOrder: 1, notes: null, colorOverride: "#AA5577"
    });
    await schedules.updateActivity(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      "a3aa998a-a2c3-4376-9105-90af0d1dbfe3", "b3aa998a-a2c3-4376-9105-90af0d1dbfe3", actorId, {
        name: "Synthetic activity", activityType: null, displayOrder: 0, notes: null
      }, 1);
    await schedules.updateActivity(workspaceId, productId, null, null,
      "b3aa998a-a2c3-4376-9105-90af0d1dbfe3", actorId, {
        name: "Synthetic root activity", activityType: null, displayOrder: 1, notes: null, colorOverride: "#AA5577"
      }, 1);
    await schedules.changeActivityDates(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      "a3aa998a-a2c3-4376-9105-90af0d1dbfe3", "b3aa998a-a2c3-4376-9105-90af0d1dbfe3", actorId,
      "2026-11-10", "2026-11-11", "Synthetic schedule lock test", 1, "c3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    await schedules.changeActivityDates(workspaceId, productId, null, null,
      "b3aa998a-a2c3-4376-9105-90af0d1dbfe3", actorId, "2026-11-10", "2026-11-11",
      "Synthetic root date lock test", 1, "c3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    await schedules.createTarget(workspaceId, productId, actorId, {
      name: "Synthetic target", description: null, color: "#336699", targetDate: "2026-11-10"
    });
    await schedules.updateTarget(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      actorId, { name: "Synthetic target", description: null, color: "#336699", targetDate: "2026-11-10" },
      1, null, "c3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    await schedules.deleteTarget(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      actorId, 1, "c3aa998a-a2c3-4376-9105-90af0d1dbfe3");

    expect(database.query).toHaveBeenCalled();
    const writes = database.calls.filter((query) => query.includes("locked_product"));
    expect(writes).toHaveLength(11);
    for (const query of writes) {
      expect(query).toContain("FROM public.products");
      expect(query).toContain("AND active = true");
      expect(query).toContain("FOR UPDATE");
    }
  });

  it("excludes deleted hierarchy rows from active reads and calendar impact candidates", async () => {
    const schedules = repository();
    await schedules.listDisciplines(workspaceId, productId);
    await schedules.listStages(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    await schedules.listActivities(workspaceId, productId, "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      "a3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    await schedules.listWorkingPlans(workspaceId, productId);
    await schedules.getHierarchy(workspaceId, productId);
    expect(database.calls[0]).toContain("deleted_at IS NULL");
    expect(database.calls[1]).toContain("s.deleted_at IS NULL");
    expect(database.calls[1]).toContain("a.deleted_at IS NULL");
    expect(database.calls[2]).toContain("deleted_at IS NULL");
    expect(database.calls[3]).toContain("deleted_at IS NULL");
    expect(database.calls[4]).toContain("d.deleted_at IS NULL");
    expect(database.calls[4]).toContain("s.deleted_at IS NULL");
    expect(database.calls[4]).toContain("a.deleted_at IS NULL");
  });

  it("lists active root activities in display order and matches root activity parents as null", async () => {
    const schedules = repository();
    await schedules.listRootActivities(workspaceId, productId);
    expect(database.calls[0]).toContain("discipline_id IS NULL AND stage_id IS NULL");
    expect(database.calls[0]).toContain("deleted_at IS NULL");
    expect(database.calls[0]).toContain("ORDER BY display_order, id");

    database.calls.length = 0;
    await schedules.listActivityDateHistory(workspaceId, productId, null, null,
      "b3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    expect(database.calls[0]).toContain("activity_id =");
    expect(database.calls[0]).not.toContain("discipline_id IS NOT DISTINCT FROM");
    expect(database.calls[0]).not.toContain("stage_id IS NOT DISTINCT FROM");
  });
});
