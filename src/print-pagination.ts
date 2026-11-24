import { civilFromDay, dayNumber } from "../domain/schedule-workspace";

export interface PrintDateSegment { start: string; end: string }
export interface PrintRow { key: string; parentKey?: string | null; hasChildren?: boolean; heightUnits?: number }
export interface PrintPage<T extends PrintRow> { rows: T[]; dates: PrintDateSegment }
type PrintDates = { start: string | null; end: string | null };
type DatedPrintRow = PrintRow & PrintDates & { bars?: readonly PrintDates[]; milestones?: readonly { date: string }[] };

export function partitionPrintDates(start: string, end: string, maxDays: number): PrintDateSegment[] {
  if (start > end || !Number.isInteger(maxDays) || maxDays < 1) return [];
  const pages: PrintDateSegment[] = [];
  for (let day = dayNumber(start); day <= dayNumber(end); day += maxDays) {
    pages.push({ start: civilFromDay(day), end: civilFromDay(Math.min(day + maxDays - 1, dayNumber(end))) });
  }
  return pages;
}

export function planPrintTimeline(start: string, end: string, widthMm: number) {
  const total = dayNumber(end) - dayNumber(start) + 1;
  // Budget 10 mm for a compact 8 pt MM/YYYY label in the shortest month.
  const maxDays = Math.max(1, Math.floor(widthMm * 28 / 10));
  const daysPerPage = Math.max(1, Math.ceil(total / Math.max(1, Math.ceil(total / maxDays))));
  return { segments: partitionPrintDates(start, end, daysPerPage), daysPerPage, mmPerDay: widthMm / daysPerPage };
}

export function selectPrintRows<T extends DatedPrintRow>(rows: readonly T[], dates: readonly PrintDateSegment[],
  includeRowDates = true, includeMilestones = true): T[][] {
  const byKey = new Map(rows.map((row) => [row.key, row]));
  const selections = dates.map(() => new Set<string>());
  function select(selection: Set<string>, row: T | undefined) {
    while (row && !selection.has(row.key)) {
      selection.add(row.key);
      row = byKey.get(row.parentKey ?? "");
    }
  }
  for (const row of rows) {
    dates.forEach((segment, index) => {
      if ([...(includeRowDates ? [row] : []), ...(row.bars ?? [])].some(({ start, end }) => {
        const first = start ?? end;
        const last = end ?? start;
        return first && last && first <= segment.end && last >= segment.start;
      }) || (includeMilestones && row.milestones?.some(({ date }) => date >= segment.start && date <= segment.end))) {
        select(selections[index], row);
      }
    });
  }
  for (const row of rows) {
    if (selections[0] && !selections.some((selection) => selection.has(row.key))) select(selections[0], row);
  }
  return selections.map((selection) => rows.filter((row) => selection.has(row.key)));
}

export function paginatePrintRows<T extends PrintRow>(rows: readonly T[], capacity: number,
  pageOverhead?: (rows: readonly T[]) => number): T[][] {
  if (!rows.length || !Number.isFinite(capacity) || capacity < 2) return rows.length ? [Array.from(rows)] : [];
  const weight = ({ heightUnits = 1 }: T) => Number.isFinite(heightUnits) && heightUnits > 0 ? heightUnits : 1;
  const parents = new Map(rows.map((row) => [row.key, row]));
  const startsChild = (index: number) => rows[index + 1]?.parentKey === rows[index].key;
  const pages: T[][] = [];
  let start = 0;
  while (start < rows.length) {
    const context: T[] = [];
    if (pages.length) {
      let parent = parents.get(rows[start].parentKey ?? "");
      while (parent && !context.includes(parent)) {
        context.unshift(parent);
        parent = parents.get(parent.parentKey ?? "");
      }
    }
    const room = Math.max(1, capacity - context.reduce((sum, row) => sum + weight(row), 0));
    let end = start;
    let used = 0;
    while (end < rows.length) {
      let groupEnd = end;
      let groupWeight = weight(rows[groupEnd]);
      while (startsChild(groupEnd)) groupWeight += weight(rows[++groupEnd]);
      const overhead = pageOverhead?.([...context, ...rows.slice(start, groupEnd + 1)]) ?? 0;
      if (end > start && used + groupWeight + overhead > room) break;
      used += groupWeight;
      end = groupEnd + 1;
    }
    pages.push([...context, ...rows.slice(start, end)]);
    start = end;
  }
  return pages;
}
