// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { assembleExecutiveGantt, createExecutiveGanttRepository, type ExecutiveRows } from "../worker/executive-gantt";

const transaction = vi.hoisted(() => vi.fn(async () => [[], [], [], [], []]));
vi.mock("@neondatabase/serverless", () => ({
  neon: () => Object.assign(
    (parts: TemplateStringsArray, ...values: unknown[]) => ({ text: parts.join("?"), values }),
    { transaction }
  )
}));

const product = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const archived = "e3aa998a-a2c3-4376-9105-90af0d1dbfe4";
const disciplineA = "d4444444-4444-4444-8444-444444444444";
const disciplineB = "d4444444-4444-4444-8444-444444444445";
const stageA = "a5555555-5555-4555-8555-555555555555";
const stageB = "a5555555-5555-4555-8555-555555555556";
const root = "a7777777-7777-4777-8777-777777777777";

function rows(): ExecutiveRows {
  return {
    products: [{ id: archived, name: "Archived", active: false },
      { id: product, name: "Current", active: true }],
    disciplines: [
      { id: disciplineB, productId: product, name: "Second", shortCode: "B", color: "#445566", displayOrder: 1 },
      { id: disciplineA, productId: product, name: "First", shortCode: "A", color: "#112233", displayOrder: 0 }
    ],
    stages: [
      { id: stageB, productId: product, disciplineId: disciplineB, code: "EC", displayName: "Same stage", color: "#222222", displayOrder: 0 },
      { id: stageA, productId: product, disciplineId: disciplineA, code: "EC", displayName: "Same stage", color: "#111111", displayOrder: 0 }
    ],
    activities: [
      { id: "z", productId: product, disciplineId: disciplineA, stageId: stageA, name: "Later", activityType: "Marco", displayOrder: 1,
        plannedStart: "2024-12-30", plannedEnd: "2025-01-02", colorOverride: null },
      { id: root, productId: product, disciplineId: null, stageId: null, name: "Root", activityType: null, displayOrder: 0,
        plannedStart: "2024-02-29", plannedEnd: "2025-01-10", colorOverride: "#ABCDEF" },
      { id: "a", productId: product, disciplineId: disciplineA, stageId: stageA, name: "Earlier", activityType: null, displayOrder: 0,
        plannedStart: "2024-12-31", plannedEnd: "2025-01-03", colorOverride: null },
      { id: "b", productId: product, disciplineId: disciplineB, stageId: stageB, name: "Overlap", activityType: null, displayOrder: 0,
        plannedStart: "2025-01-01", plannedEnd: "2025-01-05", colorOverride: "#FEDCBA" }
    ],
    targets: [
      { id: "target-b", productId: product, name: "Second", description: null, color: "#222222", displayOrder: 1,
        targetDate: "2025-01-04", operationalDate: null },
      { id: "target-a", productId: product, name: "First", description: "Target detail", color: "#111111", displayOrder: 0,
        targetDate: "2025-01-04", operationalDate: "2025-01-06" }
    ]
  };
}

describe("executive Gantt projection", () => {
  it("keeps archived and empty products and derives ranges from activities including roots", () => {
    const [current, empty] = assembleExecutiveGantt(rows());
    expect(current.id).toBe(product);
    expect(current).toMatchObject({ active: true, start: "2024-02-29", end: "2025-01-10" });
    expect(current.rootActivities).toMatchObject([{ id: root, stageId: null, disciplineId: null, color: "#ABCDEF" }]);
    expect(empty).toMatchObject({ id: archived, active: false, start: null, end: null,
      rootActivities: [], disciplines: [], targets: [] });
  });

  it("keeps overlapping stages and identically named stages under their distinct disciplines", () => {
    const [current] = assembleExecutiveGantt(rows());
    const [first, second] = current.disciplines;
    expect(first.id).toBe(disciplineA);
    expect(second.id).toBe(disciplineB);
    expect(first.stages[0]).toMatchObject({ id: stageA, displayName: "Same stage", start: "2024-12-30", end: "2025-01-03" });
    expect(second.stages[0]).toMatchObject({ id: stageB, displayName: "Same stage", start: "2025-01-01", end: "2025-01-05" });
    expect(first.stages[0].activities.map((activity) => activity.id)).toEqual(["a", "z"]);
    expect(first.stages[0].activities[1]).toMatchObject({ activityType: "Marco", color: "#111111" });
    expect(second.stages[0].activities[0].color).toBe("#FEDCBA");
  });

  it("preserves same-date targets, civil dates, and missing boundaries without inventing dates", () => {
    const data = rows();
    data.activities = [{ id: root, productId: product, disciplineId: null, stageId: null,
      name: "Open", activityType: null, displayOrder: 0, plannedStart: null,
      plannedEnd: "2024-02-29", colorOverride: null }];
    const [current] = assembleExecutiveGantt(data);
    expect(current).toMatchObject({ start: null, end: "2024-02-29" });
    expect(current.rootActivities[0]).toMatchObject({ plannedStart: null, plannedEnd: "2024-02-29", color: "#8D9A89" });
    expect(current.disciplines[0].stages[0]).toMatchObject({ start: null, end: null });
    expect(current.targets.map((target) => [target.id, target.targetDate])).toEqual([
      ["target-a", "2025-01-04"], ["target-b", "2025-01-04"]
    ]);
    expect(current.targets[0].operationalDate).toBe("2025-01-06");
    expect(current.targets[0].description).toBe("Target detail");
  });

  it("uses a fixed read-only transaction with five workspace-scoped queries", async () => {
    transaction.mockClear();
    const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
    const result = await createExecutiveGanttRepository({ DATABASE_URL: "postgresql://example.invalid/neondb" }).read(workspaceId);
    expect(result).toEqual([]);
    expect(transaction).toHaveBeenCalledTimes(1);
    const [queries, options] = transaction.mock.calls[0] as unknown as [
      { text: string; values: unknown[] }[], { isolationLevel: string; readOnly: boolean }
    ];
    expect(queries).toHaveLength(5);
    expect(options).toEqual({ isolationLevel: "RepeatableRead", readOnly: true });
    for (const query of queries) {
      expect(query.text.trim()).toMatch(/^SELECT /);
      expect(query.text).toContain("workspace_id = ?::uuid");
      expect(query.values).toEqual([workspaceId]);
    }
  });
});
