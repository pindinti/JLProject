import { dayNumber, makeTimeline, type TimelineScale, type Zoom } from "./schedule-workspace";
import type { ExecutiveDiscipline, ExecutiveProduct, ExecutiveStage, ExecutiveTarget } from "../worker/executive-gantt";

export interface PositionedExecutiveStage {
  stage: ExecutiveStage;
  discipline: ExecutiveDiscipline;
  lane: number;
  anchorDate: string;
  partial: boolean;
}

export interface PackedExecutiveStages {
  stages: PositionedExecutiveStage[];
  laneCount: number;
  undated: { stage: ExecutiveStage; discipline: ExecutiveDiscipline }[];
}

export interface ExecutiveTargetCluster {
  date: string;
  targets: ExecutiveTarget[];
}

export interface ExecutiveOverflowGroup {
  left: number;
  width: number;
  stages: PositionedExecutiveStage[];
}

function validDate(value: string | null): value is string {
  const match = value?.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1];
}

/** Greedy interval packing keeps each stage distinct and treats end dates as inclusive. */
export function packExecutiveStages(product: ExecutiveProduct, minimumVisualDays = 1): PackedExecutiveStages {
  const dated: { stage: ExecutiveStage; discipline: ExecutiveDiscipline; startDay: number; endDay: number;
    anchorDate: string; partial: boolean }[] = [];
  const undated: PackedExecutiveStages["undated"] = [];
  for (const discipline of product.disciplines) for (const stage of discipline.stages) {
    const start = validDate(stage.start) ? stage.start : null;
    const end = validDate(stage.end) ? stage.end : null;
    if (!start && !end || start && end && start > end) {
      undated.push({ stage, discipline });
      continue;
    }
    const anchorDate = start ?? end!;
    const startDay = dayNumber(anchorDate);
    dated.push({ stage, discipline, startDay,
      endDay: Math.max(dayNumber(end ?? anchorDate), startDay + Math.max(1, minimumVisualDays) - 1),
      anchorDate, partial: !start || !end });
  }
  dated.sort((left, right) => left.startDay - right.startDay || left.endDay - right.endDay ||
    left.discipline.displayOrder - right.discipline.displayOrder ||
    left.stage.displayOrder - right.stage.displayOrder || left.stage.id.localeCompare(right.stage.id));
  const laneEnds: number[] = [];
  const stages = dated.map(({ stage, discipline, startDay, endDay, anchorDate, partial }) => {
    let lane = laneEnds.findIndex((lastDay) => lastDay < startDay);
    if (lane < 0) lane = laneEnds.length;
    laneEnds[lane] = endDay;
    return { stage, discipline, lane, anchorDate, partial };
  });
  return { stages, laneCount: laneEnds.length, undated };
}

/** Groups hidden stages by their rendered interval so the compact track cannot conceal collisions. */
export function groupExecutiveOverflow(stages: readonly PositionedExecutiveStage[], scale: TimelineScale,
  minimumWidth = 28): ExecutiveOverflowGroup[] {
  const entries = stages.map((item) => {
    const left = (dayNumber(item.anchorDate) - scale.startDay) * scale.dayWidth;
    const actualWidth = item.partial || !item.stage.end ? scale.dayWidth
      : (dayNumber(item.stage.end) - dayNumber(item.anchorDate) + 1) * scale.dayWidth;
    return { item, left, right: left + Math.max(minimumWidth, actualWidth) };
  }).sort((left, right) => left.left - right.left || left.right - right.right ||
    left.item.stage.id.localeCompare(right.item.stage.id));
  const groups: { left: number; right: number; stages: PositionedExecutiveStage[] }[] = [];
  for (const entry of entries) {
    const last = groups.at(-1);
    if (last && entry.left <= last.right + 4) {
      last.right = Math.max(last.right, entry.right);
      last.stages.push(entry.item);
    } else groups.push({ left: entry.left, right: entry.right, stages: [entry.item] });
  }
  return groups.map(({ left, right, stages: items }) => ({ left, width: right - left, stages: items }));
}

export function groupExecutiveTargets(targets: readonly ExecutiveTarget[]): ExecutiveTargetCluster[] {
  const byDate = new Map<string, ExecutiveTarget[]>();
  for (const target of targets) {
    if (!validDate(target.targetDate)) continue;
    const group = byDate.get(target.targetDate) ?? [];
    group.push(target);
    byDate.set(target.targetDate, group);
  }
  return [...byDate].sort(([left], [right]) => left.localeCompare(right))
    .map(([date, group]) => ({ date, targets: group.sort((left, right) =>
      left.displayOrder - right.displayOrder || left.id.localeCompare(right.id)) }));
}

export function makeExecutiveTimeline(products: readonly ExecutiveProduct[], zoom: Zoom,
  today: string): TimelineScale {
  const activities = products.flatMap((product) => [
    ...product.rootActivities,
    ...product.disciplines.flatMap((discipline) => discipline.stages.flatMap((stage) => stage.activities))
  ]);
  const targets = products.flatMap((product) => product.targets);
  return makeTimeline({ disciplines: [], rootActivities: activities }, targets, zoom, today);
}
