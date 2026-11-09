import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const line = settings.match(/^DATABASE_URL=(.*)$/m);
if (!line) throw new Error("Local Worker database configuration is missing.");
const connection = new URL(line[1].trim().replace(/^"|"$/g, ""));
if (connection.username !== "jlproject_worker")
  throw new Error("The grant check requires the limited development Worker role.");
const sql = neon(connection.toString());

try {
  const workspaces = await sql`SELECT id::text AS id FROM public.workspaces WHERE name = 'JLProject'`;
  if (workspaces.length !== 1) throw new Error("Expected one development workspace.");
  const workspaceId = String(workspaces[0]["id"]);
  await sql`SELECT count(*) FROM public.workspace_memberships AS membership
    JOIN neon_auth."user" AS auth_user ON auth_user.id = membership.auth_user_id
    WHERE membership.workspace_id = ${workspaceId}::uuid`;
  await sql`SELECT count(*) FROM public.products WHERE workspace_id = ${workspaceId}::uuid`;

  const member = await sql`SELECT public.update_workspace_membership(
    ${randomUUID()}::uuid, ${workspaceId}::uuid, ${randomUUID()}::uuid,
    'viewer', NULL) AS result`;
  const stage = await sql`SELECT public.create_discipline_stage(
    ${workspaceId}::uuid, ${randomUUID()}::uuid, ${randomUUID()}::uuid,
    ${randomUUID()}::uuid, 'SYN', '#336699', 'Synthetic', 0) AS result`;
  const importResult = await sql`SELECT public.import_initial_schedule(
    ${workspaceId}::uuid, ${randomUUID()}::uuid, ${randomUUID()}::uuid,
    '0', '0', '{}'::jsonb) AS result`;
  const importStatus = importResult[0]?.["result"];
  if (member[0]?.["result"] !== "denied" || stage[0]?.["result"] !== "not_found" ||
      !importStatus || typeof importStatus !== "object" || importStatus.status !== "denied")
    throw new Error("Existing Worker function checks returned unexpected results.");
  process.stdout.write("Existing read and function grants passed without business changes.\n");
} catch {
  process.stderr.write("Existing Worker grant check failed.\n");
  process.exitCode = 1;
}
