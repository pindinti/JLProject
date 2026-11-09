import { randomBytes } from "node:crypto";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const source = readFileSync(".dev.vars", "utf8");
const match = source.match(/^DATABASE_URL=(.*)$/m);
if (!match) throw new Error("Local Worker database configuration is missing.");
const existing = new URL(match[1].trim().replace(/^"|"$/g, ""));
if (existing.username !== "neondb_owner")
  throw new Error("The local Worker must still use the reviewed development owner connection.");
const sql = neon(existing.toString());

try {
  const state = await sql`SELECT current_user AS role, current_database() AS database,
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker') AS "roleExists"`;
  if (state[0]?.["role"] !== "neondb_owner" || state[0]?.["database"] !== "neondb" ||
      state[0]?.["roleExists"] !== false)
    throw new Error("The development role state is not ready for provisioning.");

  const password = randomBytes(32).toString("hex");
  const next = new URL(existing);
  next.username = "jlproject_worker";
  next.password = password;
  const updated = source.replace(/^DATABASE_URL=.*$/m, `DATABASE_URL="${next.toString()}"`);
  writeFileSync(".dev.vars.worker-pending", updated, { mode: 0o600, flag: "wx" });
  try {
    await sql.query(`CREATE ROLE jlproject_worker LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '${password}'`);
  } catch (error) {
    unlinkSync(".dev.vars.worker-pending");
    throw error;
  }
  process.stdout.write("Created the limited development role and an ignored pending Worker configuration.\n");
} catch {
  process.stderr.write("Worker role preparation failed; inspect role existence before retrying.\n");
  process.exitCode = 1;
}
