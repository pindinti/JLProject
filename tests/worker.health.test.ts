import { describe, expect, it } from "vitest";
import { handleRequest } from "../worker/index";

describe("health endpoint", () => {
  it("returns a non-sensitive successful status", async () => {
    const response = await handleRequest(new Request("https://example.test/api/health"));

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ status: "ok" });
  });

  it("does not expose other API routes", async () => {
    const response = await handleRequest(new Request("https://example.test/api/unknown"));

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({ error: "Não encontrado" });
  });

  it("keeps the database connectivity check unavailable outside development", async () => {
    const response = await handleRequest(
      new Request("https://example.test/api/internal/database-connectivity")
    );

    expect(response.status).toBe(404);
  });

  it("does not disclose database errors when development configuration is absent", async () => {
    const response = await handleRequest(
      new Request("https://example.test/api/internal/database-connectivity"),
      { JLPROJECT_ENV: "development" }
    );

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ status: "unavailable" });
  });
});
