import { describe, expect, it } from "vitest";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  timelineInterval, timelinePosition, visibleScheduleRows,
  type ScheduleTree, type ScheduleTarget } from "../domain/schedule-workspace";

const tree: ScheduleTree = { disciplines: [{ id: "d", name: "Design", shortCode: "DS", color: "#123456", displayOrder: 0,
  stages: [{ id: "s", displayName: "Concept", code: "EC", color: "#334455", displayOrder: 0,
    derivedStart: "2026-11-01", derivedEnd: "2026-11-12", activities: [
      { id: "a", name: "First", plannedStart: "2026-11-01", plannedEnd: "2026-11-08", displayOrder: 0 },
      { id: "b", name: "Overlap", plannedStart: "2026-11-05", plannedEnd: "2026-11-12", displayOrder: 1 }
    ] }, { id: "empty", displayName: "Empty", code: "EP", color: "#445566", displayOrder: 1,
    derivedStart: null, derivedEnd: null, activities: [] }] }] };
const targets: ScheduleTarget[] = [{ id: "t", name: "Target", description: null, color: "#AA4557",
  targetDate: "2026-11-10", operationalDate: null, displayOrder: 0, version: 1 }];

describe("schedule workspace model", () => {
  it("flattens expanded hierarchy once and keeps empty stages visible", () => {
    const rows = visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(["d"]), new Set(["s"]));
    expect(rows.map((row) => row.key)).toEqual(["product:p", "discipline:d", "stage:s", "activity:a", "activity:b", "stage:empty"]);
    expect(rows[2]).toMatchObject({ start: "2026-11-01", end: "2026-11-12" });
    expect(rows[5]).toMatchObject({ start: null, end: null });
    expect(visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(), new Set(["s"]))
      .map((row) => row.key)).toEqual(["product:p", "discipline:d"]);
    expect(visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(["d"]), new Set(["s"]), false)
      .map((row) => row.key)).toEqual(["product:p"]);
  });

  it("positions overlapping intervals and targets by exact UTC civil days", () => {
    const scale = makeTimeline(tree, targets, "week");
    const first = timelineInterval(scale, "2026-11-01", "2026-11-08");
    const overlap = timelineInterval(scale, "2026-11-05", "2026-11-12");
    const summary = timelineInterval(scale, "2026-11-01", "2026-11-12");
    expect(first).toEqual({ left: timelinePosition(scale, "2026-11-01"), width: 8 * scale.dayWidth });
    expect(overlap?.left).toBe(first!.left + 4 * scale.dayWidth);
    expect(overlap!.left).toBeLessThan(first!.left + first!.width);
    expect(summary?.width).toBe(12 * scale.dayWidth);
    expect(timelinePosition(scale, targets[0].targetDate)).toBe(first!.left + 9 * scale.dayWidth);
    expect(timelineInterval(scale, null, null)).toBeNull();
    expect(dayNumber("2026-11-01") - dayNumber("2026-10-31")).toBe(1);
  });

  it("changes horizontal scale without changing dates or row order", () => {
    const day = makeTimeline(tree, targets, "day");
    const week = makeTimeline(tree, targets, "week");
    const month = makeTimeline(tree, targets, "month");
    expect([day.dayWidth, week.dayWidth, month.dayWidth]).toEqual([30, 12, 4]);
    expect(day.startDay).toBe(week.startDay);
    expect(week.endDay).toBe(month.endDay);
    expect(day.ticks.length).toBeGreaterThan(week.ticks.length);
    expect(week.ticks.length).toBeGreaterThan(month.ticks.length);
    expect(timelineInterval(month, "2026-11-01", "2026-11-01")?.width).toBe(4);
  });

  it("uses the São Paulo calendar date across the UTC midnight boundary", () => {
    expect(saoPauloCivilDate(new Date("2026-11-07T02:59:59Z"))).toBe("2026-11-06");
    expect(saoPauloCivilDate(new Date("2026-11-07T03:00:00Z"))).toBe("2026-11-07");
    const scale = makeTimeline(tree, targets, "day", "2026-11-07");
    expect(timelinePosition(scale, "2026-11-07") - timelinePosition(scale, "2026-11-06"))
      .toBe(scale.dayWidth);
  });

  it("selects an exact civil date from a shared horizontal coordinate at every zoom", () => {
    for (const zoom of ["day", "week", "month"] as const) {
      const scale = makeTimeline(tree, targets, zoom, "2026-11-07");
      const position = timelinePosition(scale, "2026-11-05");
      expect(timelineDateAtPosition(scale, position + scale.dayWidth * 0.8)).toBe("2026-11-05");
      expect(timelineDateAtPosition(scale, -100)).toBe("2026-10-18");
      expect(timelineDateAtPosition(scale, scale.width + 100)).toBe(civilFromDay(scale.endDay));
    }
  });
});
