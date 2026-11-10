import { describe, expect, it } from "vitest";
import { calculateWorkingDayEndDate } from "../domain/working-day-calculation";

describe("inclusive working-day end-date calculation", () => {
  it("counts a working start date as day one", () => {
    const result = calculateWorkingDayEndDate("2026-11-09", 2);

    expect(result.endDate).toBe("2026-11-10");
    expect(result.skippedDates).toEqual([]);
    expect(result.optionalDaysVerified).toBe(true);
    expect(result.unverifiedOptionalYears).toEqual([]);
  });

  it("starts counting on Monday when the start falls on a weekend", () => {
    const result = calculateWorkingDayEndDate("2026-11-07", 1);

    expect(result.endDate).toBe("2026-11-09");
    expect(result.skippedDates).toEqual([
      { date: "2026-11-07", reasons: [{ kind: "weekend", code: "saturday" }] },
      { date: "2026-11-08", reasons: [{ kind: "weekend", code: "sunday" }] }
    ]);
  });

  it("skips consecutive weekend and officially defined optional days once each", () => {
    const result = calculateWorkingDayEndDate("2026-02-13", 2);

    expect(result.endDate).toBe("2026-02-19");
    expect(result.skippedDates.map(({ date }) => date)).toEqual([
      "2026-02-14", "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18"
    ]);
    expect(result.skippedDates.slice(2).flatMap(({ reasons }) =>
      reasons.filter((reason) => reason.kind === "federal_optional").map((reason) => reason.code)))
      .toEqual(["carnival_monday", "carnival_tuesday", "ash_wednesday"]);
  });

  it("reports overlapping national, weekend, and configured closure reasons", () => {
    const result = calculateWorkingDayEndDate("2026-11-19", 2, [{
      id: "closure-1",
      kind: "company_shutdown",
      description: "Synthetic closure",
      startDate: "2026-11-20",
      endDate: "2026-11-23"
    }]);

    expect(result.endDate).toBe("2026-11-24");
    expect(result.skippedDates[0]).toEqual({
      date: "2026-11-20",
      reasons: [
        { kind: "national_holiday", code: "black_consciousness_day" },
        {
          kind: "company_shutdown", exceptionId: "closure-1", name: null,
          municipality: null, description: "Synthetic closure"
        }
      ]
    });
    expect(result.skippedDates[1]?.reasons.map(({ kind }) => kind)).toEqual(["weekend", "company_shutdown"]);
  });

  it("handles leap days and year boundaries using ISO civil dates", () => {
    expect(calculateWorkingDayEndDate("2028-02-28", 2).endDate).toBe("2028-02-29");

    const boundary = calculateWorkingDayEndDate("2026-12-30", 2);
    expect(boundary.endDate).toBe("2027-01-04");
    expect(boundary.skippedDates.map(({ date }) => date)).toEqual([
      "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"
    ]);
    expect(boundary.optionalDaysVerified).toBe(false);
    expect(boundary.unverifiedOptionalYears).toEqual([2027]);
  });

  it("rejects invalid civil dates, invalid durations, invalid exceptions, and out-of-range results", () => {
    expect(() => calculateWorkingDayEndDate("2026-02-29", 1)).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2026-01-01", 0)).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2026-01-01", -1)).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2026-01-01", 1.5)).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2026-01-01", Number.MAX_SAFE_INTEGER)).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2026-01-01", 1, [{
      kind: "company_shutdown", startDate: "2026-03-02", endDate: "2026-03-01"
    }])).toThrow(RangeError);
    expect(() => calculateWorkingDayEndDate("2100-12-31", 2)).toThrow(RangeError);
  });
});
