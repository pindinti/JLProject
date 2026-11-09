// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { provisionDevelopmentAuthUser } from "../worker/neon-auth-users";

const userId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const environment = { JLPROJECT_ENV: "development", NEON_MANAGEMENT_API_KEY: "test-only-key" };

afterEach(() => vi.unstubAllGlobals());

describe("Neon Auth provisioning boundary", () => {
  it("uses only the fixed development branch and returns the provider identity", async () => {
    const fetcher = vi.fn(async () => Response.json({ id: userId }, { status: 201 }));
    vi.stubGlobal("fetch", fetcher);
    await expect(provisionDevelopmentAuthUser("new@example.com", environment)).resolves.toEqual({ kind: "created", userId });
    const [url, options] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain("/projects/rapid-mud-63974868/branches/br-delicate-glitter-b6mj0051/auth/users");
    expect(JSON.parse(options.body as string)).toEqual({ email: "new@example.com" });
    expect(options.cache).toBe("no-store");
  });

  it("fails closed on missing credentials, production, conflicts, and malformed responses", async () => {
    const fetcher = vi.fn(async () => Response.json({}, { status: 409 }));
    vi.stubGlobal("fetch", fetcher);
    await expect(provisionDevelopmentAuthUser("new@example.com", { ...environment, JLPROJECT_ENV: "production" }))
      .resolves.toEqual({ kind: "unavailable" });
    await expect(provisionDevelopmentAuthUser("new@example.com", { JLPROJECT_ENV: "development" }))
      .resolves.toEqual({ kind: "unavailable" });
    expect(fetcher).not.toHaveBeenCalled();
    await expect(provisionDevelopmentAuthUser("new@example.com", environment)).resolves.toEqual({ kind: "conflict" });
    fetcher.mockImplementationOnce(async () => Response.json({ id: "invalid" }, { status: 201 }));
    await expect(provisionDevelopmentAuthUser("new@example.com", environment)).resolves.toEqual({ kind: "unavailable" });
  });
});
