import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0028_stage_date_planning_audit.sql", "utf8");

describe("migration 0028 independent stage dates", () => {
  it("is additive, transactional, numbered after 0027, and fails closed on schema or role drift", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("migration prerequisites differ from the reviewed Development schema through migration 0027");
    expect(migration).toMatch(/ADD COLUMN planned_start date/);
    expect(migration).toMatch(/ADD COLUMN planned_end date/);
    expect(migration).toContain("discipline_stages_planned_dates_check");
    expect(migration).not.toMatch(/^\s*(DROP\s+(TABLE|COLUMN|CONSTRAINT)|TRUNCATE\s)/im);
    expect(migration).not.toMatch(/(?:UPDATE|DELETE)\s+public\.initial_schedule_revisions/i);
  });

  it("uses a single authorized, version-checked operation with an append-only atomic audit", () => {
    expect(migration).toContain("CREATE TABLE public.stage_date_changes");
    for (const field of ["operation_id", "workspace_id", "product_id", "stage_id", "discipline_id",
      "actor_id", "changed_at", "previous_start", "previous_end", "new_start", "new_end",
      "reason", "version_before", "version_after"])
      expect(migration).toMatch(new RegExp(`\\b${field}\\b`));
    expect(migration).toContain("Stage date history is append-only.");
    expect(migration).toContain("CREATE FUNCTION public.change_discipline_stage_dates(");
    expect(migration).toContain("role IN ('admin', 'editor') FOR SHARE");
    expect(migration).toContain("FOR UPDATE OF stage");
    expect(migration).toContain("v_stage.version <> p_expected_version");
    expect(migration).toContain("SET planned_start = p_start, planned_end = p_end, version = version + 1");
    expect(migration).toContain("INSERT INTO public.stage_date_changes");
    expect(migration).toContain("current_user <> 'jlproject_date_executor'");
    expect(migration).toContain("RAISE EXCEPTION 'Audited stage date creation failed.'");
    expect(migration).toContain("CREATE FUNCTION public.create_discipline_stage_with_dates(");
  });

  it("preserves partial dates, clones explicit values into working and R00 snapshots, and extends product history", () => {
    expect(migration).toContain("planned_start IS NULL OR planned_end IS NULL OR planned_start <= planned_end");
    expect(migration).toContain("'plannedStart', v_stage.planned_start, 'plannedEnd', v_stage.planned_end");
    expect(migration).toContain("'plannedStart', stage.planned_start, 'plannedEnd', stage.planned_end");
    expect(migration).toContain("Copied from product %s during cloning.");
    expect(migration).toContain("'stage_dates_changed'");
    expect(migration).toContain("position('plannedStart' IN pg_get_functiondef(");
    expect(migration).not.toContain("position('plannedStart', pg_get_functiondef(");
    expect(migration).toContain("v_anchor constant text := '  ), eligible AS MATERIALIZED ('");
    expect(migration).toContain("Product history function source differs from the reviewed migration 0027 definition.");
  });

  it("keeps the Worker away from direct date and audit-table writes", () => {
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.change_discipline_stage_dates");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.create_discipline_stage_with_dates");
    expect(migration).toContain("has_function_privilege('jlproject_worker'");
    expect(migration).toContain("position('public.stage_date_changes' IN pg_get_functiondef(");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'SELECT')");
    expect(migration).toContain("GRANT UPDATE (planned_start, planned_end, version, updated_by, updated_at)");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.discipline_stages', 'planned_start', 'UPDATE')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'INSERT')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'UPDATE')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'TRUNCATE')");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
  });

  it("grants the executor schema creation before ownership changes and revokes it after history replacement", () => {
    const schemaCreate = migration.indexOf("GRANT CREATE ON SCHEMA public TO jlproject_date_executor;");
    const tableOwner = migration.indexOf("ALTER TABLE public.stage_date_changes OWNER TO jlproject_date_executor;");
    const functionOwner = migration.indexOf("ALTER FUNCTION public.prevent_stage_date_change_mutation() OWNER TO jlproject_date_executor;");
    const historyReplacement = migration.indexOf("EXECUTE v_replaced;");
    const revokeSchemaCreate = migration.indexOf("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;");
    expect(schemaCreate).toBeGreaterThanOrEqual(0);
    expect(schemaCreate).toBeLessThan(tableOwner);
    expect(schemaCreate).toBeLessThan(functionOwner);
    expect(historyReplacement).toBeGreaterThan(schemaCreate);
    expect(revokeSchemaCreate).toBeGreaterThan(historyReplacement);
  });
});
