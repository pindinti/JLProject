import { readFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const settings = readFileSync(".dev.vars", "utf8");
const line = settings.match(/^DATABASE_URL=(.*)$/m);
if (!line) throw new Error("Local Worker database configuration is missing.");
const connection = new URL(line[1].trim().replace(/^"|"$/g, ""));
if (connection.username !== "jlproject_worker")
  throw new Error("The rollback check requires the limited development Worker role.");
const source = readFileSync("db/verification/phase1d2a-development.sql", "utf8");
const begin = source.indexOf("DO $$");
const end = source.lastIndexOf("$$;");
if (begin < 0 || end < begin) throw new Error("Synthetic verification SQL is malformed.");
const block = source.slice(begin, end + 3);
const sql = neon(connection.toString());

try {
  await sql.transaction([sql.query(block), sql.query("SELECT 1 / 0")]);
  throw new Error("The rollback sentinel was not executed.");
} catch (error) {
  if (error && typeof error === "object" && "code" in error && error.code === "22012")
    process.stdout.write("Synthetic audit assertions passed; the transaction rolled back.\n");
  else {
    process.stderr.write("Synthetic audit assertions failed; the transaction rolled back.\n");
    process.exitCode = 1;
  }
}
