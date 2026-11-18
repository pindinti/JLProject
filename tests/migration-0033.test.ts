import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const earlier = readFileSync("db/migrations/0030_multi_entity_audit_grouping.sql", "utf8");
const history = readFileSync("db/migrations/0032_unified_living_schedule_change_history.sql", "utf8");
const correction = readFileSync("db/migrations/0033_product_import_provenance_compatibility.sql", "utf8");

function quotedSources(sql: string): Set<string> {
  return new Set([...sql.matchAll(/'([a-z_]+)'/g)].map((match) => match[1]!));
}

describe("migration 0033 provenance source compatibility", () => {
  it("permits every emitted provenance source and preserves the seven prior source types", () => {
    const priorCheck = earlier.match(/source_ledger text NOT NULL CHECK \(source_ledger IN \(([\s\S]*?)\)\)/)?.[1];
    const newCheck = correction.match(/ADD CONSTRAINT product_schedule_operation_source_events_source_ledger_check\s+CHECK \(source_ledger IN \(([\s\S]*?)\)\)/)?.[1];
    expect(priorCheck).toBeDefined();
    expect(newCheck).toBeDefined();
    const prior = quotedSources(priorCheck!);
    const allowed = quotedSources(newCheck!);
    const emitted = new Set([...history.matchAll(/v_source_ledger := '([a-z_]+)'/g)]
      .map((match) => match[1]!));
    expect(emitted).toEqual(new Set(["products", "import_batches"]));
    expect(allowed).toEqual(new Set([...prior, ...emitted]));
    for (const source of emitted) {
      expect(history).toContain("source.source_ledger = '" + source + "'");
      expect(history).toContain("v_source_ledger := '" + source + "'");
    }
  });

  it("changes only the owned constraint inside a guarded transaction", () => {
    expect(correction).toMatch(/^BEGIN;\s/);
    expect(correction).toMatch(/COMMIT;\s*$/);
    expect(correction).toContain("current_database() <> 'neondb'");
    expect(correction).toContain("current_user <> 'neondb_owner'");
    expect(correction).toContain("SET ROLE jlproject_date_executor");
    expect(correction).toContain("RESET ROLE");
    expect(correction).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
    expect(correction).toContain("product_schedule_operation_source_events_append_only");
    expect(correction).not.toMatch(/\b(UPDATE|DELETE|INSERT INTO|TRUNCATE)\s+public\./i);
    expect(correction).not.toContain("jlproject_worker TO");
  });
});
