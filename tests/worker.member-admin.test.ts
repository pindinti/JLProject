// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import type { WorkspaceRole, MembershipRepository } from "../worker/authorization";
import type { MemberAdminRepository, UpdateResult } from "../worker/member-admin";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const member = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const memberUrl = `https://app.test/api/workspaces/${workspace}/memberships/${member}`;
const listUrl = `https://app.test/api/workspaces/${workspace}/memberships`;

function membershipRepository(role: WorkspaceRole | null, active = true): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => role !== null && active,
    findMembership: async (id, workspaceId) =>
      id === actor && workspaceId === workspace && role
        ? { workspaceId: workspace, role, active } : null
  };
}

function adminRepository(result: UpdateResult = "updated"): MemberAdminRepository {
  return {
    listOwnWorkspaces: vi.fn(async () => [{ id: workspace, name: "JLProject", role: "admin" as const }]),
    listMembers: vi.fn(async () => [{ id: member, name: "Test User", email: "test@example.com", role: "viewer" as const, active: true }]),
    updateMember: vi.fn(async () => result),
    findAuthUserIdByEmail: vi.fn(async () => null),
    addMember: vi.fn(async () => "added" as const)
  };
}

function patch(body: unknown, url = memberUrl, headers: Record<string, string> = {}): Request {
  return new Request(url, {
    method: "PATCH", headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body)
  });
}

async function call(request: Request, role: WorkspaceRole | null, admin = adminRepository(), active = true) {
  return handleRequest(request, environment, async () => ({ subject: actor }),
    () => membershipRepository(role, active), () => admin);
}

describe("workspace member administration API", () => {
  it("provisions a provider user only after current admin authorization", async () => {
    const admin = adminRepository();
    const provision = vi.fn(async () => ({ kind: "created" as const, userId: member }));
    const request = () => new Request(listUrl, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: " NEW@example.com ", role: "viewer" })
    });
    const allowed = await handleRequest(request(), environment, async () => ({ subject: actor }),
      () => membershipRepository("admin"), () => admin, undefined, undefined, undefined, provision);
    expect(allowed.status).toBe(201);
    expect(provision).toHaveBeenCalledWith("new@example.com", environment);
    expect(admin.addMember).toHaveBeenCalledWith(actor, workspace, member, "viewer");
    for (const role of ["editor", "viewer", null] as const) {
      const denied = await handleRequest(request(), environment, async () => ({ subject: actor }),
        () => membershipRepository(role), () => admin, undefined, undefined, undefined, provision);
      expect(denied.status).toBe(403);
    }
    expect(provision).toHaveBeenCalledTimes(1);
    expect((await handleRequest(request(), environment, async () => null,
      () => membershipRepository("admin"), () => admin, undefined, undefined, undefined, provision)).status).toBe(401);
  });

  it("uses a verified provider identity for existing users and rejects duplicates", async () => {
    const admin = adminRepository();
    vi.mocked(admin.findAuthUserIdByEmail).mockResolvedValue(member);
    vi.mocked(admin.addMember).mockResolvedValue("duplicate");
    const response = await handleRequest(new Request(listUrl, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "existing@example.com" })
    }), environment, async () => ({ subject: actor }), () => membershipRepository("admin"), () => admin);
    expect(response.status).toBe(409);
    expect(admin.addMember).toHaveBeenCalledWith(actor, workspace, member, "editor");
  });

  it("rejects invalid onboarding inputs and cross-origin provisioning", async () => {
    const admin = adminRepository();
    const request = (body: unknown, origin?: string) => new Request(listUrl, {
      method: "POST", headers: { "Content-Type": "application/json", ...(origin ? { Origin: origin } : {}) },
      body: JSON.stringify(body)
    });
    for (const body of [{ email: "bad" }, { email: "x@y.z", role: "owner" },
      { email: "x@y.z", authUserId: actor }, { email: "x@y.z", role: "admin", active: true }]) {
      expect((await call(request(body), "admin", admin)).status).toBe(400);
    }
    expect((await call(request({ email: "x@y.z" }), "admin", admin)).status).toBe(503);
    expect((await call(request({ email: "x@y.z" }), "admin", admin, true)).status).toBe(503);
    expect((await call(request({ email: "x@y.z" }), "admin", admin, true)).headers.get("Cache-Control")).toBe("no-store");
    expect((await call(request({ email: "x@y.z" }, "https://evil.test"), "admin", admin)).status).toBe(403);
    expect(admin.addMember).not.toHaveBeenCalled();
  });
  it("requires authentication before looking up administration data", async () => {
    const admin = adminRepository();
    for (const request of [new Request(listUrl), patch({ role: "editor" })]) {
      const response = await handleRequest(request, environment, async () => null,
        () => membershipRepository("admin"), () => admin);
      expect(response.status).toBe(401);
    }
    expect(admin.listMembers).not.toHaveBeenCalled();
    expect(admin.updateMember).not.toHaveBeenCalled();
  });

  it("lists only for an active administrator and ignores client role claims", async () => {
    const admin = adminRepository();
    const allowed = await call(new Request(listUrl), "admin", admin);
    expect(allowed.status).toBe(200);
    expect(allowed.headers.get("Cache-Control")).toBe("no-store");
    await expect(allowed.json()).resolves.toMatchObject({ memberships: [{ role: "viewer" }] });
    for (const role of ["editor", "viewer", null] as const) {
      const denied = await call(new Request(listUrl, { headers: { "X-Workspace-Role": "admin" } }), role, admin);
      expect(denied.status).toBe(403);
    }
    expect((await call(new Request(listUrl), "admin", admin, false)).status).toBe(403);
    expect((await call(new Request(`https://app.test/api/workspaces/${otherWorkspace}/memberships`), "admin", admin)).status).toBe(403);
    expect(admin.listMembers).toHaveBeenCalledTimes(1);
  });

  it("lists only active workspaces for the authenticated identity", async () => {
    const admin = adminRepository();
    const response = await call(new Request("https://app.test/api/workspaces"), "viewer", admin);
    expect(response.status).toBe(200);
    expect(admin.listOwnWorkspaces).toHaveBeenCalledWith(actor);
    expect((await call(new Request("https://app.test/api/workspaces"), null, admin)).status).toBe(403);
  });

  it("accepts role and status changes with the verified actor ID", async () => {
    const admin = adminRepository();
    expect((await call(patch({ role: "editor" }, memberUrl, { "X-User-Id": member }), "admin", admin)).status).toBe(200);
    expect(admin.updateMember).toHaveBeenCalledWith(actor, workspace, member, { role: "editor" });
    expect((await call(patch({ active: false }), "admin", admin)).status).toBe(200);
    expect(admin.updateMember).toHaveBeenCalledWith(actor, workspace, member, { active: false });
    expect((await call(patch({ active: true }), "admin", admin)).status).toBe(200);
  });

  it("rejects invalid bodies, unknown IDs, and cross-origin mutations", async () => {
    const admin = adminRepository();
    for (const body of [{ role: "owner" }, { role: "admin", active: true }, { active: "true" }, {}, { authUserId: actor }]) {
      expect((await call(patch(body), "admin", admin)).status).toBe(400);
    }
    expect((await call(patch({ role: "editor" }, memberUrl.replace(member, "invalid")), "admin", admin)).status).toBe(404);
    expect((await call(patch({ role: "editor" }, memberUrl, { Origin: "https://other.test" }), "admin", admin)).status).toBe(403);
    expect(admin.updateMember).not.toHaveBeenCalled();
  });

  it("maps last-admin and unknown-member outcomes without leaking database details", async () => {
    const lastAdmin = await call(patch({ active: false }), "admin", adminRepository("last_admin"));
    expect(lastAdmin.status).toBe(409);
    await expect(lastAdmin.json()).resolves.toEqual({ error: "É necessário manter um administrador ativo." });
    expect((await call(patch({ role: "viewer" }), "admin", adminRepository("not_found"))).status).toBe(404);
    expect((await call(patch({ role: "viewer" }), "admin", adminRepository("denied"))).status).toBe(403);
    const failed = await handleRequest(patch({ role: "viewer" }), environment, async () => ({ subject: actor }),
      () => membershipRepository("admin"), () => ({ ...adminRepository(), updateMember: async () => { throw new Error("private detail"); } }));
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private detail");
  });

  it("prevents editor, viewer, inactive, and cross-workspace mutations", async () => {
    const admin = adminRepository();
    for (const role of ["editor", "viewer", null] as const) {
      expect((await call(patch({ role: "admin" }), role, admin)).status).toBe(403);
    }
    expect((await call(patch({ active: true }), "admin", admin, false)).status).toBe(403);
    expect((await call(patch({ role: "admin" }, memberUrl.replace(workspace, otherWorkspace)), "admin", admin)).status).toBe(403);
    expect(admin.updateMember).not.toHaveBeenCalled();
  });
});
