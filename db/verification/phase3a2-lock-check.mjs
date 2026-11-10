import { readFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const match = settings.match(/^DATABASE_URL=(?:"([^"]+)"|([^\r\n]+))$/m);
if (!match) throw new Error("Local Worker database configuration is missing.");
const url = new URL(match[1] ?? match[2]);
if (url.username !== "jlproject_worker") throw new Error("The lock check requires the limited Worker role.");
const sql = neon(url.toString());

async function check(label, statements, successCode = "22012") {
  try {
    await sql.transaction(statements);
    process.stdout.write(`${label}=completed\n`);
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error &&
      typeof error.code === "string" && /^[0-9A-Z]{5}$/.test(error.code) ? error.code : "unavailable";
    process.stdout.write(`${label}=${code === successCode ? "allowed" : code}\n`);
  }
}

await check("tableShareLock", [sql`LOCK TABLE public.products IN SHARE MODE`], "completed");
await check("productRowLock", [sql`SELECT id FROM public.products LIMIT 1 FOR UPDATE`, sql`SELECT 1 / 0`]);
await check("workspaceRowLock", [sql`SELECT id FROM public.workspaces LIMIT 1 FOR UPDATE`, sql`SELECT 1 / 0`]);
await check("membershipShareLock", [sql`SELECT auth_user_id FROM public.workspace_memberships LIMIT 1 FOR SHARE`, sql`SELECT 1 / 0`]);
