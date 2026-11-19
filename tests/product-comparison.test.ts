import { describe, expect, it } from "vitest";
import { compareProductSchedules, type ComparisonOverride, type ComparisonRow } from "../domain/product-comparison";
import type { ComparisonSchedule } from "../worker/product-comparison";

type Hierarchy = ComparisonSchedule["hierarchy"];
type Activity = Hierarchy["rootActivities"][number];
type Discipline = Hierarchy["disciplines"][number];
type Stage = Discipline["stages"][number];

function activity(id: string, stageId: string | null): Activity {
  return { id, stageId, name: stageId ? "Review" : "Kickoff", activityType: "meeting", displayOrder: 0,
    plannedStart: "2026-03-08", plannedEnd: "2026-03-09", planningMode: "manual",
    workingDayDuration: null, planningCalendarVersion: null, notes: null, colorOverride: null, version: 1 };
}

function schedule(prefix: string): ComparisonSchedule {
  const discipline: Discipline = { id: `${prefix}-d`, productId: prefix, name: "Design", shortCode: "D", color: "#112233",
    displayOrder: 0, description: null, version: 1, stages: [] };
  const stage: Stage = { id: `${prefix}-s`, disciplineId: discipline.id, code: "R", displayName: "Review stage",
    color: "#112233", displayOrder: 0, version: 1, plannedStart: null, plannedEnd: null,
    derivedStart: "2026-03-08", derivedEnd: "2026-03-09", activities: [activity(`${prefix}-activity`, `${prefix}-s`)] };
  discipline.stages.push(stage);
  return { product: { id: prefix, workspaceId: "workspace", name: prefix, description: null, active: true,
    status: prefix === "A" ? "vigente" : "em_estudo", version: 8, createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z" }, cursor: { scheduleVersion: "8", historyWatermark: "42" },
  hierarchy: { productId: prefix, disciplines: [discipline], rootActivities: [activity(`${prefix}-root`, null)] },
  targets: [{ id: `${prefix}-target`, name: "Delivery", color: "#112233", description: null, displayOrder: 0,
    targetDate: "2026-03-10", operationalDate: null, version: 1 }] };
}

function flatten(rows: ComparisonRow[]): ComparisonRow[] {
  return rows.flatMap((row) => [row, ...flatten(row.children)]);
}

describe("product schedule comparison", () => {
  it("suggests equivalent cloned entities with regenerated IDs and ignores cosmetic colors and versions", () => {
    const left = schedule("A");
    const right = schedule("B");
    right.hierarchy.disciplines[0].color = "#000000";
    right.hierarchy.disciplines[0].stages[0].color = "#000000";
    right.hierarchy.rootActivities[0].colorOverride = "#000000";
    right.targets[0].color = "#000000";
    right.hierarchy.rootActivities[0].version = 42;
    const result = compareProductSchedules({ left, right });
    expect(result.summary).toEqual({ identical: 5, different: 0, only_a: 0, only_b: 0, ambiguous: 0, suggested: 5, manual: 0 });
    expect(result.a.status).toBe("vigente");
    expect(result.b.status).toBe("em_estudo");
    const discipline = result.hierarchy.find((row) => row.kind === "discipline");
    expect(discipline?.children[0].children[0]).toMatchObject({ status: "identical", match: "suggested",
      a: { id: "A-activity" }, b: { id: "B-activity" }, differences: [] });
    expect(result.targets[0]).toMatchObject({ match: "suggested", status: "identical" });
  });

  it("compares exact civil dates, planning metadata, explicit and derived bounds, and target attributes", () => {
    const left = schedule("A");
    const right = schedule("B");
    const stage = right.hierarchy.disciplines[0].stages[0];
    Object.assign(stage, { plannedStart: "2026-03-08", derivedEnd: "2026-03-10" });
    Object.assign(stage.activities[0], { plannedEnd: "2026-03-10", planningMode: "working_days",
      workingDayDuration: 2, planningCalendarVersion: 5 });
    Object.assign(right.targets[0], { targetDate: "2026-03-11", operationalDate: "2026-03-09", description: "Review milestone" });
    const result = compareProductSchedules({ left, right });
    const changedStage = flatten(result.hierarchy).find((row) => row.kind === "stage")!;
    expect(changedStage.a?.effectiveInterval).toEqual({ start: "2026-03-08", end: "2026-03-09", source: "derived" });
    expect(changedStage.b?.effectiveInterval).toEqual({ start: "2026-03-08", end: null, source: "planned" });
    expect(changedStage.differences).toEqual([
      { field: "plannedStart", a: null, b: "2026-03-08" },
      { field: "derivedEnd", a: "2026-03-09", b: "2026-03-10" },
      { field: "dateSource", a: "derived", b: "planned" }
    ]);
    expect(changedStage.children[0].differences).toEqual([
      { field: "plannedEnd", a: "2026-03-09", b: "2026-03-10" },
      { field: "planningMode", a: "manual", b: "working_days" },
      { field: "workingDayDuration", a: null, b: 2 },
      { field: "planningCalendarVersion", a: null, b: 5 }
    ]);
    expect(result.targets[0].differences.map(({ field }) => field)).toEqual(["description", "targetDate", "operationalDate"]);
    expect(result.summary.different).toBe(3);
  });

  it("reports a partial explicit end without borrowing the derived start, even across a leap day", () => {
    const left = schedule("A");
    const right = schedule("B");
    const stage = right.hierarchy.disciplines[0].stages[0];
    Object.assign(stage, { plannedEnd: "2028-02-29", derivedStart: "2028-02-28", derivedEnd: "2028-03-01" });
    const stageRow = flatten(compareProductSchedules({ left, right }).hierarchy).find((row) => row.kind === "stage");
    expect(stageRow?.b?.effectiveInterval).toEqual({ start: null, end: "2028-02-29", source: "planned" });
  });

  it("keeps independently created schedules comparable and leaves renames and missing entities unmatched without a pairing", () => {
    const left = schedule("A");
    const right = schedule("Independent");
    right.hierarchy.disciplines[0].description = "Independent schedule";
    right.hierarchy.disciplines[0].stages[0].displayName = "Renamed stage";
    right.hierarchy.rootActivities = [];
    right.targets[0].name = "Independent milestone";
    const result = compareProductSchedules({ left, right });
    expect(result.summary).toMatchObject({ suggested: 1, different: 1, only_a: 4, only_b: 3 });
    expect(result.targets.map((row) => row.status)).toEqual(["only_a", "only_b"]);
    expect(flatten(result.hierarchy).filter((row) => row.kind === "stage").map((row) => row.status)).toEqual(["only_a", "only_b"]);
  });

  it("reports manual renames, moves, types and order once, with A and B locations", () => {
    const left = schedule("A");
    const right = schedule("B");
    const leftStage = left.hierarchy.disciplines[0].stages[0];
    const rightStage = right.hierarchy.disciplines[0].stages[0];
    rightStage.displayName = "Renamed stage";
    rightStage.displayOrder = 2;
    rightStage.activities = [];
    right.hierarchy.rootActivities.push({ ...activity("B-moved", null), name: "New label", activityType: null, displayOrder: 4 });
    const overrides: ComparisonOverride[] = [
      { action: "pair", kind: "stage", aId: leftStage.id, bId: rightStage.id },
      { action: "pair", kind: "activity", aId: "A-activity", bId: "B-moved" }
    ];
    const result = compareProductSchedules({ left, right }, overrides);
    const rows = flatten(result.hierarchy);
    const stageRow = rows.find((row) => row.kind === "stage");
    expect(stageRow?.differences).toEqual([
      { field: "displayName", a: "Review stage", b: "Renamed stage" }, { field: "displayOrder", a: 0, b: 2 }
    ]);
    expect(stageRow?.children[0]).toMatchObject({ match: "manual", status: "different", b: { id: "B-moved" }, differences: [
      { field: "name", a: "Review", b: "New label" }, { field: "activityType", a: "meeting", b: null },
      { field: "displayOrder", a: 0, b: 4 }, { field: "location", a: { kind: "stage", id: "A-s" }, b: null }
    ] });
    expect(rows.filter((row) => row.b?.id === "B-moved")).toHaveLength(1);
    expect(result.summary).toMatchObject({ manual: 2, suggested: 3, different: 2 });
  });

  it("uses both discipline and stage labels and codes and limits activity suggestions to paired locations", () => {
    const left = schedule("A");
    const right = schedule("B");
    right.hierarchy.disciplines[0].shortCode = "OTHER";
    const rightStage = right.hierarchy.disciplines[0].stages[0];
    rightStage.code = "OTHER";
    right.hierarchy.rootActivities[0].activityType = null;
    const pairDiscipline: ComparisonOverride = { action: "pair", kind: "discipline", aId: "A-d", bId: "B-d" };
    const pairStage: ComparisonOverride = { action: "pair", kind: "stage", aId: "A-s", bId: "B-s" };
    expect(compareProductSchedules({ left, right }).summary.suggested).toBe(1);
    expect(compareProductSchedules({ left, right }, [pairDiscipline]).summary.suggested).toBe(1);
    expect(compareProductSchedules({ left, right }, [pairDiscipline, pairStage]).summary.suggested).toBe(2);
  });

  it("preserves ambiguous activity and target candidates and allows explicit user decisions to override them", () => {
    const left = schedule("A");
    const right = schedule("B");
    right.hierarchy.rootActivities.unshift({ ...right.hierarchy.rootActivities[0], id: "B-root-extra", displayOrder: 2 });
    right.targets.push({ ...right.targets[0], id: "B-target-extra" });
    const result = compareProductSchedules({ left, right });
    const root = result.hierarchy.find((row) => row.a?.id === "A-root");
    expect(root).toMatchObject({ status: "ambiguous", b: null, match: null, candidateIds: ["B-root", "B-root-extra"] });
    expect(result.targets[0]).toMatchObject({ status: "ambiguous", candidateIds: ["B-target", "B-target-extra"] });
    expect(result.summary).toMatchObject({ ambiguous: 6, suggested: 3 });
    const manual: ComparisonOverride = { action: "pair", kind: "activity", aId: "A-root", bId: "B-root-extra" };
    const unlink: ComparisonOverride = { action: "unlink", kind: "target", aId: "A-target", bId: "B-target" };
    const overridden = compareProductSchedules({ left, right }, [manual, unlink]);
    expect(overridden.hierarchy.find((row) => row.a?.id === "A-root")).toMatchObject({ match: "manual", b: { id: "B-root-extra" } });
    expect(overridden.targets[0].candidateIds).toEqual(["B-target-extra"]);
    expect(overridden.targets.find((row) => row.b?.id === "B-target")).toMatchObject({ status: "only_b", candidateIds: [] });
    expect(compareProductSchedules({ left, right })).toEqual(result);
  });

  it("blocks automatic links at any level and validates conflicting, duplicate or wrong-kind decisions", () => {
    const input = { left: schedule("A"), right: schedule("B") };
    const directive = { kind: "stage", aId: "A-s", bId: "B-s" } as const;
    const pair = { ...directive, action: "pair" } as const;
    const unlink = { ...directive, action: "unlink" } as const;
    expect(compareProductSchedules(input, [unlink]).summary).toMatchObject({ suggested: 3, only_a: 2, only_b: 2 });
    expect(() => compareProductSchedules(input, [pair, pair])).toThrow("more than once");
    expect(() => compareProductSchedules(input, [unlink, pair])).toThrow("both pair and unlink");
    expect(() => compareProductSchedules(input, [{ ...pair, bId: "B-root" }])).toThrow("same kind");
  });

  it("produces the same result for reordered input arrays and does not mutate either schedule", () => {
    const left = schedule("A");
    const right = schedule("B");
    left.hierarchy.rootActivities.push({ ...activity("A-extra", null), name: "Extra", displayOrder: 1 });
    const before = structuredClone(left);
    const original = compareProductSchedules({ left, right });
    expect(left).toEqual(before);
    const reordered = { ...left, hierarchy: { ...left.hierarchy, rootActivities: [...left.hierarchy.rootActivities].reverse() } };
    expect(compareProductSchedules({ left: reordered, right })).toEqual(original);
    const blank = { ...left, hierarchy: { ...left.hierarchy, rootActivities: [], disciplines: [] }, targets: [] };
    expect(compareProductSchedules({ left: blank, right: { ...blank, product: right.product } }).summary)
      .toEqual({ identical: 0, different: 0, only_a: 0, only_b: 0, ambiguous: 0, suggested: 0, manual: 0 });
  });
});
