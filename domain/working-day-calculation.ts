import {
  calendarRulesForYear, parseCivilDate,
  type CalendarExceptionDates, type CalendarExceptionKind
} from "./working-calendar";

export type SkippedDateReason =
  | { kind: "weekend"; code: "saturday" | "sunday" }
  | { kind: "national_holiday"; code: string }
  | { kind: "federal_optional"; code: string }
  | {
      kind: CalendarExceptionKind;
      exceptionId: string | null;
      name: string | null;
      municipality: string | null;
      description: string | null;
    };

export interface SkippedWorkingDate {
  date: string;
  reasons: SkippedDateReason[];
}

export interface WorkingDayCalculation {
  startDate: string;
  endDate: string;
  workingDays: number;
  skippedDates: SkippedWorkingDate[];
  optionalDaysVerified: boolean;
  unverifiedOptionalYears: number[];
}

export type WorkingCalendarException = CalendarExceptionDates & {
  id?: string;
  name?: string | null;
  municipality?: string | null;
  description?: string | null;
};

function addCivilDay(date: string): string {
  const parsed = parseCivilDate(date);
  if (!parsed) throw new RangeError("Invalid civil date.");
  const next = new Date(Date.UTC(parsed.year, parsed.month - 1, parsed.day + 1));
  return `${next.getUTCFullYear().toString().padStart(4, "0")}-${(next.getUTCMonth() + 1)
    .toString().padStart(2, "0")}-${next.getUTCDate().toString().padStart(2, "0")}`;
}

function validateExceptions(exceptions: readonly WorkingCalendarException[]): void {
  const supportedKinds = new Set<CalendarExceptionKind>([
    "municipal_holiday", "collective_vacation", "company_shutdown"
  ]);
  for (const exception of exceptions) {
    if (!supportedKinds.has(exception.kind) || !parseCivilDate(exception.startDate) ||
        !parseCivilDate(exception.endDate) || exception.endDate < exception.startDate ||
        (exception.kind === "municipal_holiday" && exception.startDate !== exception.endDate)) {
      throw new RangeError("Invalid working calendar exception.");
    }
  }
}

function reasonsForDate(
  date: string,
  exceptions: readonly WorkingCalendarException[]
): SkippedDateReason[] {
  const parsed = parseCivilDate(date);
  if (!parsed) throw new RangeError("Invalid civil date.");
  const weekday = new Date(Date.UTC(parsed.year, parsed.month - 1, parsed.day)).getUTCDay();
  const reasons: SkippedDateReason[] = [];
  if (weekday === 0 || weekday === 6) {
    reasons.push({ kind: "weekend", code: weekday === 0 ? "sunday" : "saturday" });
  }

  for (const rule of calendarRulesForYear(parsed.year).rules) {
    if (rule.date === date) reasons.push({ kind: rule.kind, code: rule.code });
  }

  for (const exception of exceptions) {
    if (exception.startDate <= date && date <= exception.endDate) {
      reasons.push({
        kind: exception.kind,
        exceptionId: exception.id ?? null,
        name: exception.name ?? null,
        municipality: exception.municipality ?? null,
        description: exception.description ?? null
      });
    }
  }
  return reasons;
}

/** Calculates an inclusive working-day end date without using local time or mutating schedule data. */
export function calculateWorkingDayEndDate(
  startDate: string,
  workingDays: number,
  exceptions: readonly WorkingCalendarException[] = []
): WorkingDayCalculation {
  if (!parseCivilDate(startDate)) throw new RangeError("Invalid start date.");
  if (!Number.isSafeInteger(workingDays) || workingDays < 1) {
    throw new RangeError("Working-day duration must be a positive safe integer.");
  }
  validateExceptions(exceptions);

  let currentDate = startDate;
  let elapsedWorkingDays = 0;
  const skippedDates: SkippedWorkingDate[] = [];
  const years = new Set<number>();

  while (true) {
    const parsed = parseCivilDate(currentDate);
    if (!parsed) throw new RangeError("Calculation exceeds the supported calendar range.");
    years.add(parsed.year);

    const reasons = reasonsForDate(currentDate, exceptions);
    if (reasons.length > 0) {
      skippedDates.push({ date: currentDate, reasons });
    } else {
      elapsedWorkingDays += 1;
      if (elapsedWorkingDays === workingDays) {
        const unverifiedOptionalYears = [...years]
          .filter((year) => !calendarRulesForYear(year).optionalDaysVerified)
          .sort((left, right) => left - right);
        return {
          startDate,
          endDate: currentDate,
          workingDays,
          skippedDates,
          optionalDaysVerified: unverifiedOptionalYears.length === 0,
          unverifiedOptionalYears
        };
      }
    }

    if (currentDate === "2100-12-31") {
      throw new RangeError("Calculation exceeds the supported calendar range.");
    }
    currentDate = addCivilDay(currentDate);
  }
}
