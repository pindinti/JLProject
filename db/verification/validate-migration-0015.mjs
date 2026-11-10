import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stdout } from "node:process";

const source = readFileSync("db/migrations/0015_date_executor_calendar_read.sql", "utf8");
const normalized = source.replace(/--[^\r\n]*/g, "").replace(/\s+/g, " ").trim();

assert.match(normalized, /^BEGIN; /);
assert.match(normalized, / COMMIT;$/);
assert.equal((normalized.match(/GRANT SELECT ON public\.workspace_calendar_versions TO jlproject_date_executor;/g) ?? []).length, 1);
assert.equal((normalized.match(/GRANT jlproject_calendar_executor TO neondb_owner;/g) ?? []).length, 1);
assert.equal((normalized.match(/REVOKE jlproject_calendar_executor FROM neondb_owner;/g) ?? []).length, 1);
assert.ok(
  normalized.indexOf("GRANT jlproject_calendar_executor TO neondb_owner;") <
    normalized.indexOf("SET ROLE jlproject_calendar_executor;"),
  "Temporary ownership membership must precede SET ROLE.",
);
assert.ok(
  normalized.indexOf("RESET ROLE;") <
    normalized.indexOf("REVOKE jlproject_calendar_executor FROM neondb_owner;"),
  "Temporary ownership membership must be revoked after RESET ROLE.",
);
assert.doesNotMatch(normalized, /GRANT (?:INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER|ALL)/);
assert.doesNotMatch(normalized, /GRANT .* TO jlproject_worker/);
assert.match(normalized, /rolname = 'jlproject_date_executor' AND rolcanlogin = true/);
assert.match(normalized, /pg_has_role\('neondb_owner', 'jlproject_calendar_executor', 'usage'\)/);
assert.match(normalized, /pg_has_role\('jlproject_worker', 'jlproject_date_executor', 'member'\)/);

stdout.write("Migration 0015 grants only calendar-version SELECT and removes temporary ownership membership.\n");
