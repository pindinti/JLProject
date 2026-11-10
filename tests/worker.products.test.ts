// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../worker/index";
import type { MembershipRepository, WorkspaceRole } from "../worker/authorization";
import type { Product, ProductRepository } from "../worker/products";

const actor = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const productId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const base = `https://app.test/api/workspaces/${workspace}/products`;
const environment = { NEON_AUTH_BASE_URL: "https://auth.example.neon.tech/neondb/auth" };
const product: Product = {
  id: productId, workspaceId: workspace, name: "Synthetic product", description: null,
  active: true, version: 1, createdAt: "2026-11-07T00:00:00.000Z", updatedAt: "2026-11-07T00:00:00.000Z"
};

function membership(role: WorkspaceRole | null, active = true): MembershipRepository {
  return {
    hasAnyActiveMembership: async () => !!role && active,
    findMembership: async (id, scope) => id === actor && scope === workspace && role
      ? { workspaceId: workspace, role, active } : null
  };
}

function products(): ProductRepository {
  return {
    list: vi.fn(async () => [product]),
    find: vi.fn(async (_scope, id) => id === productId ? product : null),
    create: vi.fn(async () => ({ status: "ok" as const, product })),
    clone: vi.fn(async () => ({ status: "ok" as const, product: { ...product, id: "b3aa998a-a2c3-4376-9105-90af0d1dbfe3", name: "Cloned product" }, revisionId: "c3aa998a-a2c3-4376-9105-90af0d1dbfe3" })),
    update: vi.fn(async () => ({ status: "ok" as const, product: { ...product, version: 2 } })),
    archive: vi.fn(async () => ({ status: "ok" as const, product: { ...product, active: false, version: 2 } }))
  };
}

function request(path = base, method = "GET", body?: unknown): Request {
  return new Request(path, {
    method,
    ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
  });
}

async function call(input: Request, role: WorkspaceRole | null, repository = products(), active = true) {
  return handleRequest(input, environment, async () => ({ subject: actor }),
    () => membership(role, active), undefined, () => repository);
}

describe("product API", () => {
  it("lists and reads only within an active authorized workspace", async () => {
    const repository = products();
    const list = await call(request(), "viewer", repository);
    expect(list.status).toBe(200);
    expect(list.headers.get("Cache-Control")).toBe("no-store");
    expect(repository.list).toHaveBeenCalledWith(workspace);
    await expect(list.json()).resolves.toEqual({ products: [product] });
    expect((await call(request(`${base}/${productId}`), "editor", repository)).status).toBe(200);
    expect(repository.find).toHaveBeenCalledWith(workspace, productId);
    expect((await call(request(`${base}/11111111-1111-4111-8111-111111111111`), "admin", repository)).status).toBe(404);
  });

  it("creates, updates, and archives with the verified actor and a version", async () => {
    const repository = products();
    const input = { name: "Synthetic product", description: "Test" };
    expect((await call(request(base, "POST", input), "editor", repository)).status).toBe(201);
    expect(repository.create).toHaveBeenCalledWith(workspace, actor, input);
    expect((await call(request(`${base}/${productId}`, "PATCH", { ...input, version: 1 }), "admin", repository)).status).toBe(200);
    expect(repository.update).toHaveBeenCalledWith(workspace, productId, actor, input, 1);
    expect((await call(request(`${base}/${productId}/archive`, "POST", { version: 1 }), "editor", repository)).status).toBe(200);
    expect(repository.archive).toHaveBeenCalledWith(workspace, productId, actor, 1);
  });

  it("clones for active editors and admins using the verified identity and workspace", async () => {
    const repository = products();
    const response = await call(request(`${base}/${productId}/clone`, "POST", { name: " Cloned product " }), "editor", repository);
    expect(response.status).toBe(201);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    await expect(response.json()).resolves.toMatchObject({ product: { workspaceId: workspace }, revisionLabel: "R00" });
    expect(repository.clone).toHaveBeenCalledWith(workspace, productId, actor, "Cloned product");
    expect((await call(request(`${base}/${productId}/clone`, "POST", { name: "Admin clone" }), "admin", repository)).status).toBe(201);
  });

  it("denies clone to viewers, inactive or unauthenticated members and foreign workspaces", async () => {
    const repository = products();
    expect((await call(request(`${base}/${productId}/clone`, "POST", { name: "Denied" }), "viewer", repository)).status).toBe(403);
    expect((await call(request(`${base}/${productId}/clone`, "POST", { name: "Denied" }), "editor", repository, false)).status).toBe(403);
    expect((await call(request(`${base.replace(workspace, otherWorkspace)}/${productId}/clone`, "POST", { name: "Denied" }), "admin", repository)).status).toBe(403);
    const unauthenticated = await handleRequest(request(`${base}/${productId}/clone`, "POST", { name: "Denied" }), environment,
      async () => null, () => membership("admin"), undefined, () => repository);
    expect(unauthenticated.status).toBe(401);
    expect(repository.clone).not.toHaveBeenCalled();
  });

  it("validates clone identifiers and names, and maps conflicts and missing sources safely", async () => {
    const repository = products();
    for (const body of [{ name: "" }, { name: "  " }, { name: "x", actorId: actor }, { name: 42 }, { name: "x".repeat(201) }]) {
      expect((await call(request(`${base}/${productId}/clone`, "POST", body), "admin", repository)).status).toBe(400);
    }
    expect((await call(request(`${base}/invalid/clone`, "POST", { name: "Valid" }), "admin", repository)).status).toBe(400);
    const duplicate = await call(request(`${base}/${productId}/clone`, "POST", { name: "Existing" }), "admin", {
      ...repository, clone: async () => ({ status: "duplicate" })
    });
    expect(duplicate.status).toBe(409);
    await expect(duplicate.json()).resolves.toMatchObject({ code: "duplicate" });
    const missing = await call(request(`${base}/${productId}/clone`, "POST", { name: "Missing source" }), "admin", {
      ...repository, clone: async () => ({ status: "not_found" })
    });
    expect(missing.status).toBe(404);
    expect(await missing.text()).not.toContain("database");
  });

  it("denies unauthenticated, pending, inactive, viewer writes, and cross-workspace requests", async () => {
    const repository = products();
    const unauthenticated = await handleRequest(request(), environment, async () => null,
      () => membership("admin"), undefined, () => repository);
    expect(unauthenticated.status).toBe(401);
    for (const role of [null, "admin"] as const) {
      expect((await call(request(), role, repository, role !== "admin")).status).toBe(403);
    }
    expect((await call(request(base, "POST", { name: "Denied" }), "viewer", repository)).status).toBe(403);
    expect((await call(request(`${base}/${productId}`, "PATCH", { name: "Denied", version: 1 }), "viewer", repository)).status).toBe(403);
    expect((await call(request(`${base}/${productId}/archive`, "POST", { version: 1 }), "viewer", repository)).status).toBe(403);
    expect((await call(request(base.replace(workspace, otherWorkspace)), "admin", repository)).status).toBe(403);
    expect(repository.create).not.toHaveBeenCalled();
    expect(repository.update).not.toHaveBeenCalled();
    expect(repository.archive).not.toHaveBeenCalled();
  });

  it("rejects malformed data, stale versions, duplicates, and foreign product IDs", async () => {
    const repository = products();
    for (const body of [{ name: "" }, { name: "x", role: "admin" }, { name: 42 }, { name: "x", description: 42 }]) {
      expect((await call(request(base, "POST", body), "admin", repository)).status).toBe(400);
    }
    expect((await call(request(`${base}/${productId}`, "PATCH", { name: "x" }), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}/${productId}/archive`, "POST", { version: 0 }), "admin", repository)).status).toBe(400);
    expect((await call(request(base.replace(workspace, "invalid")), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}/invalid`), "admin", repository)).status).toBe(400);
    expect((await call(request(`${base}/${productId}`, "PATCH", { name: "x", version: 1 }), "admin", {
      ...repository, update: async () => ({ status: "stale" })
    })).status).toBe(409);
    const duplicate = await call(request(base, "POST", { name: "x" }), "admin", {
      ...repository, create: async () => ({ status: "duplicate" })
    });
    expect(duplicate.status).toBe(409);
    await expect(duplicate.json()).resolves.toMatchObject({ code: "duplicate" });
    const missing = await call(request(`${base}/${productId}`, "PATCH", { name: "x", version: 1 }), "admin", {
      ...repository, update: async () => ({ status: "not_found" })
    });
    expect(missing.status).toBe(404);
  });

  it("keeps internal failures private and rejects cross-origin writes", async () => {
    const repository = products();
    const crossOrigin = new Request(base, {
      method: "POST", headers: { Origin: "https://other.test", "Content-Type": "application/json" },
      body: JSON.stringify({ name: "Denied" })
    });
    expect((await call(crossOrigin, "admin", repository)).status).toBe(403);
    const failed = await call(request(), "admin", {
      ...repository, list: async () => { throw new Error("private database detail"); }
    });
    expect(failed.status).toBe(503);
    expect(await failed.text()).not.toContain("private database detail");
  });

  it("rejects a repository result that belongs to another workspace", async () => {
    const repository = products();
    const foreign = { ...product, workspaceId: otherWorkspace };
    expect((await call(request(`${base}/${productId}`), "admin", {
      ...repository, find: async () => foreign
    })).status).toBe(404);
    expect((await call(request(), "admin", {
      ...repository, list: async () => [foreign]
    })).status).toBe(503);
    expect((await call(request(base, "POST", { name: "Synthetic product" }), "admin", {
      ...repository, create: async () => ({ status: "ok", product: foreign })
    })).status).toBe(503);
  });
});
