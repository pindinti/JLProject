import { createAuthClient } from "@neon/auth";
import { BetterAuthReactAdapter } from "@neon/auth/react/adapters";

const authUrl = import.meta.env.VITE_NEON_AUTH_URL;

export const authClient = authUrl
  ? createAuthClient(authUrl, {
      adapter: BetterAuthReactAdapter({
        fetchOptions: { credentials: "include" }
      })
    })
  : null;

interface EmailOtpClient {
  emailOtp: {
    sendVerificationOtp(input: {
      email: string;
      type: "email-verification";
    }): Promise<{ error: unknown | null }>;
    verifyEmail(input: {
      email: string;
      otp: string;
    }): Promise<{ error: unknown | null }>;
  };
}

export async function sendEmailVerificationCode(email: string): Promise<boolean> {
  if (!authClient) return false;
  const client = authClient as typeof authClient & EmailOtpClient;
  const result = await client.emailOtp.sendVerificationOtp({ email, type: "email-verification" });
  return !result.error;
}

export async function verifyEmailCode(email: string, otp: string): Promise<boolean> {
  if (!authClient) return false;
  const client = authClient as typeof authClient & EmailOtpClient;
  const result = await client.emailOtp.verifyEmail({ email, otp });
  return !result.error;
}

export async function checkWorkspaceAccess(token: string): Promise<"authorized" | "pending" | "expired" | "error"> {
  const response = await fetch("/api/auth/session", {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store"
  });

  if (response.status === 200) return "authorized";
  if (response.status === 403) return "pending";
  if (response.status === 401) return "expired";
  return "error";
}

export interface WorkspaceSummary {
  id: string;
  name: string;
  role: "admin" | "editor" | "viewer";
}

export async function listMyWorkspaces(token: string): Promise<WorkspaceSummary[]> {
  const response = await fetch("/api/workspaces", {
    headers: { Authorization: `Bearer ${token}` }, cache: "no-store"
  });
  if (!response.ok) throw new Error("Workspace lookup failed.");
  const data = await response.json() as { workspaces: WorkspaceSummary[] };
  return data.workspaces;
}

export async function authenticatedFetch(path: string, init: RequestInit = {}): Promise<Response> {
  if (!authClient) throw new Error("Auth client is unavailable.");
  const result = await authClient.getSession();
  const token = result.data?.session?.token;
  if (!token || result.error) throw new Error("Session is unavailable.");
  return fetch(path, {
    ...init,
    headers: { ...init.headers, Authorization: `Bearer ${token}` },
    cache: "no-store"
  });
}
