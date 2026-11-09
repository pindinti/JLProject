import { neon } from "@neondatabase/serverless";

export interface WorkerEnvironment {
  DATABASE_URL?: string;
  JLPROJECT_ENV?: string;
  NEON_AUTH_BASE_URL?: string;
  NEON_MANAGEMENT_API_KEY?: string;
}

export async function verifyDatabaseConnectivity(
  environment: WorkerEnvironment
): Promise<boolean> {
  if (environment.DATABASE_URL === undefined || environment.DATABASE_URL.length === 0) {
    throw new Error("Worker database configuration is missing.");
  }

  const sql = neon(environment.DATABASE_URL);
  const rows = await sql`SELECT 1 AS ok`;

  return rows.length === 1 && rows[0]?.["ok"] === 1;
}
