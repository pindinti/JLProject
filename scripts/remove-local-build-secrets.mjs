import { readdir, unlink } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, URL } from "node:url";

const workerOutput = fileURLToPath(new URL("../dist/worker/", import.meta.url));

for (const entry of await readdir(workerOutput, { withFileTypes: true })) {
  if (entry.isFile() && (entry.name === ".dev.vars" || entry.name.startsWith(".dev.vars."))) {
    await unlink(join(workerOutput, entry.name));
  }
}
