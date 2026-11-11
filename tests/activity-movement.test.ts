import { describe, expect, it } from "vitest";
import { activityParentStageId, activitySiblingIds, buildActivityMoveRequest } from "../domain/activity-movement";
import type { ScheduleTree } from "../domain/schedule-workspace";

const tree: ScheduleTree = {
  rootActivities: [{ id: "root-a", name: "Root A", plannedStart: null, plannedEnd: null,
    displayOrder: 1, colorOverride: null, version: 4 },
  { id: "root-b", name: "Root B", plannedStart: null, plannedEnd: null,
    displayOrder: 0, colorOverride: "#AA5577", version: 2 }],
  disciplines: [{ id: "discipline-a", name: "Design", shortCode: "DS", color: "#223344", displayOrder: 0,
    stages: [{ id: "stage-a", displayName: "Concept", code: "EC", color: "#336699", displayOrder: 0,
      derivedStart: null, derivedEnd: null, activities: [
        { id: "activity-a", name: "A", plannedStart: "2026-01-01", plannedEnd: "2026-01-02",
          displayOrder: 1, colorOverride: null, version: 3 },
        { id: "activity-b", name: "B", plannedStart: null, plannedEnd: null,
          displayOrder: 0, colorOverride: "#BB6677", version: 5 }
      ] }, { id: "stage-empty", displayName: "Empty", code: "EP", color: "#778899", displayOrder: 1,
      derivedStart: null, derivedEnd: null, activities: [] }] }]
};

describe("activity hierarchy move request", () => {
  it("builds a same-stage reorder with the full sibling snapshot and current version", () => {
    expect(buildActivityMoveRequest(tree, "activity-a", "stage-a", 0)).toEqual({
      kind: "activity", targetId: "activity-a", expectedVersion: 3,
      destinationDisciplineId: "discipline-a", destinationStageId: "stage-a", destinationIndex: 0,
      expectedSourceOrder: ["activity-b", "activity-a"],
      expectedDestinationOrder: ["activity-b", "activity-a"]
    });
  });

  it("builds stage, root, and empty-root moves without deriving new IDs or metadata", () => {
    expect(buildActivityMoveRequest(tree, "root-a", "stage-empty", 0)).toMatchObject({
      targetId: "root-a", expectedVersion: 4, destinationDisciplineId: "discipline-a",
      destinationStageId: "stage-empty", expectedSourceOrder: ["root-b", "root-a"], expectedDestinationOrder: []
    });
    expect(buildActivityMoveRequest(tree, "activity-b", null, 1)).toMatchObject({
      targetId: "activity-b", expectedVersion: 5, destinationDisciplineId: null, destinationStageId: null,
      destinationIndex: 1, expectedSourceOrder: ["activity-b", "activity-a"], expectedDestinationOrder: ["root-b", "root-a"]
    });
    const emptyRoot: ScheduleTree = { disciplines: tree.disciplines };
    expect(buildActivityMoveRequest(emptyRoot, "activity-a", null, 0)).toMatchObject({
      destinationStageId: null, expectedSourceOrder: ["activity-b", "activity-a"], expectedDestinationOrder: []
    });
    expect(buildActivityMoveRequest(tree, "root-b", null, 1)).toMatchObject({
      targetId: "root-b", destinationDisciplineId: null, destinationStageId: null, destinationIndex: 1,
      expectedSourceOrder: ["root-b", "root-a"], expectedDestinationOrder: ["root-b", "root-a"]
    });
  });

  it("rejects missing activities, missing destinations, and out-of-range positions", () => {
    expect(buildActivityMoveRequest(tree, "missing", null, 0)).toBeNull();
    expect(buildActivityMoveRequest(tree, "activity-a", "missing-stage", 0)).toBeNull();
    expect(buildActivityMoveRequest(tree, "activity-a", "stage-a", 2)).toBeNull();
    expect(buildActivityMoveRequest({ ...tree, disciplines: [{ ...tree.disciplines[0]!, stages: [{
      ...tree.disciplines[0]!.stages[0]!, activities: [{ ...tree.disciplines[0]!.stages[0]!.activities[0]!, version: undefined }]
    }] }] }, "activity-a", null, 0)).toBeNull();
  });

  it("returns sibling orders and parent IDs from the loaded hierarchy only", () => {
    expect(activitySiblingIds(tree, "stage-a")).toEqual(["activity-b", "activity-a"]);
    expect(activitySiblingIds(tree, "missing-stage")).toBeNull();
    expect(activityParentStageId(tree, "root-a")).toBeNull();
    expect(activityParentStageId(tree, "activity-a")).toBe("stage-a");
    expect(activityParentStageId(tree, "missing")).toBeUndefined();
  });
});
