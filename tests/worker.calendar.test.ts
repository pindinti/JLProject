// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import type { CalendarException } from "../domain/working-calendar";
import { handleCalendarRequest } from "../worker/calendar-api";
import type { CalendarRepository } from "../worker/calendar-repository";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import { handleRequest } from "../worker/index";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const exceptionId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const base = `https://app.test/api/workspaces/${workspace}/calendar`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const holiday: CalendarException = {
  id: exceptionId, kind: "municipal_holiday", name: "Synthetic holiday", municipality: "Test City",
  description: null, startDate: "2026-11-09", endDate: "2026-11-09", version: 1
};

function membership(role: WorkspaceRole | null, active = true): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => role !== null && active,
    findMembership: async (id, scope) => id === actor && scope === workspace && role
      ? { workspaceId: workspace, role, active } : null
  };
}

function calendar(): CalendarRepository {
  return {
    read: vi.fn(async () => ({ version: 2, exceptions: [holiday] })),
    readForCalculation: vi.fn(async () => ({ version: 2, exceptions: [holiday] })),
    history: vi.fn(async () => ({ entries: [], nextBeforeVersion: null })),
    change: vi.fn(async (_ws: string, _actor: string, _operation: string, _version: number,
      action: "create" | "update" | "remove") => ({
      status: action === "create" ? "created" as const : action === "update" ? "updated" as const : "removed" as const,
      version: 3
    }))
  };
}

function request(path: string, method = "GET", body?: unknown): Request {
  return new Request(path, { method,
    ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
  });
}

async function call(input: Request, role: WorkspaceRole | null, repository = calendar(), active = true) {
  return handleCalendarRequest(input, { subject: actor }, membership(role, active), environment, () => repository);
}

describe("working calendar API", () => {
  it("routes an authenticated calendar request through the Worker boundary", async () => {
    const repository = calendar();
    const result = await handleRequest(request(`${base}?year=2026`), environment,
      async () => ({ subject: actor }), () => membership("viewer"),
      undefined, undefined, undefined, undefined, undefined, () => repository);
    expect(result.status).toBe(200);
    expect(repository.read).toHaveBeenCalledWith(workspace, 2026);
  });

  it("allows active workspace members to read only their calendar and history", async () => {
    const repository = calendar();
    for (const role of ["admin", "editor", "viewer"] as const) {
      const response = await call(request(`${base}?year=2026`), role, repository);
      expect(response.status).toBe(200);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      await expect(response.json()).resolves.toEqual({ calendar: { version: 2, exceptions: [holiday] } });
    }
    expect(repository.read).toHaveBeenCalledWith(workspace, 2026);
    expect((await call(request(`${base}/history?beforeVersion=9`), "viewer", repository)).status).toBe(200);
    expect(repository.history).toHaveBeenCalledWith(workspace, 9);
    expect((await call(request(`${base.replace(workspace, otherWorkspace)}?year=2026`), "admin", repository)).status).toBe(403);
    expect((await call(request(`${base}?year=2026`), "admin", repository, false)).status).toBe(403);
  });

  it("previews inclusive working-day dates with authoritative exceptions and optional-day coverage", async () => {
    const repository = calendar();
    const preview = await call(request(`${base}/working-day-preview?startDate=2026-11-06&workingDays=2`),
      "viewer", repository);
    expect(preview.status).toBe(200);
    const previewBody = await preview.json() as { preview: {
      startDate: string; endDate: string; workingDays: number; calendarVersion: number;
      optionalDaysVerified: boolean; skippedDates: { date: string; reasons: { kind: string }[] }[]
    } };
    expect(previewBody.preview).toMatchObject({ startDate: "2026-11-06", endDate: "2026-11-10",
      workingDays: 2, calendarVersion: 2, optionalDaysVerified: true });
    expect(previewBody.preview.skippedDates.some((item) => item.date === "2026-11-09" &&
      item.reasons.some((reason) => reason.kind === "municipal_holiday"))).toBe(true);
    expect(repository.readForCalculation).toHaveBeenCalledWith(workspace);
    const future = await call(request(`${base}/working-day-preview?startDate=2027-01-04&workingDays=1`),
      "editor", repository);
    await expect(future.json()).resolves.toMatchObject({ preview: {
      endDate: "2027-01-04", optionalDaysVerified: false, unverifiedOptionalYears: [2027]
    } });
    for (const path of [
      `${base}/working-day-preview?startDate=2026-02-30&workingDays=1`,
      `${base}/working-day-preview?startDate=2026-11-06&workingDays=0`,
      `${base}/working-day-preview?startDate=2026-11-06&workingDays=2&endDate=2026-11-10`
    ]) expect((await call(request(path), "viewer", repository)).status).toBe(400);
    expect((await call(request(`${base.replace(workspace, otherWorkspace)}/working-day-preview?startDate=2026-11-06&workingDays=2`),
      "viewer", repository)).status).toBe(403);
  });

  it("uses verified admin identity and generated operation IDs for create, edit, and remove", async () => {
    const repository = calendar();
    const input = { expectedVersion: 2, kind: "municipal_holiday", name: "Synthetic holiday",
      municipality: "Test City", description: null, startDate: "2026-11-09", endDate: "2026-11-09" };
    expect((await call(request(`${base}/exceptions`, "POST", input), "admin", repository)).status).toBe(201);
    expect((await call(request(`${base}/exceptions/${exceptionId}`, "PATCH", input), "admin", repository)).status).toBe(200);
    expect((await call(request(`${base}/exceptions/${exceptionId}`, "DELETE", { expectedVersion: 2 }), "admin", repository)).status).toBe(200);
    expect(repository.change).toHaveBeenNthCalledWith(1, workspace, actor, expect.any(String), 2, "create", null,
      { kind: input.kind, name: input.name, municipality: input.municipality,
        description: null, startDate: input.startDate, endDate: input.endDate });
    expect(repository.change).toHaveBeenNthCalledWith(2, workspace, actor, expect.any(String), 2, "update", exceptionId,
      expect.any(Object));
    expect(repository.change).toHaveBeenNthCalledWith(3, workspace, actor, expect.any(String), 2, "remove", exceptionId, null);
    const calls = vi.mocked(repository.change).mock.calls;
    expect(new Set(calls.map((entry) => entry[2])).size).toBe(3);
    expect(calls.every((entry) => /^[0-9a-f-]{36}$/i.test(entry[2]))).toBe(true);
  });

  it("accepts bounded collective vacation and company shutdown periods", async () => {
    const repository = calendar();
    for (const kind of ["collective_vacation", "company_shutdown"] as const) {
      const input = { expectedVersion: 2, kind, name: null, municipality: null,
        description: "Synthetic closure", startDate: "2026-12-21", endDate: "2026-12-31" };
      expect((await call(request(`${base}/exceptions`, "POST", input), "admin", repository)).status).toBe(201);
      expect(repository.change).toHaveBeenCalledWith(workspace, actor, expect.any(String), 2,
        "create", null, { kind, name: null, municipality: null, description: input.description,
          startDate: input.startDate, endDate: input.endDate });
    }
  });

  it("denies editors, viewers, inactive members, foreign workspaces, and unauthenticated requests", async () => {
    const repository = calendar();
    const input = { expectedVersion: 0, kind: "company_shutdown", name: null, municipality: null,
      description: "Synthetic shutdown", startDate: "2026-12-21", endDate: "2026-12-31" };
    for (const role of ["editor", "viewer"] as const)
      expect((await call(request(`${base}/exceptions`, "POST", input), role, repository)).status).toBe(403);
    expect((await call(request(`${base}/exceptions`, "POST", input), "admin", repository, false)).status).toBe(403);
    expect((await call(request(`${base.replace(workspace, otherWorkspace)}/exceptions`, "POST", input), "admin", repository)).status).toBe(403);
    expect(repository.change).not.toHaveBeenCalled();
    const unauthenticated = await handleRequest(request(`${base}?year=2026`), environment, async () => null);
    expect(unauthenticated.status).toBe(401);
    expect(await unauthenticated.text()).not.toMatch(/postgres|token|connection/i);
  });

  it("rejects invalid identifiers, dates, extra claims, versions, and oversized ranges before writing", async () => {
    const repository = calendar();
    expect((await call(request(`${base}?year=2026&year=2027`), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}?year=2101`), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}/history?beforeVersion=0`), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}/exceptions/not-a-uuid`, "DELETE", { expectedVersion: 0 }), "admin", repository)).status).toBe(400);
    const valid = { expectedVersion: 0, kind: "municipal_holiday", name: "Synthetic holiday",
      municipality: "Test City", description: null, startDate: "2026-11-09", endDate: "2026-11-09" };
    for (const invalid of [
      { ...valid, startDate: "2026-02-29", endDate: "2026-02-29" },
      { ...valid, role: "admin" },
      { ...valid, expectedVersion: -1 },
      { ...valid, municipality: "  " },
      { ...valid, kind: "company_shutdown", name: null, municipality: null, description: "Test", endDate: "2028-11-09" }
    ]) expect((await call(request(`${base}/exceptions`, "POST", invalid), "admin", repository)).status).toBe(400);
    expect(repository.change).not.toHaveBeenCalled();
  });

  it("returns safe stale, duplicate, and missing-record responses", async () => {
    const repository = calendar();
    const input = { expectedVersion: 2, kind: "municipal_holiday", name: "Synthetic holiday",
      municipality: "Test City", description: null, startDate: "2026-11-09", endDate: "2026-11-09" };
    vi.mocked(repository.change).mockResolvedValueOnce({ status: "stale" })
      .mockResolvedValueOnce({ status: "duplicate" }).mockResolvedValueOnce({ status: "not_found" });
    const statuses = [];
    for (let index = 0; index < 3; index++) {
      const response = await call(request(`${base}/exceptions`, "POST", input), "admin", repository);
      statuses.push(response.status);
      expect(await response.text()).not.toMatch(/postgres|select|connection|token/i);
    }
    expect(statuses).toEqual([409, 409, 404]);
  });
});
