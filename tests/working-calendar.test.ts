import { describe, expect, it } from "vitest";
import { calendarRulesForYear, easterSunday, isNonWorkingDate, parseCivilDate } from "../domain/working-calendar";

describe("Brazilian working calendar rules", () => {
  it("matches the amended 2026 federal calendar and treats partial optional days as whole days", () => {
    const { rules, optionalDaysVerified } = calendarRulesForYear(2026);
    expect(optionalDaysVerified).toBe(true);
    expect(rules.filter((rule) => rule.kind === "national_holiday")).toHaveLength(10);
    expect(rules.filter((rule) => rule.kind === "federal_optional")).toHaveLength(9);
    expect(rules).toContainEqual({ code: "good_friday", date: "2026-04-03", kind: "national_holiday" });
    expect(rules).toContainEqual({ code: "federal_public_service_day", date: "2026-10-30", kind: "federal_optional" });
    expect(rules.some((rule) => rule.date === "2026-10-28")).toBe(false);
    expect(rules).toContainEqual({ code: "ash_wednesday", date: "2026-02-18", kind: "federal_optional" });
    expect(rules).toContainEqual({ code: "christmas_eve", date: "2026-12-24", kind: "federal_optional" });
  });

  it("calculates recurring national dates without inventing unpublished optional days", () => {
    expect(easterSunday(2026)).toBe("2026-04-05");
    expect(easterSunday(2027)).toBe("2027-03-28");
    const future = calendarRulesForYear(2027);
    expect(future.optionalDaysVerified).toBe(false);
    expect(future.rules).toHaveLength(10);
    expect(future.rules).toContainEqual({ code: "good_friday", date: "2027-03-26", kind: "national_holiday" });
  });

  it("classifies weekends and inclusive workspace exceptions as non-working", () => {
    const exceptions = [{ kind: "company_shutdown" as const, startDate: "2026-11-09", endDate: "2026-11-11" }];
    expect(isNonWorkingDate("2026-11-07", [])).toBe(true);
    expect(isNonWorkingDate("2026-11-08", [])).toBe(true);
    expect(isNonWorkingDate("2026-11-09", exceptions)).toBe(true);
    expect(isNonWorkingDate("2026-11-11", exceptions)).toBe(true);
    expect(isNonWorkingDate("2026-11-12", exceptions)).toBe(false);
    expect(isNonWorkingDate("2026-11-20", [])).toBe(true);
  });

  it("rejects impossible civil dates and unsupported years", () => {
    expect(parseCivilDate("2026-02-29")).toBeNull();
    expect(parseCivilDate("2028-02-29")).toEqual({ year: 2028, month: 2, day: 29 });
    expect(() => calendarRulesForYear(2101)).toThrow(RangeError);
    expect(() => calendarRulesForYear(2025)).toThrow(RangeError);
  });
});
