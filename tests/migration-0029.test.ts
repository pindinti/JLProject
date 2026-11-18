import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0029_living_schedule_audit_concurrency.sql", "utf8");

describe("migration 0029 Living Schedule audit and concurrency", () => {
  it("is an additive, atomic migration guarded by the verified 0028 Development prerequisites", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("reviewed Development schema through migration 0028");
    expect(migration).toContain("LOCK TABLE public.products, public.product_disciplines, public.discipline_stages");
    expect(migration).toContain("INSERT INTO public.product_schedule_state (workspace_id, product_id)");
    expect(migration).not.toMatch(/^\s*(DROP\s+(TABLE|COLUMN|CONSTRAINT)|TRUNCATE\s)/im);
    expect(migration).not.toMatch(/(?:UPDATE|DELETE)\s+public\.initial_schedule_revisions/i);
    expect(migration).not.toMatch(/(?:INSERT|UPDATE|DELETE)\s+public\.(products|product_disciplines|discipline_stages|stage_activities|business_targets)\b/i);
  });

  it("records one monotonic product version per transaction and groups row details under it", () => {
    expect(migration).toContain("transaction_id xid8 NOT NULL");
    expect(migration).toContain("UNIQUE (workspace_id, product_id, transaction_id)");
    expect(migration).toContain("schedule_version = state.schedule_version + 1");
    expect(migration).toContain("pg_current_xact_id()");
    expect(migration).toContain("A product transaction cannot contain multiple Living Schedule operations.");
    expect(migration).toContain("NULLIF(current_setting('jlproject.hierarchy_operation_id', true), '')::uuid");
    expect(migration).toContain("history_watermark = GREATEST(state.history_watermark, v_event_id)");
    expect(migration).toContain("product_schedule_operations_append_only");
    expect(migration).toContain("product_schedule_operation_events_append_only");
    expect(migration).toContain("product_schedule_operation_links_append_only");
  });

  it("requires reasons for dated entity creation while preserving import and clone cutovers", () => {
    expect(migration).toContain("IF TG_OP = 'INSERT' THEN");
    expect(migration).toContain("TG_TABLE_NAME = 'stage_activities'");
    expect(migration).toContain("TG_TABLE_NAME = 'business_targets'");
    expect(migration).toContain("IN ('product_created', 'schedule_imported')");
    expect(migration).toContain("A valid justification is required for this schedule operation.");
  });

  it("covers direct and controlled Living Schedule mutation paths with before/after hierarchy details", () => {
    for (const trigger of ["products_schedule_audit", "product_disciplines_schedule_audit",
      "discipline_stages_schedule_audit", "stage_activities_schedule_audit",
      "business_targets_schedule_audit", "stage_definitions_schedule_audit"])
      expect(migration).toContain(`CREATE TRIGGER ${trigger}`);
    for (const table of ["activity_date_changes", "stage_date_changes", "business_target_date_changes",
      "calendar_reschedule_changes", "calendar_reschedule_reversals", "hierarchy_movement_events",
      "schedule_deletion_events"])
      expect(migration).toContain(`ON public.${table} FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source()`);
    expect(migration).toContain("parent_before jsonb");
    expect(migration).toContain("parent_after jsonb");
    expect(migration).toContain("previous_values jsonb");
    expect(migration).toContain("new_values jsonb");
    expect(migration).toContain("reversal_of_operation_id uuid");
    expect(migration).toContain("link_kind IN ('audit_detail', 'reversal_of')");
    expect(migration).toContain("A valid justification is required for this schedule operation.");
  });

  it("creates specialized-ledger triggers under the ledger owner with temporary membership", () => {
    const membershipGrant = migration.indexOf(
      "GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;",
    );
    const triggerRole = migration.indexOf("SET ROLE jlproject_date_executor;", membershipGrant);
    const firstSpecializedTrigger = migration.indexOf(
      "CREATE TRIGGER activity_date_changes_schedule_link",
      triggerRole,
    );
    const lastSpecializedTrigger = migration.indexOf(
      "CREATE TRIGGER schedule_deletion_events_schedule_link",
      firstSpecializedTrigger,
    );
    const roleReset = migration.indexOf("RESET ROLE;", lastSpecializedTrigger);
    const membershipRevoke = migration.indexOf(
      "REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;",
      roleReset,
    );

    expect(membershipGrant).toBeGreaterThanOrEqual(0);
    expect(triggerRole).toBeGreaterThan(membershipGrant);
    expect(firstSpecializedTrigger).toBeGreaterThan(triggerRole);
    expect(lastSpecializedTrigger).toBeGreaterThan(firstSpecializedTrigger);
    expect(roleReset).toBeGreaterThan(lastSpecializedTrigger);
    expect(membershipRevoke).toBeGreaterThan(roleReset);
  });

  it("revokes the legacy target-delete bypass as its function owner", () => {
    const functionRevoke = migration.indexOf(
      "REVOKE ALL ON FUNCTION public.delete_business_target(uuid,uuid,uuid,uuid,uuid,bigint)",
    );
    const executorRole = migration.lastIndexOf("SET ROLE jlproject_date_executor;", functionRevoke);
    const roleReset = migration.indexOf("RESET ROLE;", functionRevoke);
    const wrapperGrant = migration.indexOf(
      "GRANT EXECUTE ON FUNCTION public.read_product_schedule_cursor",
      functionRevoke,
    );

    expect(functionRevoke).toBeGreaterThanOrEqual(0);
    expect(executorRole).toBeGreaterThan(migration.indexOf("ALTER FUNCTION public.delete_business_target_with_reason"));
    expect(roleReset).toBeGreaterThan(functionRevoke);
    expect(wrapperGrant).toBeGreaterThan(functionRevoke);
    expect(roleReset).toBeGreaterThan(wrapperGrant);
  });

  it("retains direct date-update values unless a controlled specialized ledger owns them", () => {
    expect(migration).toMatch(/TG_TABLE_NAME = 'stage_activities'[\s\S]*?v_operation_type IN \('activity_dates_changed', 'activity_working_plan_changed',[\s\S]*?'calendar_rescheduled', 'calendar_reschedule_reversed'\)[\s\S]*?v_previous := v_previous - ARRAY\['planned_start', 'planned_end'\]/);
    expect(migration).toMatch(/TG_TABLE_NAME = 'discipline_stages'[\s\S]*?v_operation_type = 'stage_dates_changed'[\s\S]*?v_previous := v_previous - ARRAY\['planned_start', 'planned_end'\]/);
    expect(migration).toMatch(/TG_TABLE_NAME = 'business_targets'[\s\S]*?v_operation_type IN \('business_target_updated', 'business_target_date_changed'\)[\s\S]*?v_previous := v_previous - ARRAY\['target_date'\]/);
    expect(migration).not.toContain("v_previous := v_previous - ARRAY['deleted_at', 'deletion_operation_id']");
  });

  it("keeps audit tables private, makes reads workspace-scoped, and revokes the target-delete bypass", () => {
    expect(migration).toContain("REVOKE ALL ON public.product_schedule_state, public.product_schedule_operations");
    expect(migration).toContain("public.read_product_schedule_cursor(uuid,uuid,uuid)");
    expect(migration).toContain("public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)");
    expect(migration).toContain("membership.active AND membership.role IN ('admin', 'editor', 'viewer')");
    expect(migration).toContain("public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)");
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.delete_business_target(uuid,uuid,uuid,uuid,uuid,bigint)");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT')");
    expect(migration).toContain("has_schema_privilege('jlproject_date_executor', 'public', 'CREATE')");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
  });
});
