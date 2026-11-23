import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (name: string) => readFileSync("db/verification/" + name, "utf8");
type Fixture = {
  role: string;
  inputs: string[];
  exports?: { prefix: string; names: string[] }[];
  records?: string[];
};
const { fixtures } = JSON.parse(read("phase4b5-handoff-manifest.json")) as {
  fixtures: Record<string, Fixture>;
};
const names = (fixture: Fixture) => fixture.exports?.flatMap((output) => output.names) ?? [];

// Audit the psql binding conventions used by these fixtures, including includes in the same session.
function externalBindings(file: string, defined = new Set<string>(), required = new Set<string>()) {
  let query = "";
  for (const source of read(file).split(/\r?\n/)) {
    const line = source.trim();
    if (line.startsWith("--")) continue;
    const include = /^\\i db\/verification\/(\S+)$/.exec(line);
    if (include) {
      externalBindings(include[1], defined, required);
      continue;
    }
    const references = line.startsWith("\\") ? /(?<!:):(?:\{\?)?'?([a-z]\w*)/gi : /:'([a-z]\w*)'/gi;
    for (const [, variable] of line.matchAll(references)) {
      if (!defined.has(variable)) required.add(variable);
    }
    const assignment = /^\\set\s+(\w+)/.exec(line);
    if (assignment) defined.add(assignment[1]);
    if (!line.startsWith("\\")) query += "\n" + line;
    if (/\\gset(?:\s|$)/.test(line)) {
      for (const [, alias] of query.matchAll(/\bAS\s+(\w+)/gi)) defined.add(alias);
      query = "";
    } else if (line.endsWith(";")) {
      query = "";
    }
  }
  return required;
}

describe("Phase 4B.5 variable handoff", () => {
  it.each(Object.entries(fixtures))("declares the exact external bindings for %s", (file, fixture) => {
    expect(new Set(fixture.inputs)).toEqual(externalBindings(file));
  });

  it("matches the declared seed output and exact names", () => {
    for (const [file, fixture] of Object.entries(fixtures)) {
      expect(new Set(fixture.inputs).size, file).toBe(fixture.inputs.length);
      for (const output of fixture.exports ?? []) {
        const lines = read(file).split(/\r?\n/).filter((line) => line.startsWith("\\echo " + output.prefix));
        expect(lines, file).toHaveLength(1);
        expect([...lines[0].matchAll(/([a-z_0-9]+)=:/g)].map((match) => match[1]), file).toEqual(output.names);
      }
    }
  });

  it.each([
    "phase4b3c1-activity-creation",
    "phase4b3c2-hierarchy-move",
    "phase4b3c3-schedule-deletion",
  ])("covers the external seed and runtime inputs for %s", (base) => {
    const owner = fixtures[base + "-seed-owner.sql"];
    const worker = fixtures[base + "-seed-worker-stage-dates.sql"];
    const edgeFile = base + "-seed-owner-dependencies.sql";
    const ownerKeys = [...owner.inputs, ...names(owner)];
    const stageKeys = [...ownerKeys, ...names(worker)];
    expect(ownerKeys).toEqual(expect.arrayContaining(worker.inputs));
    const stageReferences = [...read(base + "-seed-worker-stage-dates.sql")
      .matchAll(/:'([a-z0-9_]+)'/g)].map((match) => match[1]);
    expect([...worker.inputs, ...names(worker)]).toEqual(expect.arrayContaining(stageReferences));
    const consumers = [edgeFile, base + ".sql"];
    if (base === "phase4b3c2-hierarchy-move") consumers.push(base + "-postflight-owner.sql");
    for (const file of consumers) {
      expect(stageKeys).toEqual(expect.arrayContaining(fixtures[file].inputs));
      const external = [...read(file).matchAll(/:'([a-z0-9_]+)'|^\\set \w+ :([a-z0-9_]+)/gm)]
        .map((match) => match[1] ?? match[2]);
      expect(fixtures[file].inputs).toEqual(expect.arrayContaining(external));
    }
  });

  it("checks the exact committed hierarchy graph and audit versions in a read-only SQL file", () => {
    const file = "phase4b3c2-hierarchy-move-postflight-owner.sql";
    const postflight = read(file);
    expect(fixtures[file]).toMatchObject({ role: "neondb_owner", readOnly: true });
    expect(new Set(fixtures[file].inputs)).toEqual(new Set([...postflight.matchAll(/:'([a-z0-9_]+)'/g)].map((match) => match[1])));
    expect(postflight).toContain("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;");
    expect([...postflight.matchAll(/jsonb_build_array\(\d, (\d), :'test_\w+_product'/g)].map((match) => Number(match[1])))
      .toEqual([2, 3, 2, 5, 6, 2]);
    for (const check of [
      "endpoint_kind = 'stage' AND predecessor_stage_id = v_edge.predecessor",
      "successor_stage_id = v_edge.successor",
      "event.change_type = 'dependency_added'",
      "event.new_values = v_event_values",
      "operation.schedule_version = v_edge.version AND operation.operation_id = v_edge.operation_id",
      "state.history_watermark = (SELECT max(event_id)",
      "stage.planned_start IS NULL AND stage.planned_end IS NULL",
      "v_start IS DISTINCT FROM DATE '2026-11-03' OR v_finish IS DISTINCT FROM DATE '2026-11-05'",
      "FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace) <> 6",
      "FROM public.product_schedule_operations WHERE workspace_id = v_workspace) <> 14",
      "ROLLBACK;",
    ]) expect(postflight).toContain(check);
    expect(postflight).not.toMatch(/^\s*(?:grant|revoke|insert|update|delete|alter)\b/im);
    const runner = read("phase4b5-run-fixture.ps1");
    expect(runner).toContain("$env:DEBUG = $null");
    expect(runner).toContain("exit $status");
    expect(runner).not.toContain("$output | Where-Object");
  });

  it("resolves every 0043 owner variable and inserts the collision activity it hands to Worker", () => {
    const owner = read("phase4b3c3-schedule-deletion-seed-owner.sql");
    const identity = read("phase4b5-seed-auth-identities-owner.sql");
    const [declarations, structuralSeed, handoff] = owner.split("\\gset");
    const aliases = (sql: string) => [...sql.matchAll(/\bAS (\w+)/gi)].map((match) => match[1]);
    const structuralNames = new Set([...aliases(declarations), ...aliases(identity)]);
    for (const [, name] of structuralSeed.matchAll(/:'(\w+)'/g)) {
      expect(structuralNames.has(name), name).toBe(true);
    }
    const handoffNames = new Set([...structuralNames, ...aliases(structuralSeed)]);
    for (const [, name] of handoff.matchAll(/(?<!:):(\w+)/g)) {
      expect(handoffNames.has(name), name).toBe(true);
    }
    const collisionId = /md5\('jlproject\.phase4b3c3\.collision_activity'\)::uuid AS (\w+)/.exec(declarations)?.[1];
    expect(collisionId).toBe("test_collision_activity");
    expect(structuralSeed).toContain("(:'" + collisionId + "', :'test_workspace', :'test_empty_product', NULL, NULL, 'Committed collision history target'");
    expect(handoff).toContain("test_collision_activity=:" + collisionId);
  });

  it("passes the collision owner baseline through the manifest with exact types and inputs", () => {
    const base = "phase4b3c3-schedule-deletion";
    const owner = fixtures[base + "-seed-owner.sql"];
    const state = read(base + "-collision-state-owner.sql");
    const pre = base + "-collision-preflight-owner.sql";
    const post = base + "-collision-postflight-owner.sql";
    const worker = base + "-seed-worker.sql";
    expect(names(owner)).toEqual(expect.arrayContaining(fixtures[pre].inputs));
    const producerValues = [...names(owner), ...names(fixtures[pre])];
    for (const file of [pre, worker, post]) {
      const source = file === worker ? read(file) : state + read(file);
      const required = [...new Set([...source.matchAll(/:'(test_\w+)'/g)].map((match) => match[1]))];
      expect(new Set(fixtures[file].inputs)).toEqual(new Set(required));
      expect(producerValues).toEqual(expect.arrayContaining(fixtures[file].inputs));
    }
    for (const file of [pre, post]) {
      expect(fixtures[file]).toMatchObject({ role: "neondb_owner", readOnly: true });
    }
  });

  it("matches the clone handoff to actual SQL arguments", () => {
    const base = "phase4b3c4-clone";
    const bootstrap = fixtures[base + "-seed-owner.sql"];
    const edgeFile = base + "-seed-owner-dependencies.sql";
    const preflight = fixtures[base + "-preflight-owner.sql"];
    const worker = fixtures[base + "-dependencies.sql"];
    const postflight = fixtures[base + "-postflight-owner.sql"];
    const available = [...bootstrap.inputs, ...names(bootstrap)];
    for (const suffix of ["-seed-worker-import", "-seed-worker-schedule", "-seed-worker-status", "-seed-owner-dependencies"]) {
      expect(available, suffix).toEqual(expect.arrayContaining(fixtures[base + suffix + ".sql"].inputs));
    }
    const edgeValues = names(fixtures[edgeFile]);
    expect(edgeValues).toEqual(expect.arrayContaining(preflight.inputs));
    expect(preflight.records).toEqual(["SOURCE_FINGERPRINT", "HISTORICAL_R00_BASELINE", "ROOT_EDGE"]);
    expect(worker.inputs).toEqual(expect.arrayContaining(preflight.inputs));
    expect([...edgeValues, "missing_target_name", "root_edge_predecessor", "root_edge_successor"])
      .toEqual(expect.arrayContaining(worker.inputs));
    const cases = ["vigente", "study", "archived", "empty"];
    expect(worker.records).toEqual(["CLONE_RESULT", "MISSING_REMAP_TARGET"]);
    expect([...read(base + "-dependencies.sql").matchAll(/NOTICE 'CLONE_RESULT\|(\w+)\|/g)].map((match) => match[1]))
      .toEqual(cases);
    const recordValues = cases.flatMap((key) => [key + "_fingerprint", key + "_clone", key + "_revision"]);
    expect([...edgeValues, ...recordValues, "missing_target_id"]).toEqual(expect.arrayContaining(postflight.inputs));
    for (const suffix of ["-preflight-owner", "-dependencies", "-postflight-owner"]) {
      const file = base + suffix + ".sql";
      const refs = [...new Set([...read(file).matchAll(/:'([a-z0-9_]+)'/g)].map((match) => match[1]))];
      expect(fixtures[file].inputs).toEqual(refs);
    }
  });

  it("verifies the approved historical R00 fingerprint from a read-only file", () => {
    const file = "phase4b5-historical-r00.sql";
    expect(fixtures[file]).toMatchObject({ role: "neondb_owner", readOnly: true, inputs: ["excluded_clone_workspace"] });
    expect(read("phase4b5-run-fixture.ps1")).toContain("@('-f',");
    const sql = read(file);
    expect(sql).toContain("BEGIN READ ONLY;");
    expect(sql).toContain("ORDER BY r.id");
    expect(sql).toContain("WHERE r.workspace_id IS DISTINCT FROM v_excluded");
    expect(sql).toContain("v_count <> 6 OR v_fingerprint IS DISTINCT FROM '9b6daa6196b11b3bee428a1d96fcd1c1'");
    expect(sql).toContain("RAISE EXCEPTION");
    expect(sql.trimEnd().endsWith("ROLLBACK;")).toBe(true);
  });
});
