import { neon } from "@neondatabase/serverless";
import { importSourceContent, type ImportSubmission } from "../domain/import-contract";
import type { WorkerEnvironment } from "./database";

export type ImportResult = { status: "created" | "replayed"; productId: string;
  revisionId: string; revisionLabel: "R00" } |
  { status: "duplicate" | "conflict" | "denied" };
export interface ImportRepository {
  import(workspaceId: string, actorId: string, submission: ImportSubmission): Promise<ImportResult>;
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonical(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function sha256(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical(value)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function isUniqueViolation(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23505";
}

export function createImportRepository(environment: WorkerEnvironment): ImportRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);
  return {
    async import(workspaceId, actorId, submission) {
      const sourceHash = await sha256(importSourceContent(submission));
      const requestHash = await sha256({ workspaceId, actorId, submission });
      try {
        const rows = await sql`
          SELECT public.import_initial_schedule(${workspaceId}::uuid, ${actorId}::uuid,
            ${submission.idempotencyKey}::uuid, ${sourceHash}, ${requestHash},
            ${JSON.stringify(submission)}::jsonb) AS result
        `;
        const result = rows[0]?.["result"] as ImportResult | undefined;
        if (!result || !["created", "replayed", "duplicate", "conflict", "denied"].includes(result.status))
          throw new Error("Unexpected import result.");
        return result;
      } catch (error) {
        if (isUniqueViolation(error)) return { status: "duplicate" };
        throw error;
      }
    }
  };
}
