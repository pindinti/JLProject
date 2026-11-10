import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import process from "node:process";

const source = readFileSync("db/migrations/0010_shared_stage_definition_color.sql", "utf8")
  .replace(/\r\n/g, "\n");
assert.match(source, /^BEGIN;\s*DO \$\$/);
assert.match(source, /COMMIT;\s*$/);

const body = source.replace(/^BEGIN;\s*/i, "").replace(/\s*COMMIT;\s*$/i, "").trim();
const doStart = body.indexOf("DO $$");
const doEnd = body.indexOf("$$;", doStart) + 3;
assert.equal(doStart, 0, "Expected the role guard to be the first migration statement.");
assert.ok(doEnd > 2, "Expected one complete role guard DO block.");

const guard = body.slice(doStart, doEnd);
let grant = body.slice(doEnd).trimStart();
while (grant.startsWith("--")) {
  const lineEnd = grant.indexOf("\n");
  grant = lineEnd < 0 ? "" : grant.slice(lineEnd + 1).trimStart();
}
const normalizedGrant = grant.replace(/\s+/g, " ").trim();
const expectedGrant = "GRANT UPDATE (color) ON public.stage_definitions TO jlproject_worker;";

assert.doesNotMatch(guard, /\b(?:ALTER|INSERT|UPDATE|DELETE|DROP|CREATE)\b/i,
  "The role guard must not contain data or schema mutations.");
assert.equal(normalizedGrant, expectedGrant,
  "The migration may grant only UPDATE(color) on stage_definitions to jlproject_worker.");

process.stdout.write(`Validated role guard:\n${guard}\nValidated grant:\n${expectedGrant}\n`);
