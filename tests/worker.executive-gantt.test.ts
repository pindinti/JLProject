// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import type { ExecutiveGanttRepository, ExecutiveProduct } from "../worker/executive-gantt";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const foreignWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const url = `https://app.test/api/workspaces/${workspace}/executive-gantt`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const product: ExecutiveProduct = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3",
  name: "Synthetic product", active: false, start: null, end: null,
  rootActivities: [], disciplines: [], targets: [] };

function membership(role: WorkspaceRole | null, active = true): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => !!role && active,
    findMembership: async (subject, scope) => subject === actor && scope === workspace && role
      ? { workspaceId: workspace, role, active } : null
  };
}

function call(request: Request, role: WorkspaceRole | null, active = true,
  verify: () => Promise<{ subject: string } | null> = async () => ({ subject: actor }),
  read = vi.fn(async () => [product])) {
  const repository: ExecutiveGanttRepository = { read };
  return { response: handleRequest(request, environment, verify,
    () => membership(role, active), undefined, undefined, undefined, undefined,
    undefined, undefined, () => repository), read };
}

describe("executive Gantt API", () => {
  it("returns a private read-only projection to active members", async () => {
    for (const role of ["viewer", "editor", "admin"] as const) {
      const { response, read } = call(new Request(url), role);
      const result = await response;
      expect(result.status).toBe(200);
      expect(result.headers.get("Cache-Control")).toBe("no-store");
      expect(await result.json()).toEqual({ products: [product] });
      expect(read).toHaveBeenCalledExactlyOnceWith(workspace);
    }
  });

  it("denies unauthenticated, inactive, missing, and foreign membership before querying", async () => {
    const noIdentity = call(new Request(url), "admin", true, async () => null);
    expect((await noIdentity.response).status).toBe(401);
    expect(noIdentity.read).not.toHaveBeenCalled();
    for (const [requestUrl, role, active] of [
      [url, null, true], [url, "viewer", false],
      [url.replace(workspace, foreignWorkspace), "admin", true]
    ] as const) {
      const denied = call(new Request(requestUrl), role, active);
      expect((await denied.response).status).toBe(403);
      expect(denied.read).not.toHaveBeenCalled();
    }
  });

  it("rejects invalid workspace IDs, methods, and cross-origin requests", async () => {
    const invalid = call(new Request(url.replace(workspace, "invalid")), "viewer");
    expect((await invalid.response).status).toBe(400);
    expect(invalid.read).not.toHaveBeenCalled();
    const method = call(new Request(url, { method: "POST" }), "admin");
    expect((await method.response).status).toBe(405);
    expect(method.read).not.toHaveBeenCalled();
    const origin = call(new Request(url, { headers: { Origin: "https://other.test" } }), "admin");
    expect((await origin.response).status).toBe(403);
    expect(origin.read).not.toHaveBeenCalled();
  });

  it("hides repository failures from clients", async () => {
    const failed = call(new Request(url), "viewer", true, async () => ({ subject: actor }),
      vi.fn(async (): Promise<ExecutiveProduct[]> => { throw new Error("private database detail"); }));
    const response = await failed.response;
    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.text()).not.toContain("private database detail");
  });
});
