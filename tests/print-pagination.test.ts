import { describe, expect, it } from "vitest";
import { paginatePrintRows, partitionPrintDates, planPrintTimeline, selectPrintRows } from "../src/print-pagination";

describe("print pagination", () => {
  it("reserves each sheet's supplementary key without charging identical entries twice", () => {
    const rows = [
      { key: "1", heightUnits: 9, alias: "ARQ" },
      { key: "2", heightUnits: 9, alias: "ARQ" },
      { key: "3", heightUnits: 9, alias: "PAIS" },
    ];
    expect(paginatePrintRows(rows, 31, (page) => new Set(page.map((row) => row.alias)).size * 3)
      .map((page) => page.map((row) => row.key))).toEqual([["1", "2"], ["3"]]);
  });

  it("does not generate aggregate-only products on executive continuations", () => {
    const dates = partitionPrintDates("2026-01-01", "2026-01-03", 1);
    const rows = [{ key: "stages", start: "2026-01-01", end: "2026-01-03",
      bars: [{ start: "2026-01-02", end: "2026-01-02" }] },
    { key: "undated-only", start: "2026-01-01", end: "2026-01-03", bars: [{ start: null, end: null }] }];
    expect(selectPrintRows(rows, dates, false).map((page) => page.map((row) => row.key)))
      .toEqual([["undated-only"], ["stages"], []]);
    const owned = [{ ...rows[0], milestones: [{ date: "2026-01-03" }] }];
    expect(selectPrintRows(owned, dates, false).map((page) => page.map((row) => row.key)))
      .toEqual([[], ["stages"], ["stages"]]);
    expect(selectPrintRows(owned, dates, false, false).map((page) => page.map((row) => row.key)))
      .toEqual([[], ["stages"], []]);
  });
  it("fits a readable multi-year range and keeps one scale on a long range", () => {
    expect(planPrintTimeline("2025-01-01", "2026-12-31", 270).segments).toHaveLength(1);
    const timeline = planPrintTimeline("2025-01-01", "2029-01-05", 270);
    expect(timeline.segments.length).toBeGreaterThan(1);
    expect(timeline.segments.at(-1)?.end).toBe("2029-01-05");
    expect(timeline.mmPerDay).toBe(270 / timeline.daysPerPage);
  });

  it("omits redundant rows from date continuations while retaining every selected row", () => {
    const rows = [
      { key: "parent", hasChildren: true, start: null, end: null },
      { key: "early", parentKey: "parent", start: "2026-01-01", end: null },
      { key: "undated", parentKey: "parent", start: null, end: null },
      { key: "late", parentKey: "parent", start: "2026-01-03", end: "2026-01-03" },
      { key: "outside", start: "2026-02-01", end: "2026-02-02" },
    ];
    const dates = partitionPrintDates("2026-01-01", "2026-01-03", 1);
    expect(selectPrintRows(rows, dates).map((page) => page.map((row) => row.key)))
      .toEqual([["parent", "early", "undated", "outside"], [], ["parent", "late"]]);
  });
  it("partitions inclusive date ranges without gaps", () => {
    expect(partitionPrintDates("2026-01-01", "2026-01-05", 2)).toEqual([
      { start: "2026-01-01", end: "2026-01-02" },
      { start: "2026-01-03", end: "2026-01-04" },
      { start: "2026-01-05", end: "2026-01-05" }
    ]);
  });

  it("keeps a one-day schedule on one date and row page", () => {
    const dates = partitionPrintDates("2026-02-28", "2026-02-28", 365);
    expect(dates).toEqual([{ start: "2026-02-28", end: "2026-02-28" }]);
    expect(paginatePrintRows(selectPrintRows([{ key: "only-row", start: "2026-02-28", end: null }], dates)[0], 24)).toHaveLength(1);
  });

  it("keeps a parent heading with a child at the next page boundary", () => {
    const rows = [
      { key: "p", parentKey: null, hasChildren: true },
      { key: "c1", parentKey: "p", hasChildren: false },
      { key: "c2", parentKey: "p", hasChildren: false },
      { key: "c3", parentKey: "p", hasChildren: false }
    ];
    expect(paginatePrintRows(rows, 2).map((page) => page.map((row) => row.key)))
      .toEqual([["p", "c1"], ["p", "c2"], ["p", "c3"]]);
  });

  it("does not leave a nested parent as the last row when another child follows", () => {
    const rows = [
      { key: "root", parentKey: null, hasChildren: true },
      { key: "sibling", parentKey: "root", hasChildren: false },
      { key: "nested", parentKey: "root", hasChildren: true },
      { key: "leaf", parentKey: "nested", hasChildren: false }
    ];
    const pages = paginatePrintRows(rows, 2);
    expect(pages.map((page) => page.map((row) => row.key))).toEqual([
      ["root", "sibling"], ["root", "nested", "leaf"]
    ]);
  });

  it("paginates rows by their estimated rendered height", () => {
    const rows = [
      { key: "long", heightUnits: 3 },
      { key: "short", heightUnits: 1 },
      { key: "longer", heightUnits: 3 }
    ];
    expect(paginatePrintRows(rows, 4).map((page) => page.map((row) => row.key)))
      .toEqual([["long", "short"], ["longer"]]);
  });

  it("continues rows vertically inside each date interval", () => {
    const rows = ["a", "b", "c"].map((key) => ({ key, start: "2026-01-01", end: "2026-01-03" }));
    const dates = partitionPrintDates("2026-01-01", "2026-01-03", 2);
    expect(selectPrintRows(rows, dates).map((selected) =>
      paginatePrintRows(selected, 2).map((page) => page.map((row) => row.key))))
      .toEqual([[["a", "b"], ["c"]], [["a", "b"], ["c"]]]);
  });
});
