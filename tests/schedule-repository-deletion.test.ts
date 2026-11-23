// @vitest-environment node
import { describe, expect, it, vi } from "vitest";

const { neonMock } = vi.hoisted(() => ({ neonMock: vi.fn() }));
vi.mock("@neondatabase/serverless", () => ({ neon: neonMock }));

import { createScheduleRepository } from "../worker/schedule-repository";

const linkedConflict = { dependencyId: "a1111111-1111-4111-8111-111111111111", reason: "linked_endpoint",
  predecessor: { id: "a2222222-2222-4222-8222-222222222222", kind: "activity" },
  successor: { id: "a3333333-3333-4333-8333-333333333333", kind: "activity" },
  linkedEndpoint: { id: "a2222222-2222-4222-8222-222222222222", kind: "activity" } };
const dateConflict = { dependencyId: "a4444444-4444-4444-8444-444444444444", reason: "finish_to_start",
  predecessor: { id: "a5555555-5555-4555-8555-555555555555", kind: "stage" },
  successor: { id: "a6666666-6666-4666-8666-666666666666", kind: "stage" },
  before: { predecessorFinish: "2026-11-10", successorStart: "2026-11-11", earliestStart: "2026-11-11" },
  after: { predecessorFinish: "2026-11-11", successorStart: "2026-11-11", earliestStart: "2026-11-12" } };

function fixture() {
  const sql = vi.fn();
  neonMock.mockReturnValue(sql);
  const repository = createScheduleRepository({ DATABASE_URL: "postgresql://example.invalid" });
  return { sql, repository };
}

describe("schedule deletion dependency adapter", () => {
  it("decodes linked endpoint conflicts for preview and confirmed deletion", async () => {
    const { sql, repository } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: linkedConflict } }]);
    await expect(repository.previewDeletion("workspace", "product", "actor", "discipline", "target"))
      .resolves.toEqual({ status: "dependency_conflict", conflict: linkedConflict });
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: linkedConflict } }]);
    await expect(repository.deleteSubtree("workspace", "product", "actor", "operation", "stage", "target",
      "a".repeat(32), "Synthetic deletion justification"))
      .resolves.toEqual({ status: "dependency_conflict", conflict: linkedConflict });
    expect(sql).toHaveBeenCalledTimes(2);
    expect(sql.mock.calls[0]?.[0]?.join("?")).toContain("public.preview_schedule_deletion(");
    expect(sql.mock.calls[1]?.[0]?.join("?")).toContain("public.delete_schedule_subtree(");
  });

  it("accepts only validated stage boundary conflicts and preserves ordinary empty-graph results", async () => {
    const { sql, repository } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: dateConflict } }]);
    await expect(repository.previewDeletion("workspace", "product", "actor", "activity", "target"))
      .resolves.toEqual({ status: "dependency_conflict", conflict: dateConflict });
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: {
      ...dateConflict, successor: { ...dateConflict.successor, kind: "activity" }
    } } }]);
    await expect(repository.previewDeletion("workspace", "product", "actor", "activity", "target"))
      .rejects.toThrow("Unexpected calendar dependency rejection.");
    sql.mockResolvedValueOnce([{ result: { status: "ok", fingerprint: "b".repeat(32),
      counts: { disciplines: 0, stages: 0, activities: 1 } } }]);
    await expect(repository.previewDeletion("workspace", "product", "actor", "activity", "target"))
      .resolves.toEqual({ status: "ok", fingerprint: "b".repeat(32),
        counts: { disciplines: 0, stages: 0, activities: 1 } });
  });

  it("rejects malformed linked endpoint evidence", async () => {
    const { sql, repository } = fixture();
    sql.mockResolvedValueOnce([{ result: { status: "dependency_conflict", conflict: {
      ...linkedConflict, linkedEndpoint: { id: "a7777777-7777-4777-8777-777777777777", kind: "activity" }
    } } }]);
    await expect(repository.deleteSubtree("workspace", "product", "actor", "operation", "activity", "target",
      "a".repeat(32), "Synthetic deletion justification"))
      .rejects.toThrow("Unexpected linked deletion dependency rejection.");
  });
});
