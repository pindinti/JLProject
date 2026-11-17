import { describe, expect, it } from "vitest";
import { executiveStageBarLabel, groupExecutiveOverflow, groupExecutiveTargets, makeExecutiveTimeline,
  packExecutiveStages } from "../domain/executive-gantt-view";
import type { ExecutiveProduct, ExecutiveStage, ExecutiveTarget } from "../worker/executive-gantt";
import { dayNumber, timelineInterval, timelinePosition } from "../domain/schedule-workspace";
import { ganttTextColor } from "../src/design/gantt-colors";

const stage = (id: string, start: string | null, end: string | null): ExecutiveStage => ({
  id, productId: "product", disciplineId: "discipline", code: "EC", displayName: "Same name",
  color: "#123456", displayOrder: 0, start, end, plannedStart: null, plannedEnd: null,
  dateSource: "derived", derivedStart: start, derivedEnd: end, activities: []
});
const product = (): ExecutiveProduct => ({ id: "product", name: "Product", active: true,
  start: null, end: null, rootActivities: [], targets: [], disciplines: [] });
const target = (id: string, date: string, order: number): ExecutiveTarget => ({
  id, productId: "product", name: id, description: null, color: "#ABCDEF", displayOrder: order,
  targetDate: date, operationalDate: null
});

describe("compact executive Gantt layout", () => {
  it("includes explicit stage dates in its timeline extent, including zero-activity partial stages", () => {
    const planned: ExecutiveStage = { ...stage("planned-only", null, null),
      start: "2030-02-28", plannedStart: "2030-02-28", dateSource: "planned" };
    const value: ExecutiveProduct = { ...product(), disciplines: [{ id: "discipline", productId: "product",
      name: "Discipline", shortCode: "D", color: "#112233", displayOrder: 0, start: planned.start, end: planned.end,
      stages: [planned] }] };
    const scale = makeExecutiveTimeline([value], "month", "2026-11-07");
    expect(scale.startDay).toBe(dayNumber("2026-11-07") - 14);
    expect(scale.endDay).toBe(dayNumber("2030-02-28") + 14);
    expect(timelineInterval(scale, planned.start, planned.end)).toBeNull();
    expect(timelinePosition(scale, planned.start!)).toBeGreaterThan(0);
  });

  it("labels stage bars by discipline and stage while tolerating missing discipline metadata", () => {
    expect(executiveStageBarLabel({ name: "Architecture", shortCode: "A" },
      { code: "EC", displayName: "Executive Concept" }, true)).toBe("A – EC");
    expect(executiveStageBarLabel({ name: "Architecture", shortCode: "A" },
      { code: "EC", displayName: "Executive Concept" })).toBe("Architecture – Executive Concept");
    expect(executiveStageBarLabel(null, { code: "EC", displayName: "Executive Concept" }, true))
      .toBe("EC");
  });
  it("packs inclusive overlaps from separate disciplines and reuses lanes deterministically", () => {
    const value = product();
    value.disciplines = [
      { id: "first", productId: value.id, name: "First", shortCode: "F", color: "#111111",
        displayOrder: 0, start: null, end: null, stages: [stage("a", "2026-02-28", "2026-03-02")] },
      { id: "second", productId: value.id, name: "Second", shortCode: "S", color: "#222222",
        displayOrder: 1, start: null, end: null, stages: [stage("b", "2026-03-02", "2026-03-04"),
          stage("c", "2026-03-05", "2026-03-06")] }
    ];
    const layout = packExecutiveStages(value);
    expect(layout.laneCount).toBe(2);
    expect(layout.stages.map(({ stage: item, lane, discipline }) => [item.id, lane, discipline.id]))
      .toEqual([["a", 0, "first"], ["b", 1, "second"], ["c", 0, "second"]]);
    expect(layout.stages[0].stage.color).toBe("#123456");
  });

  it("marks partial stages at their known boundary and keeps fully undated stages off the timeline", () => {
    const value = product();
    value.disciplines = [{ id: "first", productId: value.id, name: "First", shortCode: "F", color: "#111111",
      displayOrder: 0, start: null, end: null, stages: [stage("start", "2024-02-29", null),
        stage("end", null, "2024-03-01"), stage("none", null, null)] }];
    const layout = packExecutiveStages(value);
    expect(layout.stages.map(({ stage: item, anchorDate, partial }) => [item.id, anchorDate, partial]))
      .toEqual([["start", "2024-02-29", true], ["end", "2024-03-01", true]]);
    expect(layout.undated.map(({ stage: item }) => item.id)).toEqual(["none"]);
  });

  it("clusters same-date targets and uses original civil dates for timeline positions", () => {
    const value = product();
    value.rootActivities = [{ id: "root", productId: value.id, disciplineId: null, stageId: null,
      name: "Root", activityType: null, displayOrder: 0, plannedStart: "2024-02-29",
      plannedEnd: "2024-03-02", colorOverride: null, color: "#8D9A89" }];
    value.targets = [target("later", "2024-03-01", 1), target("first", "2024-02-29", 1),
      target("earlier", "2024-02-29", 0)];
    const clusters = groupExecutiveTargets(value.targets);
    expect(clusters.map(({ date, targets }) => [date, targets.map((item) => item.id)]))
      .toEqual([["2024-02-29", ["earlier", "first"]], ["2024-03-01", ["later"]]]);
    const scale = makeExecutiveTimeline([value], "week", "2024-02-29");
    expect(timelinePosition(scale, "2024-03-01") - timelinePosition(scale, "2024-02-29"))
      .toBe(scale.dayWidth);
    expect(timelineInterval(scale, "2024-02-29", "2024-03-02")?.width).toBe(3 * scale.dayWidth);
  });

  it("keeps stage labels legible against configured light and dark colors", () => {
    expect(ganttTextColor("#112233")).toBe("#FFFFFF");
    expect(ganttTextColor("#F4D69A")).toBe("#252B28");
  });

  it("accounts for short badge width and groups hidden overlaps without losing stage identity", () => {
    const value = product();
    value.disciplines = [{ id: "first", productId: value.id, name: "First", shortCode: "F", color: "#111111",
      displayOrder: 0, start: null, end: null, stages: [stage("one", "2026-01-01", "2026-01-01"),
        stage("two", "2026-01-02", "2026-01-02"), stage("three", "2026-01-03", "2026-01-03")] }];
    const scale = makeExecutiveTimeline([value], "month", "2026-01-01");
    const packed = packExecutiveStages(value, Math.ceil(28 / scale.dayWidth));
    expect(packed.stages.map(({ stage: item, lane }) => [item.id, lane]))
      .toEqual([["one", 0], ["two", 1], ["three", 2]]);
    const groups = groupExecutiveOverflow(packed.stages.filter(({ lane }) => lane >= 2), scale);
    expect(groups).toHaveLength(1);
    expect(groups[0].stages.map(({ stage: item }) => item.id)).toEqual(["three"]);
    expect(groups[0].width).toBeGreaterThanOrEqual(28);
  });
});
