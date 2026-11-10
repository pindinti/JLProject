import { describe, expect, it } from "vitest";
import { detectCalendarImpact, type CalendarImpactCandidate } from "../domain/calendar-impact";

const workingPlan: CalendarImpactCandidate = {
  id: "activity-1", disciplineId: "discipline-1", stageId: "stage-1", version: 3,
  planningMode: "working_days", plannedStart: "2026-11-09", plannedEnd: "2026-11-10",
  workingDayDuration: 2, planningCalendarVersion: 1
};

describe("working-plan calendar impact", () => {
  it("proposes a later end and explains skipped dates when a closure affects the plan", () => {
    const impact = detectCalendarImpact(workingPlan, 2, [{
      kind: "company_shutdown", startDate: "2026-11-10", endDate: "2026-11-10",
      description: "Synthetic closure"
    }]);
    expect(impact).toMatchObject({
      activityId: "activity-1", activityVersion: 3, workingDays: 2,
      savedCalendarVersion: 1, currentCalendarVersion: 2,
      currentStartDate: "2026-11-09", currentEndDate: "2026-11-10",
      proposedStartDate: "2026-11-09", proposedEndDate: "2026-11-11",
      impact: "date_change", optionalDaysVerified: true
    });
    expect(impact?.skippedDates).toEqual([{
      date: "2026-11-10", reasons: [{ kind: "company_shutdown", exceptionId: null,
        name: null, municipality: null, description: "Synthetic closure" }]
    }]);
    expect(workingPlan.plannedEnd).toBe("2026-11-10");
  });

  it("distinguishes a version-only change and warns about unverified optional holidays", () => {
    expect(detectCalendarImpact(workingPlan, 2, [])).toMatchObject({
      currentEndDate: "2026-11-10", proposedEndDate: "2026-11-10", impact: "version_only"
    });
    const future = detectCalendarImpact({ ...workingPlan,
      plannedStart: "2026-12-30", plannedEnd: "2027-01-04" }, 2, []);
    expect(future).toMatchObject({
      impact: "version_only", optionalDaysVerified: false, unverifiedOptionalYears: [2027]
    });
    expect(future?.skippedDates.map((item) => item.date)).toEqual([
      "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"
    ]);
  });

  it("omits current-version and manual plans without inventing durations", () => {
    expect(detectCalendarImpact(workingPlan, 1, [])).toBeNull();
    expect(detectCalendarImpact({ ...workingPlan, planningMode: "manual",
      workingDayDuration: null, planningCalendarVersion: null }, 2, [])).toBeNull();
  });

  it("rejects invalid saved plans and a calendar older than the saved version", () => {
    expect(() => detectCalendarImpact({ ...workingPlan, plannedStart: "2026-02-30" }, 2, []))
      .toThrow(RangeError);
    expect(() => detectCalendarImpact({ ...workingPlan, workingDayDuration: 0 }, 2, []))
      .toThrow(RangeError);
    expect(() => detectCalendarImpact(workingPlan, 0, [])).toThrow(RangeError);
  });
});
