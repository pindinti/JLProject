import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0022_product_change_history.sql", "utf8");

describe("migration 0022 product change history security review", () => {
  it("is transactional and requires the isolated owner, roles, prior sources, and no prior function", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    for (const required of [
      "current_user <> 'neondb_owner'", "current_database() <> 'neondb'",
      "to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL",
      "rolname = 'jlproject_date_executor' AND NOT rolcanlogin",
      "pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage')",
      "pg_has_role('neondb_owner', 'jlproject_date_executor', 'set')",
      "pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member')"
    ]) expect(migration).toContain(required);
  });

  it("uses a fixed-path definer function, authenticates the server actor, and scopes every source", () => {
    expect(migration).toMatch(/CREATE FUNCTION public\.list_product_change_history\([\s\S]*?STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp/);
    expect(migration).toContain("membership.auth_user_id = p_actor_id AND membership.active = true");
    expect(migration).toContain("product.workspace_id = p_workspace_id AND product.id = p_product_id");
    for (const source of [
      "activity_date_changes", "business_target_date_changes", "calendar_reschedule_changes",
      "calendar_reschedule_reversals", "schedule_deletion_events", "import_batches", "import_source_rows"
    ]) expect(migration).toMatch(new RegExp(`(?:FROM|JOIN) public\\.${source}\\b`));
    expect(migration).toContain("'product_created'");
    expect(migration).toContain("'schedule_imported'");
    expect(migration).toContain("'activity_dates_changed'");
    expect(migration).toContain("'business_target_date_changed'");
    expect(migration).toContain("'calendar_rescheduled'");
    expect(migration).toContain("'calendar_reschedule_reversed'");
    expect(migration).toContain("'schedule_hierarchy_deleted'");
    expect(migration).toContain("NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes");
    expect(migration).toContain("NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals");
    expect(migration).toContain("jsonb_to_recordset(event.affected_items)");
    expect(migration).not.toMatch(/(?:FROM|JOIN) public\.initial_schedule_revisions\b/);
    expect(migration).not.toMatch(/\b(?:INSERT\s+INTO|UPDATE\s+public\.|DELETE\s+FROM)\b/i);
  });

  it("provides keyset pagination with deterministic newest-first tie-breaking", () => {
    expect(migration).toContain("p_limit NOT BETWEEN 1 AND 100");
    expect(migration).toContain("(event.occurred_at, event.event_id COLLATE \"C\") <");
    expect(migration).toContain("ORDER BY event.occurred_at DESC, event.event_id COLLATE \"C\" DESC");
    expect(migration).toContain("LIMIT p_limit + 1");
    expect(migration).toContain("'nextCursor', v_next_cursor");
  });

  it("grants the Worker only function execution and verifies the audit boundaries", () => {
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text) FROM PUBLIC");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)");
    expect(migration).toMatch(/GRANT EXECUTE ON FUNCTION public\.list_product_change_history[\s\S]*?TO jlproject_worker/);
    expect(migration).toMatch(/pg_get_userbyid\(proowner\)[\s\S]*?<> 'jlproject_date_executor'/);
    for (const table of ["calendar_reschedule_changes", "calendar_reschedule_reversals", "schedule_deletion_events"])
      expect(migration).toMatch(new RegExp(`has_table_privilege\\('jlproject_worker', 'public\\.${table}', 'SELECT'\\)`));
    expect([...migration.matchAll(/^\s*GRANT\s+(?:SELECT|INSERT|UPDATE|DELETE|ALL)\b[^;]*\bTO\s+jlproject_worker\b/gim)])
      .toHaveLength(0);
    expect(migration).toContain("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
  });
});
