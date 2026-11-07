// @vitest-environment node
import { describe, expect, it } from "vitest";
import {
  authorizeResource,
  authorizeWorkspace,
  hasPermission,
  type MembershipRepository,
  type WorkspaceMembership,
  type WorkspacePermission,
  type WorkspaceRole
} from "../worker/authorization";
import { handleRequest } from "../worker/index";

const subject = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspaceId = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspaceId = "d441363c-bdde-4422-93d6-59b3868d29f4";
const resourceId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const identity = { subject };

function repository(membership: WorkspaceMembership | null): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => membership?.active === true,
    findMembership: async (authUserId, requestedWorkspaceId) =>
      authUserId === subject && requestedWorkspaceId === workspaceId ? membership : null
  };
}

function activeMembership(role: WorkspaceRole): WorkspaceMembership {
  return { workspaceId, role, active: true };
}

describe("workspace authorization", () => {
  it("denies every permission without an active membership", async () => {
    for (const membership of [null, { ...activeMembership("admin"), active: false }]) {
      for (const permission of ["read", "edit", "manage"] as const) {
        await expect(authorizeWorkspace(identity, workspaceId, permission, repository(membership)))
          .resolves.toBeNull();
      }
    }
  });

  it("enforces admin, editor, and viewer permissions", async () => {
    const allowed: Record<WorkspaceRole, WorkspacePermission[]> = {
      admin: ["read", "edit", "manage"],
      editor: ["read", "edit"],
      viewer: ["read"]
    };
    for (const role of ["admin", "editor", "viewer"] as const) {
      for (const permission of ["read", "edit", "manage"] as const) {
        expect(hasPermission(role, permission)).toBe(allowed[role].includes(permission));
        const result = await authorizeWorkspace(identity, workspaceId, permission, repository(activeMembership(role)));
        expect(result !== null).toBe(allowed[role].includes(permission));
      }
    }
    expect(hasPermission("owner", "manage")).toBe(false);
    await expect(authorizeWorkspace(identity, workspaceId.toUpperCase(), "read", repository(activeMembership("viewer"))))
      .resolves.toEqual(activeMembership("viewer"));
  });

  it("rejects invalid identities, unknown workspaces, and mismatched membership rows", async () => {
    const memberRepository = repository(activeMembership("admin"));
    await expect(authorizeWorkspace({ subject: "invalid" }, workspaceId, "read", memberRepository))
      .resolves.toBeNull();
    await expect(authorizeWorkspace(identity, "unknown", "read", memberRepository))
      .resolves.toBeNull();
    await expect(authorizeWorkspace(identity, otherWorkspaceId, "read", memberRepository))
      .resolves.toBeNull();
    await expect(authorizeWorkspace(identity, workspaceId, "read", repository({
      ...activeMembership("admin"), workspaceId: otherWorkspaceId
    }))).resolves.toBeNull();
  });

  it("checks resource ownership before granting workspace-scoped access", async () => {
    const memberRepository = repository(activeMembership("editor"));
    const sameWorkspace = { findWorkspaceId: async () => workspaceId };
    const differentWorkspace = { findWorkspaceId: async () => otherWorkspaceId };
    const unknownResource = { findWorkspaceId: async () => null };
    await expect(authorizeResource(identity, workspaceId, resourceId, "edit", memberRepository, sameWorkspace))
      .resolves.toEqual(activeMembership("editor"));
    await expect(authorizeResource(identity, workspaceId, resourceId, "read", memberRepository, differentWorkspace))
      .resolves.toBeNull();
    await expect(authorizeResource(identity, workspaceId, resourceId, "read", memberRepository, unknownResource))
      .resolves.toBeNull();
    await expect(authorizeResource(identity, workspaceId, "unknown", "read", memberRepository, sameWorkspace))
      .resolves.toBeNull();
    await expect(authorizeResource(identity, workspaceId, resourceId, "manage", memberRepository, sameWorkspace))
      .resolves.toBeNull();
    let resourceQueried = false;
    await expect(authorizeResource(identity, workspaceId, resourceId, "read", repository(null), {
      findWorkspaceId: async () => { resourceQueried = true; return workspaceId; }
    })).resolves.toBeNull();
    expect(resourceQueried).toBe(false);
  });
});

describe("protected membership API", () => {
  const membershipUrl = `https://app.test/api/workspaces/${workspaceId}/membership`;

  it("rejects unauthenticated and expired identities without querying membership", async () => {
    let repositoryUsed = false;
    for (const request of [
      new Request(membershipUrl),
      new Request(membershipUrl, { headers: { Authorization: "Bearer expired" } })
    ]) {
      const response = await handleRequest(request, environment, async () => null, () => {
        repositoryUsed = true;
        return repository(activeMembership("admin"));
      });
      expect(response.status).toBe(401);
      await expect(response.json()).resolves.toEqual({ error: "Sessão inválida ou expirada." });
    }
    expect(repositoryUsed).toBe(false);
  });

  it("returns only workspace ID and database role for an active member", async () => {
    const response = await handleRequest(
      new Request(membershipUrl), environment, async () => identity,
      () => repository(activeMembership("viewer"))
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ workspaceId, role: "viewer" });
  });

  it("ignores a client role header and denies inactive and cross-workspace access", async () => {
    const request = new Request(membershipUrl, {
      headers: { "X-Workspace-Role": "admin", "X-User-Id": subject }
    });
    for (const membership of [null, { ...activeMembership("admin"), active: false }]) {
      const response = await handleRequest(request, environment, async () => identity, () => repository(membership));
      expect(response.status).toBe(403);
      await expect(response.json()).resolves.toEqual({ error: "Acesso não autorizado." });
    }
    const otherResponse = await handleRequest(
      new Request(`https://app.test/api/workspaces/${otherWorkspaceId}/membership`),
      environment, async () => identity, () => repository(activeMembership("admin"))
    );
    expect(otherResponse.status).toBe(403);
  });

  it("keeps unknown IDs and internal failures non-sensitive", async () => {
    const unknown = await handleRequest(
      new Request("https://app.test/api/workspaces/unknown/membership"),
      environment, async () => identity, () => repository(activeMembership("admin"))
    );
    expect(unknown.status).toBe(404);
    const failed = await handleRequest(
      new Request(membershipUrl), environment, async () => identity,
      () => ({
        hasAnyActiveMembership: async () => { throw new Error("private database detail"); },
        findMembership: async () => { throw new Error("private database detail"); }
      })
    );
    expect(failed.status).toBe(503);
    const error = await failed.text();
    expect(error).toContain("Serviço indisponível.");
    expect(error).not.toContain("private database detail");
  });

  it("requires membership for session authorization and does not trust identity alone", async () => {
    const request = new Request("https://app.test/api/auth/session");
    const denied = await handleRequest(request, environment, async () => identity, () => repository(null));
    expect(denied.status).toBe(403);
    const allowed = await handleRequest(request, environment, async () => identity, () => repository(activeMembership("editor")));
    expect(allowed.status).toBe(200);
    await expect(allowed.json()).resolves.toEqual({ status: "authorized" });
  });
});
