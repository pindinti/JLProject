import { civilFromDay } from "./schedule-workspace";
import { isNonWorkingDate, parseCivilDate, type CalendarExceptionDates } from "./working-calendar";

export interface NonWorkingDayRange {
  startDay: number;
  dayCount: number;
}

/** Groups adjacent non-working civil dates into renderable timeline bands. */
export function nonWorkingDayRanges(startDay: number, endDay: number,
  exceptions: readonly CalendarExceptionDates[]): NonWorkingDayRange[] {
  if (!Number.isSafeInteger(startDay) || !Number.isSafeInteger(endDay) || endDay < startDay)
    throw new RangeError("Invalid timeline day range.");

  const ranges: NonWorkingDayRange[] = [];
  let rangeStart: number | null = null;
  for (let day = startDay; day <= endDay + 1; day++) {
    const date = day <= endDay ? civilFromDay(day) : "";
    const parsed = date ? parseCivilDate(date) : null;
    const weekday = date ? new Date(day * 86_400_000).getUTCDay() : -1;
    const nonWorking = !!date && (weekday === 0 || weekday === 6 ||
      (!!parsed && isNonWorkingDate(date, exceptions)));
    if (nonWorking && rangeStart === null) rangeStart = day;
    if (!nonWorking && rangeStart !== null) {
      ranges.push({ startDay: rangeStart, dayCount: day - rangeStart });
      rangeStart = null;
    }
  }
  return ranges;
}
