import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const match = settings.match(/^DATABASE_URL=(?:"([^"]+)"|([^\r\n]+))$/m);
if (!match) throw new Error("Local Worker database configuration is missing.");

const databaseUrl = new URL(match[1] ?? match[2]);
if (databaseUrl.username !== "jlproject_worker" || databaseUrl.pathname !== "/neondb")
  throw new Error("The rollback test requires the limited JLProject development Worker connection.");

const sql = neon(databaseUrl.toString());
const workspaceRows = await sql`SELECT id::text AS id FROM public.workspaces WHERE name = 'JLProject'`;
if (workspaceRows.length !== 1) throw new Error("Expected the JLProject development workspace.");
const workspaceId = String(workspaceRows[0]["id"]);

const actors = await sql`SELECT auth_user_id::text AS id FROM public.workspace_memberships
  WHERE workspace_id = ${workspaceId}::uuid AND active = true AND role IN ('admin', 'editor')
  ORDER BY (role = 'admin') DESC LIMIT 1`;
const sources = await sql`SELECT id::text AS id FROM public.products
  WHERE workspace_id = ${workspaceId}::uuid AND name LIKE 'Synthetic 1C2 %' AND active = true`;
if (actors.length !== 1 || sources.length !== 1)
  throw new Error("Expected an active writer and one synthetic source product.");

const name = `Synthetic 3A2 worker rollback ${randomUUID()}`;
try {
  await sql.transaction([
    sql`SELECT public.clone_product(${workspaceId}::uuid, ${String(sources[0]["id"])}::uuid,
      ${String(actors[0]["id"])}::uuid, ${name}) AS result`,
    sql`SELECT 1 / 0 AS force_rollback`
  ]);
  throw new Error("The intentional rollback statement unexpectedly succeeded.");
} catch (error) {
  const code = typeof error === "object" && error !== null && "code" in error &&
    typeof error.code === "string" && /^[0-9A-Z]{5}$/.test(error.code) ? error.code : "unavailable";
  const message = typeof error === "object" && error !== null && "message" in error &&
    typeof error.message === "string" ? error.message : "";
  const relation = message.match(/permission denied (?:for|to lock) (?:table|relation) ([a-z_.]+)/i)?.[1];
  if (code !== "22012")
    throw new Error(`The clone did not reach the intentional rollback assertion (SQLSTATE ${code}${relation ? `, relation ${relation}` : ""}).`);
}

const residue = await sql`SELECT count(*)::int AS count FROM public.products
  WHERE workspace_id = ${workspaceId}::uuid AND name = ${name}`;
if (Number(residue[0]?.["count"]) !== 0)
  throw new Error("The failed clone left a product row behind.");

process.stdout.write("Limited Worker clone reached the forced failure; transaction rollback left no product row.\n");
