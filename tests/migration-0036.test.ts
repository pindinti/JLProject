import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0036_schedule_dependency_storage.sql", "utf8");
const postflight = readFileSync("db/verification/phase4b1-storage-postflight.sql", "utf8");

describe("migration 0036 dependency storage contract", () => {
  it("uses a workspace and product foreign key for each typed endpoint", () => {
    for (const [kind, relation] of [["activity", "stage_activities"], ["stage", "discipline_stages"]]) {
      for (const position of ["predecessor", "successor"]) {
        expect(migration).toContain(`FOREIGN KEY (workspace_id, product_id, ${position}_${kind}_id)`);
      }
      expect(migration.split(`REFERENCES public.${relation} (workspace_id, product_id, id) ON DELETE RESTRICT`)).toHaveLength(3);
      expect(migration).toContain(`predecessor_${kind}_id <> successor_${kind}_id`);
      expect(migration).toContain(`(workspace_id, product_id, predecessor_${kind}_id, successor_${kind}_id)`);
    }
  });

  it("keeps edge storage dormant and leaves the existing baseline and audit writers outside this migration", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("REVOKE ALL ON TABLE public.product_schedule_dependencies FROM PUBLIC, jlproject_worker, jlproject_date_executor");
    expect(migration).not.toMatch(/\b(ALTER TABLE|GRANT|INSERT INTO|UPDATE|DELETE FROM|CREATE FUNCTION|CREATE TRIGGER)\b/i);
    expect(postflight).toContain("BEGIN READ ONLY;");
    expect(postflight).toContain("initial_schedule_revisions_immutable");
  });
});
