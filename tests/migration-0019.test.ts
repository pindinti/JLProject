import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0019_calendar_reschedule_history.sql", "utf8");

describe("migration 0019 security review", () => {
  it("is transactional and checks its exact development schema and role prerequisites", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    for (const required of [
      "current_user <> 'neondb_owner'", "current_database() <> 'neondb'",
      "rolname = 'jlproject_date_executor' AND NOT rolcanlogin",
      "public.calendar_reschedule_changes", "public.calendar_reschedule_reversals",
      "public.activity_date_changes", "public.stage_activities",
      "pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage')",
      "pg_has_role('neondb_owner', 'jlproject_date_executor', 'set')"
    ]) expect(migration).toContain(required);
    expect(migration).not.toContain("pg_has_role('neondb_owner', 'jlproject_date_executor', 'member')");
  });

  it("uses a fixed-path definer function with explicit member and product scope checks", () => {
    expect(migration).toMatch(/CREATE FUNCTION public\.list_calendar_reschedule_history\([\s\S]*?SECURITY DEFINER SET search_path = pg_catalog, pg_temp/);
    expect(migration).toContain("auth_user_id = p_actor_id AND active = true");
    expect(migration).toContain("workspace_id = p_workspace_id AND id = p_product_id AND active = true");
    expect(migration).toContain("WHERE c.workspace_id = p_workspace_id AND c.product_id = p_product_id");
    expect(migration).toContain("audit_consistent AND state_unchanged");
    expect(migration).toContain("'previousStart'");
    expect(migration).toContain("'newStart'");
    expect(migration).toContain("'actorId'");
    expect(migration).toContain("'reason', reason");
    expect(migration).toContain("'already_reversed'");
    expect(migration).toContain("LEFT JOIN public.stage_activities AS a");
  });

  it("grants only function execution and preserves direct audit-table denial", () => {
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.list_calendar_reschedule_history(uuid,uuid,uuid) FROM PUBLIC");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.list_calendar_reschedule_history(uuid,uuid,uuid) TO jlproject_worker");
    expect(migration).toMatch(/has_table_privilege\('jlproject_worker', 'public\.calendar_reschedule_changes', 'SELECT'\)/);
    expect(migration).toMatch(/has_table_privilege\('jlproject_worker', 'public\.calendar_reschedule_reversals', 'SELECT'\)/);
    expect(migration).toMatch(/has_function_privilege\('public',[\s\S]*?'EXECUTE'\)/);
    expect(migration).toMatch(/pg_get_userbyid\(proowner\)[\s\S]*?<> 'jlproject_date_executor'/);
    expect(migration).not.toMatch(/GRANT\s+(?:SELECT|INSERT|UPDATE|DELETE|ALL)[\s\S]*?TO jlproject_worker/i);
    expect(migration).not.toContain("initial_schedule_revisions");
  });

  it("checks every executor data dependency and uses no application function or sequence", () => {
    const dependencies = [
      "workspaces", "workspace_memberships", "products", "stage_activities",
      "activity_date_changes", "calendar_reschedule_changes", "calendar_reschedule_reversals"
    ];
    for (const table of dependencies) {
      expect(migration).toContain(`NOT has_table_privilege('jlproject_date_executor', 'public.${table}', 'SELECT')`);
      expect(migration).toMatch(new RegExp(`(?:FROM|JOIN) public\\.${table}\\b`));
    }
    expect(migration).not.toMatch(/nextval\s*\(|\b(?:PERFORM|SELECT|:=)\s+public\.[a-z_]+\s*\(/i);
    expect(migration).toContain("SECURITY DEFINER SET search_path = pg_catalog, pg_temp");
  });
});
