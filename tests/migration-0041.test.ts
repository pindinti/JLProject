import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assessDependencyBoundaryChange } from "../domain/schedule-dependencies";

const migration = readFileSync("db/migrations/0041_guard_activity_creation_dependencies.sql", "utf8").replace(/\r\n/g, "\n");

describe("activity creation dependency guard migration", () => {
  it("checks all activity INSERT paths under workspace then product locks", () => {
    expect(migration).toContain("public.guard_calendar_reschedule_dependencies(uuid,uuid,jsonb)");
    expect(migration).toContain("proposedStartDate");
    expect(migration).toContain("public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)");
    expect(migration).toContain("CREATE TRIGGER stage_activities_activity_creation_dependency_guard");
    expect(migration).toContain("BEFORE INSERT ON public.stage_activities");
    expect(migration).toContain("PERFORM 1 FROM public.workspaces WHERE id = NEW.workspace_id FOR SHARE");
    expect(migration).toContain("product.workspace_id = NEW.workspace_id AND product.id = NEW.product_id FOR UPDATE");
    expect(migration).toContain("v_product_active IS DISTINCT FROM true");
    expect(migration).toContain("ERRCODE = 'P4D01', DETAIL = v_conflict::text");
    expect(migration).toContain("guard_activity_creation_dependencies(p_workspace_id, p_product_id, p_stage_id, p_start, p_end)");
  });

  it("projects derived child ranges only and leaves explicit or partially explicit D065 stages fixed", () => {
    expect(migration).toContain("stage.planned_start IS NOT NULL OR stage.planned_end IS NOT NULL");
    expect(migration).toContain("SELECT min(projected.start_date), max(projected.end_date)");
    expect(migration).toContain("UNION ALL\n    SELECT p_start, p_end");
    expect(migration).toContain("public.dependency_effective_date_interval");
    expect(migration).toContain("public.dependency_first_working_start");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("returns root and empty-graph inserts unchanged and does not move schedules", () => {
    expect(migration).toContain("IF p_stage IS NULL OR NOT EXISTS");
    expect(migration).toContain("RETURN NULL;");
    expect(migration).not.toMatch(/\b(?:UPDATE|DELETE FROM) public\.(?:stage_activities|discipline_stages|product_schedule_dependencies)\b/i);
  });

  it("retains the shared allowance for improving existing conflicts", () => {
    const before = { predecessorFinish: "2026-11-10", successorStart: "2026-11-06", earliestStart: "2026-11-11" };
    expect(assessDependencyBoundaryChange(before, {
      predecessorFinish: "2026-11-09", successorStart: "2026-11-06", earliestStart: "2026-11-10"
    })).toBeNull();
    expect(assessDependencyBoundaryChange(before, {
      predecessorFinish: "2026-11-11", successorStart: "2026-11-06", earliestStart: "2026-11-12"
    })).toBe("finish_to_start");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("keeps the guards private and leaves route activation and insert permissions untouched", () => {
    expect(migration).toContain("FROM PUBLIC, jlproject_worker;");
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.guard_activity_creation_before_insert() FROM neondb_owner;");
    expect(migration).toContain("has_function_privilege('neondb_owner',");
    expect(migration).not.toMatch(/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.guard_activity_creation_dependencies\b/i);
    expect(migration).toContain("has_function_privilege('jlproject_worker',");
    expect(migration).toContain("'public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)', 'EXECUTE')");
    expect(migration).not.toMatch(/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.guard_activity[^;]*TO\s+jlproject_worker/i);
    expect(migration).not.toMatch(/GRANT\s+INSERT|REVOKE\s+INSERT/i);
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
  });

  it("grants trigger execution as function owner and revokes it there after trigger creation", () => {
    const initialOwnerRole = migration.indexOf("SET ROLE jlproject_date_executor;");
    const ownerGrant = migration.indexOf(
      "GRANT EXECUTE ON FUNCTION public.guard_activity_creation_before_insert() TO neondb_owner;"
    );
    const roleReset = migration.indexOf("RESET ROLE;", ownerGrant);
    const trigger = migration.indexOf("CREATE TRIGGER stage_activities_activity_creation_dependency_guard");
    const cleanupOwnerRole = migration.indexOf("SET ROLE jlproject_date_executor;", trigger);
    const triggerRevoke = migration.indexOf(
      "REVOKE ALL ON FUNCTION public.guard_activity_creation_before_insert() FROM neondb_owner;",
      cleanupOwnerRole
    );
    const helperRevoke = migration.indexOf(
      "REVOKE ALL ON FUNCTION public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date) FROM neondb_owner;",
      cleanupOwnerRole
    );
    const cleanupRoleReset = migration.indexOf("RESET ROLE;", helperRevoke);
    const schemaPrivilegeCleanup = migration.indexOf("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;", cleanupRoleReset);
    const membershipCleanup = migration.indexOf(
      "REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;",
      schemaPrivilegeCleanup
    );

    expect(initialOwnerRole).toBeGreaterThan(-1);
    expect(initialOwnerRole).toBeLessThan(ownerGrant);
    expect(ownerGrant).toBeLessThan(roleReset);
    expect(roleReset).toBeLessThan(trigger);
    expect(trigger).toBeLessThan(cleanupOwnerRole);
    expect(cleanupOwnerRole).toBeLessThan(triggerRevoke);
    expect(triggerRevoke).toBeLessThan(helperRevoke);
    expect(helperRevoke).toBeLessThan(cleanupRoleReset);
    expect(cleanupRoleReset).toBeLessThan(schemaPrivilegeCleanup);
    expect(schemaPrivilegeCleanup).toBeLessThan(membershipCleanup);
  });
});
