// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository } from "../worker/schedule-repository";

const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const actorId = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const activityId = "a6666666-6666-4666-8666-666666666666";
const targetId = "f7777777-7777-4777-8777-777777777777";
const occurredAt = "2026-11-10T12:00:00.000000Z";

function event(id: string, time: string, eventType: string) {
  return {
    id, occurredAt: time, actorId, actorName: null, eventType,
    item: { kind: "activity", id: activityId, name: "Synthetic activity",
      hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
    justification: "Synthetic audit reason",
    before: { plannedStart: "2026-11-01", plannedEnd: "2026-11-03" },
    after: { plannedStart: "2026-11-01", plannedEnd: "2026-11-04" }, affectedItems: []
  };
}

describe("product change history repository", () => {
  let sql: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    sql = vi.fn(async () => []);
    neonMock.mockReset();
    neonMock.mockReturnValue(sql);
  });

  it("maps audit details and enriches only the returned page's actor identities", async () => {
    const newest = event(`activity-date:${activityId}`, occurredAt, "activity_dates_changed");
    const oldest = event(`target-date:${targetId}`, "2026-11-09T12:00:00.000000Z", "business_target_date_changed");
    sql.mockResolvedValueOnce([{ result: { status: "ok", events: [newest, oldest],
      nextCursor: { occurredAt: oldest.occurredAt, eventId: oldest.id } } }])
      .mockResolvedValueOnce([{ id: actorId, name: "Synthetic actor" }]);

    const result = await createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .listProductChangeHistory(workspaceId, productId, actorId, 2, null);

    expect(result).toMatchObject({ status: "ok", events: [
      { id: newest.id, occurredAt, actorId, actorName: "Synthetic actor", eventType: "activity_dates_changed",
        item: { name: "Synthetic activity", hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage" } },
        justification: "Synthetic audit reason", before: { plannedEnd: "2026-11-03" },
        after: { plannedEnd: "2026-11-04" } },
      { id: oldest.id, eventType: "business_target_date_changed" }
    ], nextCursor: { occurredAt: oldest.occurredAt, eventId: oldest.id } });
    expect(sql).toHaveBeenCalledTimes(2);
    const historySql = sql.mock.calls[0]?.[0] as TemplateStringsArray;
    expect(historySql.join("?")).toContain("list_product_change_history");
    const actorSql = sql.mock.calls[1]?.[0] as TemplateStringsArray;
    expect(actorSql.join("?")).toContain('neon_auth."user"');
    expect(actorSql.join("?")).toContain("jsonb_array_elements_text");
    expect(actorSql.join("?")).not.toContain("activity_date_changes");
  });

  it("maps one hierarchy movement audit row with its parent/position details and cursor", async () => {
    const movementId = `hierarchy-movement:${activityId}`;
    const movement = { id: movementId, occurredAt, actorId, actorName: null, eventType: "hierarchy_moved",
      item: { kind: "activity", id: activityId, name: "Synthetic activity",
        hierarchy: { scope: "product_root" } }, justification: null,
      before: { parent: { scope: "stage", discipline: "Synthetic discipline", stage: "Synthetic stage" }, position: 3 },
      after: { parent: { scope: "product_root", discipline: null, stage: null }, position: 1 }, affectedItems: [] };
    sql.mockResolvedValueOnce([{ result: { status: "ok", events: [movement],
      nextCursor: { occurredAt, eventId: movementId } } }])
      .mockResolvedValueOnce([{ id: actorId, name: "Synthetic mover" }]);

    const result = await createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .listProductChangeHistory(workspaceId, productId, actorId, 1, null);

    expect(result).toMatchObject({ status: "ok", events: [{ id: movementId, occurredAt, actorId,
      actorName: "Synthetic mover", eventType: "hierarchy_moved",
      item: { kind: "activity", id: activityId, name: "Synthetic activity",
        hierarchy: { scope: "product_root" } },
      before: { parent: { scope: "stage", discipline: "Synthetic discipline", stage: "Synthetic stage" }, position: 3 },
      after: { parent: { scope: "product_root" }, position: 1 } }],
      nextCursor: { occurredAt, eventId: movementId } });
    const query = sql.mock.calls[0]?.[0] as TemplateStringsArray;
    expect(query.join("?")).toContain("list_product_change_history");
    expect(sql).toHaveBeenCalledTimes(2);
  });

  it("rejects non-newest-first results instead of returning an unstable page", async () => {
    const newest = event(`activity-date:${activityId}`, occurredAt, "activity_dates_changed");
    const oldest = event(`target-date:${targetId}`, "2026-11-09T12:00:00.000000Z", "business_target_date_changed");
    sql.mockResolvedValueOnce([{ result: { status: "ok", events: [oldest, newest], nextCursor: null } }])
      .mockResolvedValueOnce([{ id: actorId, name: "Synthetic actor" }]);
    await expect(createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .listProductChangeHistory(workspaceId, productId, actorId, 2, null))
      .rejects.toThrow("Product change history is not ordered newest first.");
  });

  it("returns an empty page without an actor lookup", async () => {
    sql.mockResolvedValueOnce([{ result: { status: "ok", events: [], nextCursor: null } }]);
    await expect(createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .listProductChangeHistory(workspaceId, productId, actorId, 25, null))
      .resolves.toEqual({ status: "ok", events: [], nextCursor: null });
    expect(sql).toHaveBeenCalledTimes(1);
  });

  it("preserves exact stage-event IDs and their shared operation group", async () => {
    const operationId = "b5555555-5555-4555-8555-555555555555";
    const firstStageId = "a5555555-5555-4555-8555-555555555555";
    const secondStageId = "c5555555-5555-4555-8555-555555555555";
    const firstStageEvent = { ...event(`stage-date:${firstStageId}`,
      occurredAt, "stage_dates_changed"), item: { kind: "stage", id: "a5555555-5555-4555-8555-555555555555",
      name: "Synthetic stage A", operationId,
      hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage A" } },
      before: { plannedStart: null, plannedEnd: null },
      after: { plannedStart: "2026-11-01", plannedEnd: null } };
    const secondStageEvent = { ...event(`stage-date:${secondStageId}`,
      "2026-11-10T11:59:00.000000Z", "stage_dates_changed"), item: { kind: "stage", id: secondStageId,
      name: "Synthetic stage B", operationId,
      hierarchy: { discipline: "Synthetic discipline", stage: "Synthetic stage B" } },
      before: { plannedStart: null, plannedEnd: null },
      after: { plannedStart: null, plannedEnd: "2026-11-05" } };
    sql.mockResolvedValueOnce([{ result: { status: "ok", events: [firstStageEvent, secondStageEvent],
      nextCursor: { occurredAt: secondStageEvent.occurredAt, eventId: secondStageEvent.id } } }])
      .mockResolvedValueOnce([{ id: actorId, name: "Synthetic actor" }]);

    const result = await createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" })
      .listProductChangeHistory(workspaceId, productId, actorId, 2, null);

    expect(result).toMatchObject({ status: "ok", events: [
      { id: firstStageEvent.id, eventType: "stage_dates_changed",
        item: { kind: "stage", id: firstStageId, name: "Synthetic stage A", operationId },
        before: { plannedStart: null }, after: { plannedStart: "2026-11-01" },
        actorName: "Synthetic actor" },
      { id: secondStageEvent.id, eventType: "stage_dates_changed",
        item: { kind: "stage", id: secondStageId, name: "Synthetic stage B", operationId },
        before: { plannedEnd: null }, after: { plannedEnd: "2026-11-05" } }
    ], nextCursor: { occurredAt: secondStageEvent.occurredAt, eventId: secondStageEvent.id } });
    const query = sql.mock.calls[0]?.[0] as TemplateStringsArray;
    expect(query.join("?")).toContain("list_product_change_history");
    expect(query.join("?")).not.toContain("list_stage_date_change_history");
  });
});
