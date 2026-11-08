import type { ImportPreview } from "./import-preview";
import { colorForLabel, type ImportSubmission } from "./import-contract";

export function buildImportSubmission(
  preview: ImportPreview,
  productName: string,
  sourceFilename: string,
  idempotencyKey: string,
  confirmedSourceIds: ReadonlySet<string>
): ImportSubmission | null {
  if (preview.issues.some((issue) => issue.severity === "error" || issue.code === "count")) return null;
  const targets = preview.targets.map((target, index) => {
    const exact = target.matchedSourceId;
    const confirmed = preview.sourceMeta.find((meta) => meta.matchKind === "date_suggestion" &&
      meta.suggestedTargetRow === target.sourceRow && confirmedSourceIds.has(meta.sourceId));
    const matchedSourceId = exact ?? confirmed?.sourceId;
    if (!matchedSourceId) return null;
    return { name: target.name, sourceRow: target.sourceRow, targetDate: target.targetDate,
      operationalDate: target.operationalDate, status: target.status, notes: target.notes,
      displayOrder: index, matchedSourceId, matchMethod: exact ? "exact" as const : "date_confirmed" as const };
  });
  if (targets.some((target) => target === null)) return null;
  return {
    idempotencyKey, productName: productName.trim(), sourceFilename,
    disciplines: preview.disciplines.map((discipline, disciplineIndex) => ({
      name: discipline.name, shortCode: `D${disciplineIndex + 1}`,
      color: colorForLabel(discipline.name), displayOrder: disciplineIndex,
      stages: discipline.stages.map((stage, stageIndex) => ({
        code: stage.name, color: colorForLabel(stage.name), displayName: stage.name,
        displayOrder: stageIndex,
        activities: stage.activities.map((activity) => ({ sourceId: activity.sourceId,
          sourceRow: activity.sourceRow, name: activity.name, activityType: activity.type,
          status: activity.status, notes: activity.notes, plannedStart: activity.plannedStart,
          plannedEnd: activity.plannedEnd, displayOrder: activity.sourceRow }))
      }))
    })),
    sourceMeta: preview.sourceMeta.map((meta) => ({ sourceId: meta.sourceId, sourceRow: meta.sourceRow,
      name: meta.name, discipline: meta.discipline, stage: meta.stage,
      plannedStart: meta.plannedStart, plannedEnd: meta.plannedEnd, status: meta.status,
      notes: meta.notes })),
    targets: targets as ImportSubmission["targets"]
  };
}
