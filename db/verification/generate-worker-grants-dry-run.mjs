import { readFileSync, writeFileSync } from "node:fs";

const migration = readFileSync("db/migrations/0007_worker_least_privilege.sql", "utf8");
if (!migration.startsWith("BEGIN;") || !/COMMIT;\s*$/.test(migration))
  throw new Error("Worker grants migration must be one reviewed transaction.");
const grants = migration.replace(/^BEGIN;\s*/, "").replace(/\s*COMMIT;\s*$/, "");
writeFileSync("db/role-grants.local.sql", `BEGIN;
CREATE ROLE jlproject_worker LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
${grants}
ROLLBACK;
`);
