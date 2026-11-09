import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const pending = readFileSync(".dev.vars.worker-pending", "utf8");
const match = pending.match(/^DATABASE_URL=(.*)$/m);
if (!match) throw new Error("Pending Worker database configuration is missing.");
const connection = new URL(match[1].trim().replace(/^"|"$/g, ""));
if (connection.username !== "jlproject_worker")
  throw new Error("The pending connection is not the limited Worker role.");
const sql = neon(connection.toString());

try {
  const rows = await sql`SELECT current_user AS role, current_database() AS database,
    has_function_privilege(current_user,
      'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)',
      'execute') AS "canChangeDates",
    has_table_privilege(current_user, 'public.activity_date_changes', 'select') AS "canReadAudit",
    has_table_privilege(current_user, 'public.activity_date_changes', 'insert') AS "canInsertAudit",
    has_column_privilege(current_user, 'public.stage_activities', 'planned_start', 'update')
      AS "canDirectlyUpdateDates"`;
  const state = rows[0];
  if (state?.["role"] !== "jlproject_worker" || state["database"] !== "neondb" ||
      state["canChangeDates"] !== true || state["canReadAudit"] !== true ||
      state["canInsertAudit"] !== false || state["canDirectlyUpdateDates"] !== false)
    throw new Error("Limited Worker privileges do not match the reviewed policy.");
  await sql`SELECT 1 FROM public.products LIMIT 0`;
  await sql`SELECT id, name, email FROM neon_auth."user" LIMIT 0`;
  writeFileSync(".dev.vars", pending, { mode: 0o600 });
  unlinkSync(".dev.vars.worker-pending");
  process.stdout.write("Activated the verified limited Worker connection in ignored local configuration.\n");
} catch {
  process.stderr.write("Limited Worker activation failed; the existing local configuration was retained.\n");
  process.exitCode = 1;
}
