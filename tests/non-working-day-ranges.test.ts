import { describe, expect, it } from "vitest";
import { dayNumber, civilFromDay } from "../domain/schedule-workspace";
import { nonWorkingDayRanges } from "../domain/non-working-day-ranges";
import type { CalendarExceptionDates } from "../domain/working-calendar";

describe("non-working Gantt day ranges", () => {
  it("groups weekends, applicable holidays, and workspace closures by exact civil date", () => {
    const exceptions: CalendarExceptionDates[] = [
      { kind: "municipal_holiday", startDate: "2026-11-09", endDate: "2026-11-09" },
      { kind: "company_shutdown", startDate: "2027-02-08", endDate: "2027-02-10" }
    ];
    const ranges = nonWorkingDayRanges(dayNumber("2026-11-01"), dayNumber("2027-02-15"), exceptions);
    const dates = ranges.flatMap(({ startDay, dayCount }) =>
      Array.from({ length: dayCount }, (_, offset) => civilFromDay(startDay + offset)));

    expect(ranges.map(({ startDay, dayCount }) => [civilFromDay(startDay), dayCount]))
      .toContainEqual(["2026-11-07", 3]);
    expect(ranges.map(({ startDay, dayCount }) => [civilFromDay(startDay), dayCount]))
      .toContainEqual(["2026-11-01", 2]); // Sunday plus the Monday national holiday.
    expect(dates).toContain("2026-11-20"); // National holiday.
    expect(dates).toContain("2026-12-24"); // Verified 2026 nationwide optional day.
    expect(dates).toContain("2027-02-08");
    expect(dates).toContain("2027-02-09");
    expect(dates).toContain("2027-02-10");
    expect(dates).not.toContain("2027-02-15"); // Unverified optional days are not inferred.
    expect(ranges.find(({ startDay }) => civilFromDay(startDay) === "2026-12-24")?.dayCount).toBe(4);
  });

  it("rejects invalid timeline ranges", () => {
    expect(() => nonWorkingDayRanges(10, 9, [])).toThrow(RangeError);
    expect(() => nonWorkingDayRanges(1.5, 2, [])).toThrow(RangeError);
  });
});
