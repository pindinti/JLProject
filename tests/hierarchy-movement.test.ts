import { describe, expect, it } from "vitest";
import { buildHierarchyMoveRequest, hierarchyParentId, hierarchySiblingIds } from "../domain/hierarchy-movement";
import type { ScheduleTree } from "../domain/schedule-workspace";

const activity = { id: "activity-a", stageId: "stage-a", name: "Synthetic activity", activityType: null,
  plannedStart: "2026-11-01", plannedEnd: "2026-11-03", displayOrder: 0, notes: null,
  colorOverride: null, version: 1, planningMode: "manual" as const, workingDayDuration: null,
  planningCalendarVersion: null };
const stageA = { id: "stage-a", disciplineId: "discipline-a", code: "A", color: "#123456",
  displayName: "Stage A", displayOrder: 0, derivedStart: activity.plannedStart,
  derivedEnd: activity.plannedEnd, version: 3, activities: [activity] };
const stageB = { ...stageA, id: "stage-b", disciplineId: "discipline-b", code: "B",
  displayName: "Stage B", displayOrder: 0, activities: [] };
const disciplineA = { id: "discipline-a", name: "Discipline A", shortCode: "A", color: "#234567",
  displayOrder: 0, version: 4, stages: [stageA] };
const disciplineB = { id: "discipline-b", name: "Discipline B", shortCode: "B", color: "#345678",
  displayOrder: 1, version: 8, stages: [stageB] };
const tree: ScheduleTree = { disciplines: [disciplineA, disciplineB], rootActivities: [] };

describe("hierarchy movement request builder", () => {
  it("builds stage reorder and cross-discipline requests with complete sibling snapshots", () => {
    const stageC = { ...stageA, id: "stage-c", displayOrder: 1 };
    const orderedTree = { ...tree, disciplines: [{ ...disciplineA, stages: [stageA, stageC] }, disciplineB] };
    expect(buildHierarchyMoveRequest(orderedTree, "stage", "stage-c", "discipline-a", 0)).toEqual({
      kind: "stage", targetId: "stage-c", expectedVersion: 3, destinationDisciplineId: "discipline-a",
      destinationStageId: null, destinationIndex: 0, expectedSourceOrder: ["stage-a", "stage-c"],
      expectedDestinationOrder: ["stage-a", "stage-c"]
    });
    expect(buildHierarchyMoveRequest(tree, "stage", "stage-a", "discipline-b", 0)).toEqual({
      kind: "stage", targetId: "stage-a", expectedVersion: 3, destinationDisciplineId: "discipline-b",
      destinationStageId: null, destinationIndex: 0, expectedSourceOrder: ["stage-a"],
      expectedDestinationOrder: ["stage-b"]
    });
  });

  it("builds discipline reorder requests against the product sibling list", () => {
    expect(buildHierarchyMoveRequest(tree, "discipline", "discipline-b", null, 0)).toEqual({
      kind: "discipline", targetId: "discipline-b", expectedVersion: 8, destinationDisciplineId: null,
      destinationStageId: null, destinationIndex: 0, expectedSourceOrder: ["discipline-a", "discipline-b"],
      expectedDestinationOrder: ["discipline-a", "discipline-b"]
    });
    expect(hierarchySiblingIds(tree, "discipline", null)).toEqual(["discipline-a", "discipline-b"]);
    expect(hierarchyParentId(tree, "discipline", "discipline-a")).toBeNull();
  });

  it("rejects missing items, versions, parents, and out-of-range positions", () => {
    expect(buildHierarchyMoveRequest(tree, "stage", "missing", "discipline-a", 0)).toBeNull();
    expect(buildHierarchyMoveRequest({ ...tree, disciplines: [{ ...disciplineA, stages: [{ ...stageA, version: undefined }] }, disciplineB] },
      "stage", "stage-a", "discipline-a", 0)).toBeNull();
    expect(buildHierarchyMoveRequest(tree, "stage", "stage-a", null, 0)).toBeNull();
    expect(buildHierarchyMoveRequest(tree, "stage", "stage-a", "missing-discipline", 0)).toBeNull();
    expect(buildHierarchyMoveRequest(tree, "discipline", "discipline-a", "discipline-b", 0)).toBeNull();
    expect(buildHierarchyMoveRequest(tree, "discipline", "discipline-a", null, 2)).toBeNull();
  });
});
