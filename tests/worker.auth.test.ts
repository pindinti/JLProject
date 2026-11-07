// @vitest-environment node
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT
} from "jose";
import { beforeAll, describe, expect, it } from "vitest";
import { verifyIdentity } from "../worker/auth";
import { handleRequest } from "../worker/index";

const authBaseUrl = "https://auth.example.neon.tech/neondb/auth";
const issuer = new URL(authBaseUrl).origin;
const subject = "f5ad4d8b-019c-4c1f-9aa0-ff56739e40ca";
const environment = { NEON_AUTH_BASE_URL: authBaseUrl };

let privateKey: Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
let keySet: ReturnType<typeof createLocalJWKSet>;

async function issueToken(overrides: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ emailVerified: true, ...overrides })
    .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
    .setSubject(subject)
    .setIssuer(issuer)
    .setAudience(issuer)
    .setIssuedAt(now)
    .setExpirationTime(now + 600)
    .sign(privateKey);
}

async function issueTimedToken(issuedAt: number, expiresAt: number) {
  return new SignJWT({ emailVerified: true })
    .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
    .setSubject(subject).setIssuer(issuer).setAudience(issuer)
    .setIssuedAt(issuedAt).setExpirationTime(expiresAt).sign(privateKey);
}

beforeAll(async () => {
  const pair = await generateKeyPair("EdDSA", { extractable: true });
  privateKey = pair.privateKey;
  const publicJwk = await exportJWK(pair.publicKey);
  keySet = createLocalJWKSet({ keys: [{ ...publicJwk, kid: "test-key", alg: "EdDSA" }] });
});

describe("Worker identity boundary", () => {
  it("rejects missing and malformed bearer credentials", async () => {
    const missing = new Request("https://app.test/api/auth/session");
    const malformed = new Request("https://app.test/api/auth/session", {
      headers: { Authorization: "Bearer not-a-jwt" }
    });

    await expect(verifyIdentity(missing, environment, keySet)).resolves.toBeNull();
    await expect(verifyIdentity(malformed, environment, keySet)).resolves.toBeNull();
  });

  it("accepts a signed, unexpired token from the configured issuer", async () => {
    const token = await issueToken();
    const request = new Request("https://app.test/api/auth/session", {
      headers: { Authorization: `Bearer ${token}` }
    });

    await expect(verifyIdentity(request, environment, keySet)).resolves.toEqual({ subject });
  });

  it("allows small issued-at clock drift without relaxing expiry", async () => {
    const now = Math.floor(Date.now() / 1000);
    const slightlyAhead = await issueTimedToken(now + 2, now + 600);
    const tooFarAhead = await issueTimedToken(now + 60, now + 600);
    const tooOld = await issueTimedToken(now - 1000, now + 600);
    const expired = await issueTimedToken(now - 10, now - 1);

    for (const [token, accepted] of [
      [slightlyAhead, true], [tooFarAhead, false], [tooOld, false], [expired, false]
    ] as const) {
      const request = new Request("https://app.test/api/auth/session", {
        headers: { Authorization: `Bearer ${token}` }
      });
      await expect(verifyIdentity(request, environment, keySet)).resolves.toEqual(
        accepted ? { subject } : null
      );
    }
  });

  it("rejects expired, wrong-issuer, wrong-audience, unverified, and banned tokens", async () => {
    const now = Math.floor(Date.now() / 1000);
    const expired = await new SignJWT({ emailVerified: true })
      .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
      .setSubject(subject).setIssuer(issuer).setAudience(issuer)
      .setIssuedAt(now - 1200).setExpirationTime(now - 600).sign(privateKey);
    const wrongAudience = await new SignJWT({ emailVerified: true })
      .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
      .setSubject(subject).setIssuer(issuer).setAudience("https://other.example")
      .setIssuedAt(now).setExpirationTime(now + 600).sign(privateKey);
    const wrongIssuer = await new SignJWT({ emailVerified: true })
      .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
      .setSubject(subject).setIssuer("https://other.example").setAudience(issuer)
      .setIssuedAt(now).setExpirationTime(now + 600).sign(privateKey);

    for (const token of [expired, wrongIssuer, wrongAudience, await issueToken({ emailVerified: false }), await issueToken({ banned: true })]) {
      const request = new Request("https://app.test/api/auth/session", {
        headers: { Authorization: `Bearer ${token}` }
      });
      await expect(verifyIdentity(request, environment, keySet)).resolves.toBeNull();
    }
  });

  it("rejects a token signed by an untrusted key", async () => {
    const otherPair = await generateKeyPair("EdDSA");
    const now = Math.floor(Date.now() / 1000);
    const token = await new SignJWT({ emailVerified: true })
      .setProtectedHeader({ alg: "EdDSA", kid: "test-key" })
      .setSubject(subject).setIssuer(issuer).setAudience(issuer)
      .setIssuedAt(now).setExpirationTime(now + 600).sign(otherPair.privateKey);
    const request = new Request("https://app.test/api/auth/session", {
      headers: { Authorization: `Bearer ${token}` }
    });

    await expect(verifyIdentity(request, environment, keySet)).resolves.toBeNull();
  });

  it("denies workspace access to an authenticated identity without membership", async () => {
    const response = await handleRequest(
      new Request("https://app.test/api/auth/session"),
      environment,
      async () => ({ subject }),
      () => ({
        hasAnyActiveMembership: async () => false,
        findMembership: async () => null
      })
    );

    expect(response.status).toBe(403);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ error: "Acesso pendente." });
  });

  it("does not disclose token or configuration details in API errors", async () => {
    const request = new Request("https://app.test/api/auth/session", {
      headers: { Authorization: "Bearer invalid" }
    });
    const response = await handleRequest(request, environment);

    expect(response.status).toBe(401);
    const body = await response.text();
    expect(body).toBe('{"error":"Sessão inválida ou expirada."}');
    expect(body).not.toContain("invalid");
  });

  it("rejects cross-origin browser requests", async () => {
    const response = await handleRequest(
      new Request("https://app.test/api/auth/session", { headers: { Origin: "https://other.test" } }),
      environment,
      async () => ({ subject })
    );
    expect(response.status).toBe(403);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});
