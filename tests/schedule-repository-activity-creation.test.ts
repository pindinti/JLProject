// @vitest-environment node
import { describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository } from "../worker/schedule-repository";

const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const disciplineId = "d4444444-4444-4444-8444-444444444444";
const stageId = "a5555555-5555-4555-8555-555555555555";
const actorId = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const operationId = "c5555555-5555-4555-8555-555555555555";
const conflict = {
  dependencyId: "b5555555-5555-4555-8555-555555555555",
  reason: "finish_to_start",
  predecessor: { id: "b6666666-6666-4666-8666-666666666666", kind: "stage" },
  successor: { id: stageId, kind: "stage" },
  before: { predecessorFinish: "2026-11-09", successorStart: "2026-11-10", earliestStart: "2026-11-10" },
  after: { predecessorFinish: "2026-11-10", successorStart: "2026-11-10", earliestStart: "2026-11-11" }
};

function fixture() {
  const sql = vi.fn();
  neonMock.mockReturnValue(sql);
  return { sql, repository: createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" }) };
}

describe("activity creation dependency persistence adapter", () => {
  it("maps a database-trigger conflict into verified stage dependency details without retrying", async () => {
    const { sql, repository } = fixture();
    const error = Object.assign(new Error("Activity creation would worsen a schedule dependency."), {
      code: "P4D01", detail: JSON.stringify({ status: "dependency_conflict", conflict })
    });
    sql.mockRejectedValueOnce(error);

    await expect(repository.createActivity(workspaceId, productId, disciplineId, stageId, actorId, {
      name: "Synthetic child", activityType: null, plannedStart: "2026-11-10", plannedEnd: "2026-11-12",
      displayOrder: 1, notes: null
    }, "Synthetic child creation", operationId)).resolves.toEqual({ status: "dependency_conflict", conflict });

    expect(sql).toHaveBeenCalledTimes(1);
    const query = (sql.mock.calls[0]?.[0] as TemplateStringsArray).join("?");
    expect(query).toContain("locked_workspace AS MATERIALIZED");
    expect(query).toContain("locked_product AS MATERIALIZED");
    expect(query).toContain("INSERT INTO public.stage_activities");
  });

  it("maps the working-day creation routine's structured conflict and skips the activity read", async () => {
    const { sql, repository } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict } }]);

    await expect(repository.createWorkingActivity(workspaceId, productId, disciplineId, stageId, actorId, {
      name: "Synthetic working child", activityType: null,
      plannedStart: "2026-11-10", plannedEnd: "2026-11-12", displayOrder: 1,
      notes: null, workingDays: 3, calendarVersion: 2
    }, "Synthetic working child creation", operationId)).resolves.toEqual({
      status: "dependency_conflict", conflict
    });

    expect(sql).toHaveBeenCalledTimes(1);
    expect((sql.mock.calls[0]?.[0] as TemplateStringsArray).join("?")).toContain("create_activity_with_working_plan");
  });

  it("rejects malformed, non-worsening, or non-stage trigger evidence", async () => {
    const { sql, repository } = fixture();
    sql.mockRejectedValueOnce(Object.assign(new Error("bad detail"), { code: "P4D01", detail: "{}" }));
    await expect(repository.createActivity(workspaceId, productId, disciplineId, stageId, actorId, {
      name: "Synthetic child", activityType: null, plannedStart: "2026-11-10", plannedEnd: "2026-11-12",
      displayOrder: 1, notes: null
    }, null, operationId)).rejects.toThrow("Activity creation returned malformed dependency conflict details.");

    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: {
      ...conflict, before: { ...conflict.before, successorStart: "2026-11-06" }
    } } }]);
    await expect(repository.createWorkingActivity(workspaceId, productId, disciplineId, stageId, actorId, {
      name: "Synthetic working child", activityType: null, plannedStart: "2026-11-10", plannedEnd: "2026-11-12",
      displayOrder: 1, notes: null, workingDays: 3, calendarVersion: 2
    }, "Synthetic working child creation", operationId)).rejects.toThrow("Unexpected calendar dependency rejection.");
    expect(sql).toHaveBeenCalledTimes(2);
  });
});
