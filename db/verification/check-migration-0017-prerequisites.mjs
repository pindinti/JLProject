import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stdout } from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const match = settings.match(/^DATABASE_URL=(?:"([^"]+)"|([^\r\n]+))$/m);
assert.ok(match, "The ignored local Worker database configuration is required.");
const url = new URL(match[1] ?? match[2]);
assert.equal(url.username, "jlproject_worker", "Read-only audit must use the limited Worker role.");
const sql = neon(url.toString());
const rows = await sql`SELECT current_database() AS database_name, current_user AS role_name,
  to_regclass('public.calendar_reschedule_changes') IS NULL AS migration_absent,
  to_regprocedure('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)') IS NULL AS function_absent,
  (SELECT rolcanlogin = false FROM pg_roles WHERE rolname = 'jlproject_date_executor') AS executor_nologin,
  has_table_privilege('jlproject_date_executor', 'public.workspaces', 'SELECT') AS workspaces_read,
  has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') AS membership_read,
  has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') AS product_read,
  has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') AS activity_read,
  has_table_privilege('jlproject_date_executor', 'public.workspace_calendar_versions', 'SELECT') AS calendar_version_read,
  has_function_privilege('jlproject_date_executor',
    'public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)',
    'EXECUTE') AS planning_execute,
  has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') = false AS no_executor_create,
  pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') = false AS no_worker_membership,
  has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') = false AS no_direct_date_write,
  has_table_privilege('jlproject_worker', 'public.activity_date_changes', 'INSERT') = false AS no_direct_audit_write`;
const row = rows[0];
assert.equal(row?.["database_name"], "neondb");
assert.equal(row?.["role_name"], "jlproject_worker");
const checks = Object.entries(row ?? {}).filter(([key]) => !["database_name", "role_name"].includes(key));
for (const [name, passed] of checks) assert.equal(passed, true, `Missing migration prerequisite: ${name}`);
stdout.write(`Migration 0017 read-only privilege audit passed (${checks.length} checks).\n`);
