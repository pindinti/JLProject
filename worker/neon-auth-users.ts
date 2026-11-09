import type { WorkerEnvironment } from "./database";

const projectId = "rapid-mud-63974868";
const developmentBranchId = "br-delicate-glitter-b6mj0051";
const userIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type ProvisionResult = { kind: "created"; userId: string } | { kind: "conflict" } | { kind: "unavailable" };

export async function provisionDevelopmentAuthUser(email: string, environment: WorkerEnvironment): Promise<ProvisionResult> {
  if (environment.JLPROJECT_ENV !== "development" || !environment.NEON_MANAGEMENT_API_KEY) {
    return { kind: "unavailable" };
  }
  try {
    const response = await fetch(
      `https://console.neon.tech/api/v2/projects/${projectId}/branches/${developmentBranchId}/auth/users`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${environment.NEON_MANAGEMENT_API_KEY}`,
          "Content-Type": "application/json",
          Accept: "application/json"
        },
        body: JSON.stringify({ email }),
        cache: "no-store"
      }
    );
    if (response.status === 409) return { kind: "conflict" };
    if (response.status !== 201) return { kind: "unavailable" };
    const data: unknown = await response.json();
    const userId = data && typeof data === "object" && "id" in data ? data.id : null;
    return typeof userId === "string" && userIdPattern.test(userId)
      ? { kind: "created", userId } : { kind: "unavailable" };
  } catch {
    return { kind: "unavailable" };
  }
}
