import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0026_hierarchy_movement.sql", "utf8");
const verification = readFileSync(
  "db/verification/phase3a7a-hierarchy-movement-development-worker.sql", "utf8"
);

describe("migration 0026 hierarchy movement", () => {
  it("is transactional, unapplied, and anchored to the reviewed role and schema state", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("Hierarchy movement migration prerequisites");
    expect(migration).toContain("jlproject_worker");
    expect(migration).toContain("jlproject_date_executor");
  });

  it("preserves historical date parents while enabling atomic stage ancestry changes", () => {
    expect(migration).toMatch(/GRANT jlproject_date_executor TO neondb_owner\s+WITH INHERIT FALSE, SET TRUE;\s+SET ROLE jlproject_date_executor;\s+ALTER TABLE public\.activity_date_changes[\s\S]*?RESET ROLE;/);
    expect(migration).toContain("DROP CONSTRAINT activity_date_changes_activity_fk");
    expect(migration).toContain("activity_date_changes_product_scope_fk");
    expect(migration).toMatch(/stage_activities_parent_fk[\s\S]*?DEFERRABLE INITIALLY IMMEDIATE/);
    expect(migration).toContain("SET CONSTRAINTS public.stage_activities_parent_fk DEFERRED");
    expect(migration).toContain("UPDATE public.stage_activities SET discipline_id = p_destination_discipline_id");
  });

  it("uses one authorized version-checked operation and an append-only movement ledger", () => {
    expect(migration).toContain("CREATE TABLE public.hierarchy_movement_events");
    expect(migration).toContain("CREATE FUNCTION public.move_schedule_item");
    expect(migration).toContain("role IN ('admin', 'editor')");
    expect(migration).toContain("v_version <> p_expected_version");
    expect(migration).toContain("v_source_before <> p_expected_source_order");
    expect(migration).toContain("v_destination_before <> p_expected_destination_order");
    expect(migration).toContain("Hierarchy movement audit is append-only.");
    expect(migration).toContain("original_discipline_id");
    expect(migration).toContain("destination_order_after");
    expect(migration).toContain("descendant_activity_ids");
  });

  it("closes direct ordering bypasses without granting parent updates to the Worker", () => {
    for (const table of ["product_disciplines", "discipline_stages", "stage_activities"])
      expect(migration).toContain(`REVOKE UPDATE (display_order) ON public.${table} FROM jlproject_worker`);
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'discipline_id', 'UPDATE')");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'UPDATE')");
    expect(migration).not.toMatch(/UPDATE\s+public\.initial_schedule_revisions/i);
    expect(migration).not.toMatch(/INSERT\s+INTO\s+public\.initial_schedule_revisions/i);
    expect(migration).toMatch(/REVOKE ALL ON FUNCTION public\.move_schedule_item[\s\S]*?GRANT EXECUTE ON FUNCTION public\.move_schedule_item[\s\S]*?RESET ROLE;/);
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
    expect(migration).toContain("count(*) <> 1 OR NOT bool_and(membership.admin_option");
  });

  it("prepares rollback-only synthetic coverage", () => {
    expect(verification).toMatch(/^--[\s\S]*?\nBEGIN;\s/);
    expect(verification).toMatch(/ROLLBACK;\s*$/);
    for (const expected of [
      "valid activity reorder", "root-to-stage movement", "stage movement",
      "Stage reorder", "workspace outside the actor's membership", "discipline reorder", "stale version", "sibling-order conflict",
      "viewer permission", "immutable movement audit", "R00 fingerprint",
      "planned date fingerprint", "forced audit failure",
      "destination stage color", "product-root fallback", "changed_at IS NULL",
      "WITH INHERIT FALSE, SET TRUE",
      "REVOKE jlproject_worker FROM neondb_owner GRANTED BY neondb_owner",
      "Temporary role options were not restored before rollback"
    ]) expect(verification).toContain(expected);
  });
});
