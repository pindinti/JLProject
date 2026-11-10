export type CalendarRuleKind = "national_holiday" | "federal_optional";
export type CalendarExceptionKind = "municipal_holiday" | "collective_vacation" | "company_shutdown";

export interface CalendarRule {
  code: string;
  date: string;
  kind: CalendarRuleKind;
}

export interface CalendarExceptionDates {
  kind: CalendarExceptionKind;
  startDate: string;
  endDate: string;
}

export interface CalendarException extends CalendarExceptionDates {
  id: string;
  name: string | null;
  municipality: string | null;
  description: string | null;
  version: number;
}

export interface CalendarExceptionInput extends CalendarExceptionDates {
  name: string | null;
  municipality: string | null;
  description: string | null;
}

export interface CalendarHistoryEntry {
  operationId: string;
  version: number;
  action: "created" | "updated" | "removed";
  actorName: string | null;
  changedAt: string;
  before: CalendarException | null;
  after: CalendarException;
}

const fixedNationalRules = [
  ["new_year", "01-01"],
  ["tiradentes", "04-21"],
  ["labor_day", "05-01"],
  ["independence_day", "09-07"],
  ["our_lady_of_aparecida", "10-12"],
  ["all_souls_day", "11-02"],
  ["republic_day", "11-15"],
  ["black_consciousness_day", "11-20"],
  ["christmas", "12-25"]
] as const;

// Federal optional days are published annually. This catalog reflects the 2026
// MGI ordinance and its October 2026 amendment; later years need reviewed acts.
const federalOptional2026 = [
  ["carnival_monday", "2026-02-16"],
  ["carnival_tuesday", "2026-02-17"],
  ["ash_wednesday", "2026-02-18"],
  ["tiradentes_bridge", "2026-04-20"],
  ["corpus_christi", "2026-06-04"],
  ["corpus_christi_bridge", "2026-06-05"],
  ["federal_public_service_day", "2026-10-30"],
  ["christmas_eve", "2026-12-24"],
  ["new_years_eve", "2026-12-31"]
] as const;

function isoDate(year: number, month: number, day: number): string {
  return `${year.toString().padStart(4, "0")}-${month.toString().padStart(2, "0")}-${day.toString().padStart(2, "0")}`;
}

export function parseCivilDate(value: string): { year: number; month: number; day: number } | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (year < 2026 || year > 2100 || month < 1 || month > 12) return null;
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day >= 1 && day <= lastDay ? { year, month, day } : null;
}

export function easterSunday(year: number): string {
  if (!Number.isInteger(year) || year < 2026 || year > 2100) throw new RangeError("Unsupported calendar year.");
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return isoDate(year, month, day);
}

function shiftCivilDate(date: string, days: number): string {
  const parsed = parseCivilDate(date);
  if (!parsed) throw new RangeError("Invalid civil date.");
  const value = new Date(Date.UTC(parsed.year, parsed.month - 1, parsed.day + days));
  return isoDate(value.getUTCFullYear(), value.getUTCMonth() + 1, value.getUTCDate());
}

export function calendarRulesForYear(year: number): { rules: CalendarRule[]; optionalDaysVerified: boolean } {
  if (!Number.isInteger(year) || year < 2026 || year > 2100) throw new RangeError("Unsupported calendar year.");
  const rules: CalendarRule[] = fixedNationalRules.map(([code, monthDay]) => ({
    code, date: `${year}-${monthDay}`, kind: "national_holiday"
  }));
  rules.push({ code: "good_friday", date: shiftCivilDate(easterSunday(year), -2), kind: "national_holiday" });
  if (year === 2026) {
    rules.push(...federalOptional2026.map(([code, date]) => ({ code, date, kind: "federal_optional" as const })));
  }
  return { rules: rules.sort((left, right) => left.date.localeCompare(right.date)), optionalDaysVerified: year === 2026 };
}

export function isNonWorkingDate(date: string, exceptions: readonly CalendarExceptionDates[]): boolean {
  const parsed = parseCivilDate(date);
  if (!parsed) throw new RangeError("Invalid civil date.");
  const weekday = new Date(Date.UTC(parsed.year, parsed.month - 1, parsed.day)).getUTCDay();
  if (weekday === 0 || weekday === 6) return true;
  if (calendarRulesForYear(parsed.year).rules.some((rule) => rule.date === date)) return true;
  return exceptions.some((exception) => exception.startDate <= date && date <= exception.endDate);
}
