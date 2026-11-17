import { describe, expect, it } from "vitest";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  scheduleStageInterval, timelineInterval, timelinePosition, visibleScheduleRows,
  stageDateDiscrepancies,
  type ScheduleTree, type ScheduleTarget } from "../domain/schedule-workspace";

const tree: ScheduleTree = { disciplines: [{ id: "d", name: "Design", shortCode: "DS", color: "#123456", displayOrder: 0,
  stages: [{ id: "s", displayName: "Concept", code: "EC", color: "#334455", displayOrder: 0,
    plannedStart: null, plannedEnd: null, derivedStart: "2026-11-01", derivedEnd: "2026-11-12", activities: [
      { id: "a", name: "First", plannedStart: "2026-11-01", plannedEnd: "2026-11-08", displayOrder: 0, colorOverride: null },
      { id: "b", name: "Overlap", plannedStart: "2026-11-05", plannedEnd: "2026-11-12", displayOrder: 1, colorOverride: "#AABBCC" }
    ] }, { id: "empty", displayName: "Empty", code: "EP", color: "#445566", displayOrder: 1,
    plannedStart: null, plannedEnd: null, derivedStart: null, derivedEnd: null, activities: [] }] }] };
const targets: ScheduleTarget[] = [{ id: "t", name: "Target", description: null, color: "#AA4557",
  targetDate: "2026-11-10", operationalDate: null, displayOrder: 0, version: 1 }];

describe("schedule workspace model", () => {
  it("keeps explicit stage boundaries separate and does not fill a partial interval from activities", () => {
    expect(scheduleStageInterval(tree.disciplines[0]!.stages[0]!)).toEqual({
      start: "2026-11-01", end: "2026-11-12", source: "derived"
    });
    expect(scheduleStageInterval({ ...tree.disciplines[0]!.stages[0]!,
      plannedStart: "2026-12-01", plannedEnd: "2026-12-12" })).toEqual({
      start: "2026-12-01", end: "2026-12-12", source: "planned"
    });
    expect(scheduleStageInterval({ ...tree.disciplines[0]!.stages[0]!,
      plannedStart: "2026-12-01", plannedEnd: null })).toEqual({
      start: "2026-12-01", end: null, source: "planned"
    });
    expect(scheduleStageInterval({ ...tree.disciplines[0]!.stages[0]!,
      plannedStart: null, plannedEnd: "2026-12-12" })).toEqual({
      start: null, end: "2026-12-12", source: "planned"
    });
  });

  it("flattens expanded hierarchy once and keeps empty stages visible", () => {
    const rows = visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(["d"]), new Set(["s"]));
    expect(rows.map((row) => row.key)).toEqual(["product:p", "discipline:d", "stage:s", "activity:a", "activity:b", "stage:empty"]);
    expect(rows[2]).toMatchObject({ start: "2026-11-01", end: "2026-11-12" });
    expect(rows[5]).toMatchObject({ start: null, end: null });
    expect(rows[3]?.color).toBe("#334455");
    expect(rows[4]?.color).toBe("#AABBCC");
    expect(visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(), new Set(["s"]))
      .map((row) => row.key)).toEqual(["product:p", "discipline:d"]);
    expect(visibleScheduleRows({ id: "p", name: "Product" }, tree, new Set(["d"]), new Set(["s"]), false)
      .map((row) => row.key)).toEqual(["product:p"]);
  });

  it("uses explicit stage bounds for parent ranges and timeline extent without filling partial dates", () => {
    const plannedOnly: ScheduleTree = { disciplines: [{ ...tree.disciplines[0]!, stages: [
      { ...tree.disciplines[0]!.stages[1]!, plannedStart: "2027-02-10", plannedEnd: "2027-02-12" },
      { ...tree.disciplines[0]!.stages[0]!, plannedStart: "2027-03-01", plannedEnd: null }
    ] }] };
    const rows = visibleScheduleRows({ id: "p", name: "Product" }, plannedOnly, new Set(["d"]), new Set(["empty"]));
    expect(rows[0]).toMatchObject({ start: "2026-11-01", end: "2027-03-01" });
    expect(rows.find((row) => row.kind === "discipline")).toMatchObject({ start: "2026-11-01", end: "2027-03-01" });
    expect(rows.find((row) => row.key === "stage:empty")).toMatchObject({ start: "2027-02-10", end: "2027-02-12", dateSource: "planned" });
    expect(rows.find((row) => row.key === "stage:s")).toMatchObject({ start: "2027-03-01", end: null, dateSource: "planned" });
    const scale = makeTimeline(plannedOnly, [], "day", "2026-11-07");
    expect(civilFromDay(scale.endDay - 14)).toBe("2027-03-01");
  });

  it("reports activities outside only explicitly defined stage boundaries", () => {
    const stage = { ...tree.disciplines[0]!.stages[0]!, plannedStart: "2026-11-03", plannedEnd: "2026-11-10" };
    expect(stageDateDiscrepancies(stage)).toEqual([
      { activityId: "a", activityName: "First", boundary: "start", activityDate: "2026-11-01", stageDate: "2026-11-03" },
      { activityId: "b", activityName: "Overlap", boundary: "end", activityDate: "2026-11-12", stageDate: "2026-11-10" }
    ]);
    expect(stageDateDiscrepancies({ ...stage, plannedStart: "2026-11-01", plannedEnd: null })).toEqual([]);
    expect(stageDateDiscrepancies({ ...stage, plannedStart: null, plannedEnd: "2026-11-12" })).toEqual([]);
    expect(stageDateDiscrepancies(tree.disciplines[0]!.stages[0]!)).toEqual([]);
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

  it("updates inherited activity colors with the stage while retaining overrides", () => {
    const changed = { disciplines: [{ ...tree.disciplines[0]!, stages: [{ ...tree.disciplines[0]!.stages[0]!,
      color: "#778899" }, tree.disciplines[0]!.stages[1]!] }] };
    const rows = visibleScheduleRows({ id: "p", name: "Product" }, changed, new Set(["d"]), new Set(["s"]));
    expect(rows.find((row) => row.key === "activity:a")?.color).toBe("#778899");
    expect(rows.find((row) => row.key === "activity:b")?.color).toBe("#AABBCC");
  });

  it("places root activities before disciplines and includes their dates once", () => {
    const withRoots: ScheduleTree = { ...tree, rootActivities: [
      { id: "root-2", name: "Later root", plannedStart: "2026-12-01", plannedEnd: "2026-12-03",
        displayOrder: 1, colorOverride: "#AA5577" },
      { id: "root-1", name: "Earlier root", plannedStart: "2026-10-20", plannedEnd: "2026-10-22",
        displayOrder: 0, colorOverride: null }
    ] };
    const rows = visibleScheduleRows({ id: "p", name: "Product" }, withRoots, new Set(["d"]), new Set(["s"]));
    expect(rows.slice(0, 3).map((row) => row.key)).toEqual([
      "product:p", "activity:root-1", "activity:root-2"
    ]);
    expect(rows[1]?.color).toBe("#8D9A89");
    expect(rows[2]?.color).toBe("#AA5577");
    expect(rows[0]).toMatchObject({ start: "2026-10-20", end: "2026-12-03", hasChildren: true });
    const scale = makeTimeline(withRoots, targets, "day", "2026-11-07");
    expect(scale.startDay).toBe(dayNumber("2026-10-06"));
    expect(scale.endDay).toBe(dayNumber("2026-12-17"));
  });

  it("treats an omitted root collection in older schedule payloads as empty", () => {
    expect(visibleScheduleRows({ id: "p", name: "Product" }, { disciplines: [] }, new Set(), new Set()))
      .toEqual([{ key: "product:p", kind: "product", id: "p", label: "Product", start: null,
        end: null, hasChildren: false, expanded: true }]);
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
