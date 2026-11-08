// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import type { ImportRepository, ImportResult } from "../worker/import-repository";
import { syntheticImportSubmission } from "./fixtures/synthetic-import";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const product = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const revision = "36cb6f40-425d-4660-b204-8dd2a129371a";
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };

function membership(role: WorkspaceRole | null, active = true): MembershipRepository {
  return { hasAnyActiveMembership: async () => !!role && active,
    findMembership: async (identity, scope) => identity === actor && scope === workspace && role
      ? { workspaceId: workspace, role, active } : null };
}
function repository(result: ImportResult = { status: "created", productId: product,
  revisionId: revision, revisionLabel: "R00" }): ImportRepository {
  return { import: vi.fn(async () => result) };
}
function request(body: unknown = syntheticImportSubmission(), scope = workspace): Request {
  return new Request(`https://app.test/api/workspaces/${scope}/imports`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
  });
}
async function call(input: Request, role: WorkspaceRole | null, repo = repository(), active = true,
  authenticated = true) {
  return handleRequest(input, environment, async () => authenticated ? { subject: actor } : null,
    () => membership(role, active), undefined, undefined, undefined, () => repo);
}

describe("workspace import API", () => {
  it("accepts a validated structured import for admins and editors", async () => {
    const repo = repository();
    const response = await call(request(), "admin", repo);
    expect(response.status).toBe(201);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toMatchObject({ productId: product, revisionId: revision, revisionLabel: "R00" });
    expect(repo.import).toHaveBeenCalledWith(workspace, actor, syntheticImportSubmission());
    expect((await call(request(), "editor")).status).toBe(201);
  });

  it("denies unauthenticated, viewer, inactive, missing, and cross-workspace requests", async () => {
    const repo = repository();
    expect((await call(request(), "admin", repo, true, false)).status).toBe(401);
    expect((await call(request(), "viewer", repo)).status).toBe(403);
    expect((await call(request(), "admin", repo, false)).status).toBe(403);
    expect((await call(request(), null, repo)).status).toBe(403);
    expect((await call(request(undefined, otherWorkspace), "admin", repo)).status).toBe(403);
    expect(repo.import).not.toHaveBeenCalled();
  });

  it("rejects dependency fields, malformed dates, and oversized payloads without repository calls", async () => {
    const repo = repository();
    expect((await call(request({ ...syntheticImportSubmission(), dependencies: [] }), "admin", repo)).status).toBe(400);
    const invalid = syntheticImportSubmission();
    invalid.disciplines[0].stages[0].activities[0].plannedEnd = "2026-10-01";
    expect((await call(request(invalid), "admin", repo)).status).toBe(400);
    const oversized = new Request(`https://app.test/api/workspaces/${workspace}/imports`, {
      method: "POST", headers: { "Content-Type": "application/json", "Content-Length": "300000" }, body: "{}"
    });
    expect((await call(oversized, "admin", repo)).status).toBe(413);
    expect(repo.import).not.toHaveBeenCalled();
  });

  it("returns safe duplicate, conflict, and replay responses", async () => {
    const duplicate = await call(request(), "admin", repository({ status: "duplicate" }));
    expect(duplicate.status).toBe(409);
    expect(await duplicate.json()).toMatchObject({ code: "duplicate" });
    expect((await call(request(), "admin", repository({ status: "conflict" }))).status).toBe(409);
    const replay = await call(request(), "admin", repository({ status: "replayed", productId: product,
      revisionId: revision, revisionLabel: "R00" }));
    expect(replay.status).toBe(200);
    expect(await replay.json()).toMatchObject({ replayed: true });
  });

  it("rejects cross-origin writes before authentication", async () => {
    const input = new Request(`https://app.test/api/workspaces/${workspace}/imports`, {
      method: "POST", headers: { "Origin": "https://other.test", "Content-Type": "application/json" },
      body: JSON.stringify(syntheticImportSubmission())
    });
    const result = await call(input, "admin");
    expect(result.status).toBe(403);
  });
});
