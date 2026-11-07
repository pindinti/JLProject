import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { WorkerEnvironment } from "./database";

const jwksByUrl = new Map<string, JWTVerifyGetKey>();
const subjectPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const maxTokenAgeSeconds = 15 * 60;
const issuedAtClockSkewSeconds = 5;

export interface Identity {
  subject: string;
}

export async function verifyIdentity(
  request: Request,
  environment: WorkerEnvironment,
  testKeySet?: JWTVerifyGetKey
): Promise<Identity | null> {
  const authorization = request.headers.get("Authorization");
  const match = authorization?.match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/);
  if (!match || match[1].length > 8192 || !environment.NEON_AUTH_BASE_URL) return null;

  let authUrl: URL;
  try {
    authUrl = new URL(environment.NEON_AUTH_BASE_URL);
    if (
      authUrl.protocol !== "https:" ||
      !authUrl.hostname.endsWith(".neon.tech") ||
      !authUrl.pathname.endsWith("/auth") ||
      authUrl.username || authUrl.password || authUrl.search || authUrl.hash
    ) return null;
  } catch {
    return null;
  }

  const jwksUrl = new URL(`${authUrl.pathname}/.well-known/jwks.json`, authUrl.origin).href;
  let keySet = testKeySet ?? jwksByUrl.get(jwksUrl);
  if (!keySet) {
    keySet = createRemoteJWKSet(new URL(jwksUrl));
    jwksByUrl.set(jwksUrl, keySet);
  }

  try {
    const { payload } = await jwtVerify(match[1], keySet, {
      algorithms: ["EdDSA"],
      issuer: authUrl.origin,
      audience: authUrl.origin,
      requiredClaims: ["sub", "iat", "exp", "iss", "aud"],
    });

    const now = Math.floor(Date.now() / 1000);
    if (
      !payload.sub ||
      !subjectPattern.test(payload.sub) ||
      (payload.id !== undefined && payload.id !== payload.sub) ||
      typeof payload.iat !== "number" ||
      !Number.isInteger(payload.iat) ||
      payload.iat > now + issuedAtClockSkewSeconds ||
      now - payload.iat > maxTokenAgeSeconds ||
      payload.emailVerified !== true ||
      payload.banned === true
    ) return null;

    return { subject: payload.sub };
  } catch {
    return null;
  }
}
