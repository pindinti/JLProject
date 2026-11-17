import { describe, expect, it } from "vitest";
import { visibleExecutiveFullRows, type ExecutiveCollapsed } from "../domain/executive-gantt-full";
import type { ExecutiveProduct } from "../worker/executive-gantt";

const open: ExecutiveCollapsed = { products: new Set(), disciplines: new Set(), stages: new Set() };
const products: ExecutiveProduct[] = [{
  id: "p", name: "Portfolio product", active: false, start: "2024-02-29", end: "2024-03-04",
  rootActivities: [{ id: "root", productId: "p", disciplineId: null, stageId: null,
    name: "Product activity", activityType: null, displayOrder: 0,
    plannedStart: "2024-02-29", plannedEnd: "2024-03-04", colorOverride: null, color: "#123456" }],
  disciplines: ["d1", "d2"].map((id, index) => ({ id, productId: "p", name: `Discipline ${index}`,
    shortCode: `D${index}`, color: "#654321", displayOrder: index,
    start: "2024-03-01", end: "2024-03-03", stages: [{
      id: `s${index}`, productId: "p", disciplineId: id, code: "EC", displayName: "Repeated stage",
      color: index ? "#AA5577" : "#22AA88", displayOrder: 0,
      start: index ? null : "2024-03-01", end: index ? null : "2024-03-03",
      activities: [{ id: `a${index}`, productId: "p", disciplineId: id, stageId: `s${index}`,
        name: `Activity ${index}`, activityType: null, displayOrder: 0,
        plannedStart: index ? null : "2024-03-01", plannedEnd: index ? null : "2024-03-03",
        colorOverride: null, color: "#808080" }] }] })),
  targets: []
}, { id: "empty", name: "Empty product", active: true, start: null, end: null,
  rootActivities: [], disciplines: [], targets: [] }];

describe("full Executive Gantt hierarchy", () => {
  it("projects four deterministic detail levels without reparenting root activities", () => {
    expect(visibleExecutiveFullRows(products, "products", open).map((row) => row.key))
      .toEqual(["product:p", "product:empty"]);
    expect(visibleExecutiveFullRows(products, "disciplines", open).map((row) => row.key))
      .toEqual(["product:p", "discipline:d1", "discipline:d2", "product:empty"]);
    expect(visibleExecutiveFullRows(products, "stages", open).map((row) => row.key))
      .toEqual(["product:p", "discipline:d1", "stage:s0", "discipline:d2", "stage:s1", "product:empty"]);
    const rows = visibleExecutiveFullRows(products, "activities", open);
    expect(rows.map((row) => row.key)).toEqual(["product:p", "activity:root", "discipline:d1",
      "stage:s0", "activity:a0", "discipline:d2", "stage:s1", "activity:a1", "product:empty"]);
    expect(rows[1]).toMatchObject({ depth: 1, discipline: null, stage: null,
      start: "2024-02-29", end: "2024-03-04" });
    expect(rows.filter((row) => row.kind === "stage").map((row) =>
      [row.id, row.label, row.discipline?.id, row.color, row.start]))
      .toEqual([["s0", "Repeated stage", "d1", "#22AA88", "2024-03-01"],
        ["s1", "Repeated stage", "d2", "#AA5577", null]]);
    expect(rows.at(-1)).toMatchObject({ id: "empty", start: null, end: null });
  });

  it("collapses intermediate levels and scopes a discipline filter to its product", () => {
    expect(visibleExecutiveFullRows(products, "activities", {
      products: new Set(["p"]), disciplines: new Set(), stages: new Set()
    }).map((row) => row.key)).toEqual(["product:p", "product:empty"]);
    expect(visibleExecutiveFullRows(products, "activities", {
      products: new Set(), disciplines: new Set(["d1"]), stages: new Set(["s1"])
    }).map((row) => row.key)).toEqual(["product:p", "activity:root", "discipline:d1",
      "discipline:d2", "stage:s1", "product:empty"]);
    expect(visibleExecutiveFullRows(products, "activities", open, "d2").map((row) => row.key))
      .toEqual(["product:p", "discipline:d2", "stage:s1", "activity:a1"]);
  });
});
