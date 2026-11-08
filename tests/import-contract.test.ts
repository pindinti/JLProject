import { describe, expect, it } from "vitest";
import { validateImportSubmission } from "../domain/import-contract";
import { syntheticImportSubmission } from "./fixtures/synthetic-import";

describe("initial import contract", () => {
  it("accepts 41 ordered activities, five targets, and confirmed date-only mappings", () => {
    const submission = syntheticImportSubmission();
    expect(validateImportSubmission(submission)).toBe(true);
    expect(submission.targets[0]).toMatchObject({ targetDate: "2027-01-03", operationalDate: "2027-01-01" });
    expect(new Date(`${submission.targets[0].targetDate}T00:00:00.000Z`).getUTCDay()).toBe(0);
    expect(submission.disciplines.flatMap((discipline) => discipline.stages.flatMap((stage) =>
      stage.activities.map((activity) => activity.sourceId)))).toHaveLength(41);
  });

  it("rejects predecessor claims, duplicate IDs, missing rows, and changed dates", () => {
    const submission = syntheticImportSubmission();
    expect(validateImportSubmission({ ...submission, predecessor: "T001" })).toBe(false);
    submission.disciplines[0].stages[0].activities[1].sourceId = "T001";
    expect(validateImportSubmission(submission)).toBe(false);
    const missing = syntheticImportSubmission();
    missing.disciplines[0].stages[0].activities.pop();
    expect(validateImportSubmission(missing)).toBe(false);
    const range = syntheticImportSubmission();
    range.disciplines[0].stages[0].activities[0].plannedEnd = "2026-10-31";
    expect(validateImportSubmission(range)).toBe(false);
  });

  it("rejects unconfirmed, ambiguous, or conflicting target mappings", () => {
    const submission = syntheticImportSubmission();
    submission.targets[2].matchMethod = "exact";
    expect(validateImportSubmission(submission)).toBe(false);
    const ambiguous = syntheticImportSubmission();
    ambiguous.targets[3].targetDate = ambiguous.targets[2].targetDate;
    expect(validateImportSubmission(ambiguous)).toBe(false);
    const conflicting = syntheticImportSubmission();
    conflicting.targets[2].targetDate = "2027-12-01";
    expect(validateImportSubmission(conflicting)).toBe(false);
    const wrong = syntheticImportSubmission();
    wrong.targets[2].matchedSourceId = "T001";
    expect(validateImportSubmission(wrong)).toBe(false);
  });

  it("rejects malformed ordering and inconsistent shared stage colors", () => {
    const order = syntheticImportSubmission();
    order.disciplines[0].stages[0].activities[0].displayOrder = 0;
    expect(validateImportSubmission(order)).toBe(false);
    const color = syntheticImportSubmission();
    color.disciplines[1].stages[0].color = "#000000";
    expect(validateImportSubmission(color)).toBe(false);
  });
});
