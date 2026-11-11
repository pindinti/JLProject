export interface ScheduleActivity {
  id: string; name: string; plannedStart: string | null; plannedEnd: string | null;
  displayOrder: number; colorOverride: string | null; version?: number;
}
export const rootActivityDefaultColor = "#8D9A89";
export interface ScheduleStage {
  id: string; displayName: string; code: string; color: string; displayOrder: number;
  derivedStart: string | null; derivedEnd: string | null; activities: ScheduleActivity[];
}
export interface ScheduleDiscipline {
  id: string; name: string; shortCode: string; color: string; displayOrder: number; stages: ScheduleStage[];
}
export interface ScheduleTree {
  disciplines: ScheduleDiscipline[];
  rootActivities?: ScheduleActivity[];
}
export interface ScheduleTarget { id: string; name: string; description: string | null; color: string;
  targetDate: string; operationalDate: string | null; displayOrder: number; version: number }
export type VisibleRow = { key: string; kind: "product" | "discipline" | "stage" | "activity";
  id: string; disciplineId?: string; stageId?: string; label: string; code?: string;
  color?: string; start: string | null; end: string | null; hasChildren: boolean; expanded: boolean };
export type Zoom = "day" | "week" | "month";

const dayMilliseconds = 86_400_000;
export function dayNumber(date: string): number { return Math.floor(Date.parse(`${date}T00:00:00.000Z`) / dayMilliseconds); }
export function civilFromDay(day: number): string { return new Date(day * dayMilliseconds).toISOString().slice(0, 10); }

const saoPauloDate = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit"
});
export function saoPauloCivilDate(now: Date): string {
  const parts = Object.fromEntries(saoPauloDate.formatToParts(now).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function extent(values: (string | null)[]): { start: string | null; end: string | null } {
  const dates = values.filter((value): value is string => value !== null).sort();
  return { start: dates[0] ?? null, end: dates.at(-1) ?? null };
}

export function visibleScheduleRows(product: { id: string; name: string }, tree: ScheduleTree,
  openDisciplines: ReadonlySet<string>, openStages: ReadonlySet<string>, productExpanded = true): VisibleRow[] {
  const rootActivities = [...(tree.rootActivities ?? [])]
    .sort((left, right) => left.displayOrder - right.displayOrder || left.id.localeCompare(right.id));
  const stageActivities = tree.disciplines.flatMap((discipline) =>
    discipline.stages.flatMap((stage) => stage.activities));
  const allActivities = [...rootActivities, ...stageActivities];
  const productDates = extent(allActivities.flatMap((activity) => [activity.plannedStart, activity.plannedEnd]));
  const rows: VisibleRow[] = [{ key: `product:${product.id}`, kind: "product", id: product.id,
    label: product.name, start: productDates.start, end: productDates.end,
    hasChildren: rootActivities.length > 0 || tree.disciplines.length > 0, expanded: productExpanded }];
  if (!productExpanded) return rows;
  for (const activity of rootActivities) {
    rows.push({ key: `activity:${activity.id}`, kind: "activity", id: activity.id,
      label: activity.name, color: activity.colorOverride ?? rootActivityDefaultColor,
      start: activity.plannedStart, end: activity.plannedEnd, hasChildren: false, expanded: false });
  }
  for (const discipline of tree.disciplines) {
    const dates = extent(discipline.stages.flatMap((stage) => stage.activities.flatMap((activity) =>
      [activity.plannedStart, activity.plannedEnd])));
    const disciplineExpanded = openDisciplines.has(discipline.id);
    rows.push({ key: `discipline:${discipline.id}`, kind: "discipline", id: discipline.id,
      disciplineId: discipline.id, label: discipline.name, code: discipline.shortCode,
      color: discipline.color, start: dates.start, end: dates.end,
      hasChildren: discipline.stages.length > 0, expanded: disciplineExpanded });
    if (!disciplineExpanded) continue;
    for (const stage of discipline.stages) {
      const stageExpanded = openStages.has(stage.id);
      rows.push({ key: `stage:${stage.id}`, kind: "stage", id: stage.id,
        disciplineId: discipline.id, stageId: stage.id, label: stage.displayName, code: stage.code,
        color: stage.color, start: stage.derivedStart, end: stage.derivedEnd,
        hasChildren: stage.activities.length > 0, expanded: stageExpanded });
      if (!stageExpanded) continue;
      for (const activity of stage.activities) {
        rows.push({ key: `activity:${activity.id}`, kind: "activity", id: activity.id,
          disciplineId: discipline.id, stageId: stage.id, label: activity.name,
          color: activity.colorOverride ?? stage.color, start: activity.plannedStart, end: activity.plannedEnd,
          hasChildren: false, expanded: false });
      }
    }
  }
  return rows;
}

export interface TimelineScale {
  startDay: number; endDay: number; dayWidth: number; width: number;
  months: { startDay: number; days: number }[];
  ticks: number[];
}

export function makeTimeline(tree: ScheduleTree, targets: ScheduleTarget[], zoom: Zoom,
  today = saoPauloCivilDate(new Date()), previous?: Pick<TimelineScale, "startDay" | "endDay">): TimelineScale {
  const activities = [...(tree.rootActivities ?? []), ...tree.disciplines.flatMap((discipline) =>
    discipline.stages.flatMap((stage) => stage.activities))];
  const dates = [...activities.flatMap((activity) => [activity.plannedStart, activity.plannedEnd]),
    ...targets.map((target) => target.targetDate), today].filter((date): date is string => date !== null);
  const startDay = Math.min(Math.min(...dates.map(dayNumber)) - 14, previous?.startDay ?? Infinity);
  const endDay = Math.max(Math.max(...dates.map(dayNumber)) + 14, previous?.endDay ?? -Infinity);
  const dayWidth = zoom === "day" ? 30 : zoom === "week" ? 12 : 4;
  const months: TimelineScale["months"] = [];
  for (let day = startDay; day <= endDay;) {
    const current = new Date(day * dayMilliseconds);
    const nextMonth = Date.UTC(current.getUTCFullYear(), current.getUTCMonth() + 1, 1) / dayMilliseconds;
    const days = Math.min(nextMonth, endDay + 1) - day;
    months.push({ startDay: day, days });
    day += days;
  }
  const ticks: number[] = [];
  for (let day = startDay; day <= endDay; day++) {
    const current = new Date(day * dayMilliseconds);
    if (zoom === "day" || zoom === "week" && current.getUTCDay() === 1 ||
      zoom === "month" && current.getUTCDate() === 1) ticks.push(day);
  }
  return { startDay, endDay, dayWidth, width: (endDay - startDay + 1) * dayWidth, months, ticks };
}

export function timelinePosition(scale: TimelineScale, date: string): number {
  return (dayNumber(date) - scale.startDay) * scale.dayWidth;
}

export function timelineDateAtPosition(scale: TimelineScale, position: number): string {
  const offset = Math.max(0, Math.min(scale.endDay - scale.startDay, Math.floor(position / scale.dayWidth)));
  return civilFromDay(scale.startDay + offset);
}

export function timelineInterval(scale: TimelineScale, start: string | null, end: string | null):
  { left: number; width: number } | null {
  if (!start || !end) return null;
  return { left: timelinePosition(scale, start), width: (dayNumber(end) - dayNumber(start) + 1) * scale.dayWidth };
}
