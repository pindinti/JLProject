import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const match = settings.match(/^DATABASE_URL=(?:"([^"]+)"|([^\r\n]+))$/m);
if (!match) throw new Error("Local Worker database configuration is missing.");
const databaseUrl = new URL(match[1] ?? match[2]);
if (databaseUrl.username !== "jlproject_worker" || databaseUrl.pathname !== "/neondb")
  throw new Error("The check requires the limited development Worker connection.");

const sql = neon(databaseUrl.toString());
const connection = await sql`SELECT current_user AS role, current_database() AS database`;
if (connection[0]?.["role"] !== "jlproject_worker" || connection[0]?.["database"] !== "neondb")
  throw new Error("Unexpected database role or database.");

const workspaces = await sql`SELECT id::text AS id FROM public.workspaces WHERE name = 'JLProject'`;
if (workspaces.length !== 1) throw new Error("Expected one JLProject development workspace.");
const workspaceId = String(workspaces[0]["id"]);
const admins = await sql`SELECT auth_user_id::text AS id FROM public.workspace_memberships
  WHERE workspace_id = ${workspaceId}::uuid AND role = 'admin' AND active = true`;
if (admins.length < 1) throw new Error("Expected an active development administrator.");
const actorId = String(admins[0]["id"]);

const privileges = await sql`SELECT
  has_function_privilege(current_user,
    'public.change_workspace_calendar(uuid,uuid,uuid,bigint,text,uuid,text,text,text,text,date,date)',
    'execute') AS execute_allowed,
  has_function_privilege('public',
    'public.change_workspace_calendar(uuid,uuid,uuid,bigint,text,uuid,text,text,text,text,date,date)',
    'execute') AS public_execute,
  has_table_privilege(current_user, 'public.workspace_calendar_versions', 'select') AS version_read,
  has_table_privilege(current_user, 'public.workspace_calendar_exceptions', 'select') AS exception_read,
  has_table_privilege(current_user, 'public.workspace_calendar_events', 'select') AS event_read,
  has_table_privilege(current_user, 'public.workspace_calendar_versions', 'insert') AS version_insert,
  has_table_privilege(current_user, 'public.workspace_calendar_versions', 'update') AS version_update,
  has_table_privilege(current_user, 'public.workspace_calendar_exceptions', 'insert') AS exception_insert,
  has_table_privilege(current_user, 'public.workspace_calendar_exceptions', 'update') AS exception_update,
  has_table_privilege(current_user, 'public.workspace_calendar_exceptions', 'delete') AS exception_delete,
  has_table_privilege(current_user, 'public.workspace_calendar_events', 'insert') AS event_insert,
  has_table_privilege(current_user, 'public.workspace_calendar_events', 'update') AS event_update,
  has_table_privilege(current_user, 'public.workspace_calendar_events', 'delete') AS event_delete,
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.workspace_calendar_events'::regclass
    AND tgname = 'workspace_calendar_events_append_only' AND tgenabled = 'O') AS audit_trigger_enabled`;
const grants = privileges[0];
const readAllowed = grants["execute_allowed"] && grants["version_read"] &&
  grants["exception_read"] && grants["event_read"] && grants["audit_trigger_enabled"];
const directWritesDenied = !grants["public_execute"] && !grants["version_insert"] &&
  !grants["version_update"] && !grants["exception_insert"] && !grants["exception_update"] &&
  !grants["exception_delete"] && !grants["event_insert"] && !grants["event_update"] &&
  !grants["event_delete"];
if (!readAllowed || !directWritesDenied) throw new Error("Unexpected calendar privileges or audit trigger state.");

const versions = await sql`SELECT version FROM public.workspace_calendar_versions
  WHERE workspace_id = ${workspaceId}::uuid`;
const currentVersion = Number(versions[0]?.["version"] ?? 0);
const operationId = randomUUID();
const name = `Synthetic calendar rollback ${randomUUID()}`;
try {
  await sql.transaction([
    sql`SELECT public.change_workspace_calendar(
      ${workspaceId}::uuid, ${actorId}::uuid, ${operationId}::uuid, ${currentVersion}::bigint,
      'create', NULL::uuid, 'municipal_holiday', ${name}, 'Synthetic Municipality',
      NULL::text, DATE '2099-04-15', DATE '2099-04-15') AS result`,
    sql`SELECT 1 / 0 AS force_rollback`
  ]);
  throw new Error("The forced rollback unexpectedly succeeded.");
} catch (error) {
  const code = typeof error === "object" && error !== null && "code" in error ? error.code : null;
  if (code !== "22012") throw new Error(`Calendar write did not reach forced rollback (SQLSTATE ${String(code)}).`);
}

const residue = await sql`SELECT
  (SELECT count(*)::int FROM public.workspace_calendar_exceptions
    WHERE workspace_id = ${workspaceId}::uuid AND name = ${name}) AS exceptions,
  (SELECT count(*)::int FROM public.workspace_calendar_events
    WHERE operation_id = ${operationId}::uuid) AS events,
  (SELECT COALESCE(max(version), 0)::bigint FROM public.workspace_calendar_versions
    WHERE workspace_id = ${workspaceId}::uuid) AS version`;
if (Number(residue[0]?.["exceptions"]) !== 0 || Number(residue[0]?.["events"]) !== 0 ||
    Number(residue[0]?.["version"]) !== currentVersion)
  throw new Error("The forced rollback left calendar changes behind.");

process.stdout.write("Calendar grants and audit trigger verified; limited-Worker write rolled back without residue.\n");
