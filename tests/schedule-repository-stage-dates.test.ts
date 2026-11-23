// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository } from "../worker/schedule-repository";

const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const disciplineId = "d4444444-4444-4444-8444-444444444444";
const stageId = "a5555555-5555-4555-8555-555555555555";
const actorId = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const operationId = "c5555555-5555-4555-8555-555555555555";

function stageRow(plannedStart: string | null, plannedEnd: string | null) {
  return { id: stageId, disciplineId, code: "EC", color: "#445566", displayName: "Synthetic stage",
    displayOrder: 0, version: 2, plannedStart, plannedEnd,
    derivedStart: "2026-11-01", derivedEnd: "2026-11-12" };
}

describe("stage date persistence adapter", () => {
  let sql: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    sql = vi.fn(async () => []);
    neonMock.mockReset();
    neonMock.mockReturnValue(sql);
  });

  it("creates dated stages through the atomic audited database operation", async () => {
    sql.mockResolvedValueOnce([{ result: stageId }]).mockResolvedValueOnce([stageRow("2026-11-03", null)]);
    const result = await createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .createStageWithDates(workspaceId, productId, disciplineId, actorId,
        { code: "EC", color: "#445566", displayName: "Synthetic stage", displayOrder: 0 },
        { plannedStart: "2026-11-03", plannedEnd: null, reason: "Synthetic stage creation",
          operationId });

    expect(result).toMatchObject({ status: "ok", operationId, value: {
      plannedStart: "2026-11-03", plannedEnd: null, derivedStart: "2026-11-01",
      derivedEnd: "2026-11-12", version: 2
    } });
    const query = sql.mock.calls[0]?.[0] as TemplateStringsArray;
    expect(query.join("?")).toContain("create_discipline_stage_with_dates");
    expect(query.join("?")).not.toContain("INSERT INTO public.stage_date_changes");
    expect(sql.mock.calls[0]?.slice(1)).toContain(operationId);
    expect(sql.mock.calls[0]?.slice(1)).toContain("Synthetic stage creation");
  });

  it("preserves partial values separately from derived values and passes the optimistic version", async () => {
    sql.mockResolvedValueOnce([{ result: { status: "updated" } }])
      .mockResolvedValueOnce([stageRow(null, "2026-11-10")]);
    const result = await createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .changeStageDates(workspaceId, productId, disciplineId, stageId, actorId,
        { plannedStart: null, plannedEnd: "2026-11-10", reason: "Synthetic partial correction" },
        1, operationId);

    expect(result).toMatchObject({ status: "updated", operationId, stage: {
      plannedStart: null, plannedEnd: "2026-11-10", derivedStart: "2026-11-01", derivedEnd: "2026-11-12"
    } });
    const query = sql.mock.calls[0]?.[0] as TemplateStringsArray;
    expect(query.join("?")).toContain("change_discipline_stage_dates");
    expect(sql.mock.calls[0]?.slice(1)).toContain("Synthetic partial correction");
    expect(sql.mock.calls[0]?.slice(1)).toContain(1);
    expect(sql.mock.calls[0]?.slice(1)).toContain(operationId);
  });

  it("maps a stale database version token without reading a stage or inventing a retry", async () => {
    sql.mockResolvedValueOnce([{ result: { status: "stale" } }]);
    await expect(createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .changeStageDates(workspaceId, productId, disciplineId, stageId, actorId,
        { plannedStart: "2026-11-01", plannedEnd: null, reason: "Synthetic stale correction" },
        1, operationId)).resolves.toEqual({ status: "stale" });
    expect(sql).toHaveBeenCalledTimes(1);
  });

  it("returns verified dependency evidence without reading the stage or retrying a blocked write", async () => {
    const rejection = { status: "dependency_conflict", dependencyId: operationId, direction: "inbound", reason: "missing_boundary",
      before: { predecessorFinish: "2026-11-03", successorStart: "2026-11-05", earliestStart: "2026-11-04" },
      after: { predecessorFinish: "2026-11-03", successorStart: null, earliestStart: "2026-11-04" } };
    sql.mockResolvedValueOnce([{ result: rejection }]);
    const repository = createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" });
    const edit = { plannedStart: null, plannedEnd: "2026-11-10", reason: "Synthetic partial correction" };
    await expect(repository.changeStageDates(workspaceId, productId, disciplineId, stageId, actorId,
      edit, 1, operationId)).resolves.toEqual(rejection);
    expect(sql).toHaveBeenCalledTimes(1);
    sql.mockResolvedValueOnce([{ result: { ...rejection, reason: "finish_to_start" } }]);
    await expect(repository.changeStageDates(workspaceId, productId, disciplineId, stageId, actorId,
      edit, 1, operationId)).rejects.toThrow("Unexpected dependency date rejection.");
    expect(sql).toHaveBeenCalledTimes(2);
  });
});
