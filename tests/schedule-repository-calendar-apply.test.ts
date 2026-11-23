// @vitest-environment node
import { describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository, type CalendarRescheduleProposal } from "../worker/schedule-repository";

const proposal: CalendarRescheduleProposal = { activityId: "activity", disciplineId: null, stageId: null,
  expectedVersion: 3, startDate: "2026-11-09", currentEndDate: "2026-11-10", proposedEndDate: "2026-11-11",
  workingDays: 2, savedCalendarVersion: 1 };
const conflict = { dependencyId: "edge", predecessor: { id: "stage-a", kind: "stage" },
  successor: { id: "stage-b", kind: "stage" }, reason: "finish_to_start",
  before: { predecessorFinish: "2026-11-10", earliestStart: "2026-11-11", successorStart: "2026-11-11" },
  after: { predecessorFinish: "2026-11-11", earliestStart: "2026-11-12", successorStart: "2026-11-11" } };

function fixture() {
  const sql = vi.fn();
  neonMock.mockReturnValue(sql);
  const repository = createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" });
  return { sql, apply: () => repository.applyCalendarReschedule("workspace", "product", "actor", "operation", 2,
    "Synthetic calendar apply check", [proposal]) };
}

describe("calendar apply persistence adapter", () => {
  it("maps accepted and stale batches using the existing one-call transaction contract", async () => {
    const { sql, apply } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "updated", count: 1 } }]);
    await expect(apply()).resolves.toEqual({ status: "updated", count: 1, operationId: "operation" });
    const [query, ...argumentsUsed] = sql.mock.calls[0];
    expect(query.join("?")).toContain("public.apply_calendar_reschedule(");
    expect(argumentsUsed).toContain(JSON.stringify([proposal]));
    sql.mockResolvedValueOnce([{ result: { status: "stale_calendar" } }]);
    await expect(apply()).resolves.toEqual({ status: "stale_calendar" });
    expect(sql).toHaveBeenCalledTimes(2);
  });

  it("validates database conflict details against the Phase 4 rules and fails closed on inconsistent evidence", async () => {
    const { sql, apply } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict } }]);
    await expect(apply()).resolves.toEqual({ status: "dependency_conflict", conflict });
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: { ...conflict,
      after: { ...conflict.after, earliestStart: conflict.before.earliestStart } } } }]);
    await expect(apply()).rejects.toThrow("Unexpected calendar dependency rejection.");
    expect(sql).toHaveBeenCalledTimes(2);
  });

  it("propagates a failed database transaction without retrying or writing a subset", async () => {
    const { sql, apply } = fixture();
    sql.mockRejectedValueOnce(new Error("Synthetic late batch failure"));
    await expect(apply()).rejects.toThrow("Synthetic late batch failure");
    expect(sql).toHaveBeenCalledTimes(1);
  });
});
