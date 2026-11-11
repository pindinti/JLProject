import type { ScheduleTree } from "./schedule-workspace";

export interface ActivityMoveRequest {
  kind: "activity";
  targetId: string;
  expectedVersion: number;
  destinationDisciplineId: string | null;
  destinationStageId: string | null;
  destinationIndex: number;
  expectedSourceOrder: string[];
  expectedDestinationOrder: string[];
}

interface ActivityLocation {
  disciplineId: string | null;
  stageId: string | null;
  activities: ScheduleTree["rootActivities"];
}

function orderedActivities(activities: NonNullable<ActivityLocation["activities"]>) {
  return [...activities].sort((left, right) => left.displayOrder - right.displayOrder ||
    (left.id < right.id ? -1 : left.id > right.id ? 1 : 0));
}

function locateActivity(tree: ScheduleTree, activityId: string): ActivityLocation | null {
  const rootActivities = tree.rootActivities ?? [];
  const rootActivity = rootActivities.find((activity) => activity.id === activityId);
  if (rootActivity) return { disciplineId: null, stageId: null, activities: rootActivities };
  for (const discipline of tree.disciplines) {
    for (const stage of discipline.stages) {
      if (stage.activities.some((activity) => activity.id === activityId)) {
        return { disciplineId: discipline.id, stageId: stage.id, activities: stage.activities };
      }
    }
  }
  return null;
}

export function activitySiblingIds(tree: ScheduleTree, stageId: string | null): string[] | null {
  if (stageId === null) return orderedActivities(tree.rootActivities ?? []).map((activity) => activity.id);
  for (const discipline of tree.disciplines) {
    const stage = discipline.stages.find((candidate) => candidate.id === stageId);
    if (stage) return orderedActivities(stage.activities).map((activity) => activity.id);
  }
  return null;
}

export function activityParentStageId(tree: ScheduleTree, activityId: string): string | null | undefined {
  if ((tree.rootActivities ?? []).some((activity) => activity.id === activityId)) return null;
  for (const discipline of tree.disciplines) {
    for (const stage of discipline.stages) {
      if (stage.activities.some((activity) => activity.id === activityId)) return stage.id;
    }
  }
  return undefined;
}

export function buildActivityMoveRequest(tree: ScheduleTree, activityId: string,
  destinationStageId: string | null, destinationIndex: number): ActivityMoveRequest | null {
  const source = locateActivity(tree, activityId);
  if (!source) return null;
  const activity = source.activities?.find((candidate) => candidate.id === activityId);
  if (!activity || !Number.isSafeInteger(activity.version) || activity.version! < 1 ||
      !Number.isSafeInteger(destinationIndex) || destinationIndex < 0) return null;

  let destinationDisciplineId: string | null = null;
  let destinationActivities: NonNullable<ActivityLocation["activities"]>;
  if (destinationStageId === null) {
    destinationActivities = tree.rootActivities ?? [];
  } else {
    const destination = tree.disciplines.flatMap((discipline) => discipline.stages
      .filter((stage) => stage.id === destinationStageId).map((stage) => ({ discipline, stage })))[0];
    if (!destination) return null;
    destinationDisciplineId = destination.discipline.id;
    destinationActivities = destination.stage.activities;
  }

  const sameParent = source.stageId === destinationStageId;
  const sourceOrder = orderedActivities(source.activities ?? []).map((item) => item.id);
  const destinationOrder = sameParent ? sourceOrder : orderedActivities(destinationActivities).map((item) => item.id);
  const maximumIndex = destinationOrder.length - (sameParent ? 1 : 0);
  if (destinationIndex > maximumIndex) return null;

  return {
    kind: "activity", targetId: activityId, expectedVersion: activity.version!,
    destinationDisciplineId, destinationStageId, destinationIndex,
    expectedSourceOrder: sourceOrder, expectedDestinationOrder: destinationOrder
  };
}
