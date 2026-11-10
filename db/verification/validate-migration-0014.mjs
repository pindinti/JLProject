import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stdout } from "node:process";

const migration = readFileSync("db/migrations/0014_working_day_planning.sql", "utf8");
const normalized = migration.replace(/\s+/g, " ");

assert.match(migration, /^BEGIN;\s/);
assert.match(migration, /COMMIT;\s*$/);

const temporaryGrant = normalized.indexOf("GRANT CREATE ON SCHEMA public TO jlproject_date_executor;");
const setExecutor = normalized.indexOf("SET ROLE jlproject_date_executor;");
const firstControlledFunction = normalized.indexOf("CREATE FUNCTION public.change_activity_planning(");
const resetRole = normalized.indexOf("RESET ROLE;");
const temporaryRevoke = normalized.indexOf("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;");
const revokeMembership = normalized.indexOf("REVOKE jlproject_date_executor FROM neondb_owner;");

assert.ok(temporaryGrant >= 0 && temporaryGrant < setExecutor,
  "The migration owner must temporarily grant schema CREATE before switching roles.");
assert.ok(setExecutor < firstControlledFunction,
  "Controlled date-planning functions must be created under the executor role.");
assert.ok(firstControlledFunction < resetRole && resetRole < temporaryRevoke,
  "Schema CREATE must be revoked after resetting from the executor role.");
assert.ok(temporaryRevoke < revokeMembership,
  "Temporary schema CREATE must be revoked before dropping role membership.");
assert.equal((normalized.match(/GRANT CREATE ON SCHEMA public TO jlproject_date_executor;/g) ?? []).length, 1);
assert.equal((normalized.match(/REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;/g) ?? []).length, 1);
assert.match(normalized,
  /has_schema_privilege\('jlproject_date_executor', 'public', 'CREATE'\)/,
  "The final privilege guard must reject a committed executor CREATE grant.");
assert.doesNotMatch(normalized, /GRANT CREATE ON SCHEMA public TO jlproject_worker/);
assert.doesNotMatch(normalized, /GRANT ALL .* TO jlproject_worker/);
assert.match(normalized, /GRANT EXECUTE ON FUNCTION public\.change_activity_planning/);
assert.match(normalized, /GRANT EXECUTE ON FUNCTION public\.create_activity_with_working_plan/);
assert.match(normalized, /has_table_privilege\('jlproject_worker', 'public\.stage_activities', 'INSERT'\)/,
  "The final privilege guard must reject table-wide Worker INSERT.");

stdout.write("Migration 0014 transaction, temporary executor CREATE grant/revoke, and Worker privilege guards validated.\n");
