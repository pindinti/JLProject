// @vitest-environment node
import { describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository } from "../worker/schedule-repository";

function fixture() {
  const sql = vi.fn();
  neonMock.mockReturnValue(sql);
  const repository = createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" });
  return { sql, reverse: () => repository.reverseCalendarReschedule("workspace", "product", "actor", "original", "reversal",
    "Synthetic calendar reversal check") };
}

describe("calendar reversal persistence adapter", () => {
  it("preserves the reversal identity, the original reference, and the existing stale result", async () => {
    const { sql, reverse } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "reversed", count: 2 } }]);
    await expect(reverse()).resolves.toEqual({ status: "reversed", count: 2, originalOperationId: "original", operationId: "reversal" });
    const [query, ...args] = sql.mock.calls[0];
    expect(query.join("?")).toContain("public.reverse_calendar_reschedule(");
    expect(query.join("?")).toContain("jlproject.schedule_reversal_of");
    expect(args).toEqual(expect.arrayContaining(["original", "reversal", "Synthetic calendar reversal check"]));
    sql.mockResolvedValueOnce([{ result: { status: "stale", activityId: "child" } }]);
    await expect(reverse()).resolves.toEqual({ status: "stale", activityId: "child" });
  });

  it("verifies a structured reversal conflict and rejects evidence of an improving batch", async () => {
    const { sql, reverse } = fixture();
    const conflict = { dependencyId: "stage-edge", reason: "finish_to_start",
      predecessor: { id: "stage-a", kind: "stage" }, successor: { id: "stage-b", kind: "stage" },
      before: { predecessorFinish: "2026-11-10", earliestStart: "2026-11-11", successorStart: "2026-11-11" },
      after: { predecessorFinish: "2026-11-10", earliestStart: "2026-11-11", successorStart: "2026-11-09" } };
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict } }]);
    await expect(reverse()).resolves.toEqual({ status: "dependency_conflict", conflict });
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: { ...conflict,
      before: { ...conflict.before, successorStart: "2026-11-06" } } } }]);
    await expect(reverse()).rejects.toThrow("Unexpected calendar dependency rejection.");
    expect(sql).toHaveBeenCalledTimes(2);
  });

  it("propagates an aborted transaction without issuing a second statement", async () => {
    const { sql, reverse } = fixture();
    sql.mockRejectedValueOnce(new Error("Synthetic late reversal failure"));
    await expect(reverse()).rejects.toThrow("Synthetic late reversal failure");
    expect(sql).toHaveBeenCalledTimes(1);
  });
});
