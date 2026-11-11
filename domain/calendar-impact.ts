import { calculateWorkingDayEndDate, type SkippedWorkingDate,
  type WorkingCalendarException } from "./working-day-calculation";
import { parseCivilDate } from "./working-calendar";

export interface CalendarImpactCandidate {
  id: string;
  disciplineId: string | null;
  stageId: string | null;
  version: number;
  planningMode: "manual" | "working_days";
  plannedStart: string | null;
  plannedEnd: string | null;
  workingDayDuration: number | null;
  planningCalendarVersion: number | null;
}

export interface ActivityCalendarImpact {
  activityId: string;
  disciplineId: string | null;
  stageId: string | null;
  activityVersion: number;
  workingDays: number;
  savedCalendarVersion: number;
  currentCalendarVersion: number;
  currentStartDate: string;
  currentEndDate: string;
  proposedStartDate: string;
  proposedEndDate: string;
  impact: "date_change" | "version_only";
  skippedDates: SkippedWorkingDate[];
  optionalDaysVerified: boolean;
  unverifiedOptionalYears: number[];
}

/** Returns a proposal only for a working-day plan saved under an older calendar version. */
export function detectCalendarImpact(
  activity: CalendarImpactCandidate,
  currentCalendarVersion: number,
  exceptions: readonly WorkingCalendarException[]
): ActivityCalendarImpact | null {
  if (activity.planningMode === "manual") return null;
  const savedVersion = activity.planningCalendarVersion;
  const duration = activity.workingDayDuration;
  const start = activity.plannedStart;
  const end = activity.plannedEnd;
  if (!Number.isSafeInteger(currentCalendarVersion) || currentCalendarVersion < 0 ||
      !Number.isSafeInteger(savedVersion) || savedVersion === null || savedVersion < 0 ||
      savedVersion > currentCalendarVersion || !Number.isSafeInteger(activity.version) ||
      activity.version < 1 || !Number.isSafeInteger(duration) || duration === null ||
      duration < 1 || duration > 27393 || !start || !end ||
      !parseCivilDate(start) || !parseCivilDate(end) || start > end) {
    throw new RangeError("Invalid saved working-day plan or calendar version.");
  }
  if (savedVersion === currentCalendarVersion) return null;

  const proposed = calculateWorkingDayEndDate(start, duration, exceptions);
  return {
    activityId: activity.id, disciplineId: activity.disciplineId, stageId: activity.stageId,
    activityVersion: activity.version, workingDays: duration,
    savedCalendarVersion: savedVersion, currentCalendarVersion,
    currentStartDate: start, currentEndDate: end,
    proposedStartDate: start, proposedEndDate: proposed.endDate,
    impact: proposed.endDate === end ? "version_only" : "date_change",
    skippedDates: proposed.skippedDates,
    optionalDaysVerified: proposed.optionalDaysVerified,
    unverifiedOptionalYears: proposed.unverifiedOptionalYears
  };
}
