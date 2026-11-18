import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0031_import_authorization_compatibility.sql", "utf8");
const preflight = readFileSync("db/verification/phase1-import-authorization-preflight.sql", "utf8");
const postflight = readFileSync("db/verification/phase1-import-authorization-postflight.sql", "utf8");
const integration = readFileSync("db/verification/phase1-import-authorization-rollback.sql", "utf8");

describe("migration 0031 import authorization compatibility", () => {
  it("is an atomic, guarded, additive correction for the reviewed import contract", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)");
    expect(migration).toContain("An import-path SELECT, INSERT, or workspace row-lock privilege is missing.");
    expect(migration).not.toMatch(/^\s*(DROP\s+(TABLE|COLUMN|CONSTRAINT)|TRUNCATE\s)/im);
    expect(migration).not.toMatch(/(?:INSERT|UPDATE|DELETE)\s+public\.(products|product_disciplines|discipline_stages|stage_activities|business_targets|initial_schedule_revisions)\b/i);
  });

  it("grants only provenance-column INSERT without changing the importer security model", () => {
    expect(migration.match(/^GRANT\b.*$/gm)).toEqual([
      "GRANT INSERT (source_external_id) ON public.stage_activities TO jlproject_worker;",
    ]);
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT')");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'source_external_id', 'UPDATE')");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE')");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planning_mode', 'INSERT')");
    expect(migration).toContain("has_function_privilege('jlproject_worker', 'public.capture_product_schedule_mutation()', 'EXECUTE')");
    expect(migration).toContain("public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)");
    expect(migration).not.toMatch(/SECURITY\s+DEFINER/i);
    expect(migration).not.toMatch(/ALTER\s+FUNCTION/i);
  });

  it("checks the import path, active audit/R00 protections, and Worker least privilege", () => {
    expect(migration).toContain("NOT prosecdef");
    expect(migration).toContain("search_path=public, pg_catalog");
    expect(migration).toContain("stage_activities_schedule_audit");
    expect(migration).toContain("initial_schedule_revisions_immutable");
    expect(migration).toContain("public.product_schedule_operation_source_events");
    expect(migration).toContain("public.stage_activities_source_id_unique_idx");
    expect(migration).toContain("pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE')");
    expect(migration).not.toMatch(/(?:INSERT|UPDATE|DELETE)\s+public\.initial_schedule_revisions/i);
  });

  it("records a read-only preflight and prepares rollback-only Worker integration checks", () => {
    expect(preflight).toContain("BEGIN READ ONLY;");
    expect(preflight).toMatch(/ROLLBACK;\s*$/);
    expect(preflight).toContain("stageActivityColumnPrivileges");
    expect(preflight).toContain("r00Fingerprints");
    expect(preflight).toContain("migration0030Objects");

    expect(postflight).toContain("BEGIN READ ONLY;");
    expect(postflight).toMatch(/ROLLBACK;\s*$/);
    expect(postflight).toContain("source_external_id");
    expect(postflight).toContain("public.product_schedule_operation_source_events");
    expect(postflight).toContain("initial_schedule_revisions_immutable");

    expect(integration).toContain("Rollback-only import authorization checks for migration 0031");
    expect(integration).toContain("public.import_initial_schedule");
    expect(integration).toContain("source_external_id = 'T001'");
    expect(integration).toContain("P1-0031 imported target");
    expect(integration).toContain("target.operational_date = DATE '2031-01-29'");
    expect(integration).toContain("'schedule_imported'");
    expect(integration).toContain("'replayed'");
    expect(integration).toContain("'conflict'");
    expect(integration).toContain("'duplicate'");
    expect(integration).toContain("'denied'");
    expect(migration).toContain("initial_schedule_revisions_immutable");
    expect(integration).toContain("R00 mutation was not rejected");
    expect(integration).toContain("v_existing_r00_after IS DISTINCT FROM v_existing_r00_before");
    expect(integration).not.toContain("COMMIT;");
    expect(integration.match(/^ROLLBACK;$/gm)?.length).toBe(2);
  });
});
