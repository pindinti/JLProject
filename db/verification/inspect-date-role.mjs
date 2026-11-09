import { readFileSync } from "node:fs";
import process from "node:process";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const line = settings.split(/\r?\n/).find((value) => value.startsWith("DATABASE_URL="));
if (!line) throw new Error("Worker database configuration is missing.");
const connection = line.slice("DATABASE_URL=".length).trim().replace(/^"|"$/g, "");
const sql = neon(connection);
const rows = await sql`SELECT current_user AS role, rolcreaterole AS "canCreateRole",
  rolsuper AS "isSuperuser", to_regrole('jlproject_date_executor') IS NOT NULL AS "executorExists",
  to_regrole('jlproject_worker') IS NOT NULL AS "workerExists",
  to_regclass('public.activity_date_changes') IS NOT NULL AS "auditTableExists",
  pg_has_role(current_user, 'jlproject_date_executor', 'usage') AS "canUseExecutor",
  pg_has_role(current_user, 'jlproject_date_executor', 'set') AS "canSetExecutor",
  has_function_privilege(current_user,
    'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)',
    'execute') AS "canExecuteDateChange",
  has_table_privilege(current_user, 'public.activity_date_changes', 'select') AS "canReadAudit",
  has_table_privilege(current_user, 'public.activity_date_changes', 'insert') AS "canInsertAudit"
  FROM pg_roles WHERE rolname = current_user`;
const row = rows[0];
if (!row) throw new Error("Database role lookup failed.");
process.stdout.write(JSON.stringify({ role: row["role"], canCreateRole: row["canCreateRole"],
  isSuperuser: row["isSuperuser"], executorExists: row["executorExists"],
  workerExists: row["workerExists"],
  auditTableExists: row["auditTableExists"], canUseExecutor: row["canUseExecutor"],
  canSetExecutor: row["canSetExecutor"], canExecuteDateChange: row["canExecuteDateChange"],
  canReadAudit: row["canReadAudit"], canInsertAudit: row["canInsertAudit"] }));
