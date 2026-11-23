import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0042_guard_hierarchy_move_dependencies.sql", "utf8").replace(/\r\n/g, "\n");
const verification = readFileSync("db/verification/phase4b3c2-hierarchy-move.sql", "utf8").replace(/\r\n/g, "\n");

describe("hierarchy movement dependency guard migration", () => {
  it("requires the reviewed dependency/date guards and preserves the existing Worker move operation", () => {
    expect(migration).toContain("public.guard_activity_creation_dependencies(uuid,uuid,uuid,date,date)");
    expect(migration).toContain("stage_activities_activity_creation_dependency_guard");
    expect(migration).toContain("CREATE FUNCTION public.guard_activity_reparent_dependencies");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.move_schedule_item");
    expect(migration).toContain("has_function_privilege('jlproject_worker'");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'UPDATE')");
    expect(migration).toContain("has_function_privilege('jlproject_worker',");
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
  });

  it("projects source removal and destination addition together using D065 stage boundaries", () => {
    expect(migration).toContain("child.id <> p_activity");
    expect(migration).toContain("UNION ALL\n        SELECT v_activity.planned_start, v_activity.planned_end");
    expect(migration).toContain("stage.planned_start IS NULL AND stage.planned_end IS NULL");
    expect(migration.match(/child\.discipline_id IS NOT DISTINCT FROM stage\.discipline_id/g)).toHaveLength(2);
    expect(migration).toContain("public.dependency_effective_date_interval");
    expect(migration).toContain("public.dependency_first_working_start");
    expect(migration).toContain("ORDER BY edge.id");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("guards only activity reparenting before any writes while allowing pure reorder and stage moves", () => {
    expect(migration).toContain("IF p_kind = 'activity' AND NOT v_same_parent THEN");
    expect(migration).toContain("IF v_same_parent AND v_source_before = v_source_after THEN");
    expect(migration).toContain("v_original_stage_id, p_destination_stage_id");
    expect(migration).toContain("IF v_dependency_conflict IS NOT NULL THEN RETURN v_dependency_conflict; END IF;");
    expect(migration).not.toMatch(/^\s*(?:UPDATE|INSERT|DELETE FROM) public\.(?:stage_activities|discipline_stages|product_schedule_dependencies)\b/im);
    expect(migration).toContain("FROM PUBLIC, jlproject_worker, neondb_owner;");
    expect(migration).not.toMatch(/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.guard_activity_reparent/i);
  });

  it("compares final dependency slack so unchanged or improved violations remain allowed", () => {
    expect(migration).toContain("v_new_start < v_new_bound AND (v_old_start IS NULL OR v_old_bound IS NULL");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("prepares rollback-only coverage for reparenting boundaries and failure cases", () => {
    expect(verification).toMatch(/^--[\s\S]*?\nBEGIN;\s/);
    expect(verification).toMatch(/ROLLBACK;\s*$/);
    const lowerVerification = verification.toLowerCase();
    for (const expected of ["same-parent reorder", "source-child removal", "destination-child addition",
      "root-to-stage", "stage-to-root", "fixed explicit and partial", "multi-edge derived-stage conflict",
      "dependency_conflict", "stale version", "viewer", "empty graph",
      "second logical operation", "schedule cursor", "source row"]) expect(lowerVerification).toContain(expected);
    expect(verification).toContain("EXCEPTION WHEN check_violation THEN");
    expect(verification).toContain("v_error_state <> '23514'");
    expect(verification).toContain("A product transaction cannot contain multiple Living Schedule operations.");
    expect(verification).toContain("IF NOT v_second_operation_rejected THEN");
    expect(verification).not.toContain("EXCEPTION WHEN unique_violation THEN");
  });
});
