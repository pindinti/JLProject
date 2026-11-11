import type { ScheduleTree } from "./schedule-workspace";

export type HierarchyMoveKind = "activity" | "stage" | "discipline";
export interface HierarchyMoveRequest {
  kind: HierarchyMoveKind;
  targetId: string;
  expectedVersion: number;
  destinationDisciplineId: string | null;
  destinationStageId: string | null;
  destinationIndex: number;
  expectedSourceOrder: string[];
  expectedDestinationOrder: string[];
}

interface LocatedItem { parentId: string | null; version: number | undefined; siblingIds: string[] }

function compareId(left: string, right: string): number { return left < right ? -1 : left > right ? 1 : 0; }
function ordered<T extends { id: string; displayOrder: number }>(items: T[]): T[] {
  return [...items].sort((left, right) => left.displayOrder - right.displayOrder || compareId(left.id, right.id));
}

function locateItem(tree: ScheduleTree, kind: HierarchyMoveKind, targetId: string): LocatedItem | null {
  if (kind === "discipline") {
    const siblings = ordered(tree.disciplines);
    const item = siblings.find((candidate) => candidate.id === targetId);
    return item ? { parentId: null, version: item.version, siblingIds: siblings.map(({ id }) => id) } : null;
  }
  if (kind === "stage") {
    for (const discipline of tree.disciplines) {
      const siblings = ordered(discipline.stages);
      const item = siblings.find((candidate) => candidate.id === targetId);
      if (item) return { parentId: discipline.id, version: item.version, siblingIds: siblings.map(({ id }) => id) };
    }
    return null;
  }
  const rootActivities = ordered(tree.rootActivities ?? []);
  const rootItem = rootActivities.find((candidate) => candidate.id === targetId);
  if (rootItem) return { parentId: null, version: rootItem.version, siblingIds: rootActivities.map(({ id }) => id) };
  for (const discipline of tree.disciplines) {
    for (const stage of discipline.stages) {
      const siblings = ordered(stage.activities);
      const item = siblings.find((candidate) => candidate.id === targetId);
      if (item) return { parentId: stage.id, version: item.version, siblingIds: siblings.map(({ id }) => id) };
    }
  }
  return null;
}

function destinationDisciplineForActivity(tree: ScheduleTree, stageId: string): string | null {
  return tree.disciplines.find((discipline) => discipline.stages.some((stage) => stage.id === stageId))?.id ?? null;
}

export function hierarchySiblingIds(tree: ScheduleTree, kind: HierarchyMoveKind, parentId: string | null): string[] | null {
  if (kind === "discipline") return parentId === null ? ordered(tree.disciplines).map(({ id }) => id) : null;
  if (kind === "stage") {
    if (parentId === null) return null;
    const discipline = tree.disciplines.find((candidate) => candidate.id === parentId);
    return discipline ? ordered(discipline.stages).map(({ id }) => id) : null;
  }
  if (parentId === null) return ordered(tree.rootActivities ?? []).map(({ id }) => id);
  for (const discipline of tree.disciplines) {
    const stage = discipline.stages.find((candidate) => candidate.id === parentId);
    if (stage) return ordered(stage.activities).map(({ id }) => id);
  }
  return null;
}

export function hierarchyParentId(tree: ScheduleTree, kind: HierarchyMoveKind, targetId: string): string | null | undefined {
  const item = locateItem(tree, kind, targetId);
  return item ? item.parentId : undefined;
}

export function buildHierarchyMoveRequest(tree: ScheduleTree, kind: HierarchyMoveKind, targetId: string,
  destinationParentId: string | null, destinationIndex: number): HierarchyMoveRequest | null {
  const source = locateItem(tree, kind, targetId);
  if (!source || !Number.isSafeInteger(source.version) || source.version! < 1 ||
      !Number.isSafeInteger(destinationIndex) || destinationIndex < 0) return null;
  if ((kind === "discipline" && destinationParentId !== null) ||
      (kind === "stage" && (destinationParentId === null ||
        !tree.disciplines.some((discipline) => discipline.id === destinationParentId))) ||
      (kind === "activity" && destinationParentId !== null &&
        !tree.disciplines.some((discipline) => discipline.stages.some((stage) => stage.id === destinationParentId))))
    return null;

  const destinationOrder = hierarchySiblingIds(tree, kind, destinationParentId);
  if (!destinationOrder) return null;
  const sameParent = source.parentId === destinationParentId;
  const maximumIndex = destinationOrder.length - (sameParent ? 1 : 0);
  if (destinationIndex > maximumIndex) return null;

  let destinationDisciplineId: string | null = null;
  let destinationStageId: string | null = null;
  if (kind === "stage") destinationDisciplineId = destinationParentId;
  else if (kind === "activity" && destinationParentId !== null) {
    destinationDisciplineId = destinationDisciplineForActivity(tree, destinationParentId);
    if (destinationDisciplineId === null) return null;
    destinationStageId = destinationParentId;
  }

  return { kind, targetId, expectedVersion: source.version!, destinationDisciplineId, destinationStageId,
    destinationIndex, expectedSourceOrder: source.siblingIds,
    expectedDestinationOrder: sameParent ? source.siblingIds : destinationOrder };
}
