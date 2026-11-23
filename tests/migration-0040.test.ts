import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assessDependencyBoundaryChange } from "../domain/schedule-dependencies";

const migration = readFileSync("db/migrations/0040_guard_calendar_reschedule_reversal.sql", "utf8").replace(/\r\n/g, "\n");
const legacy = readFileSync("db/migrations/0025_root_activities.sql", "utf8").replace(/\r\n/g, "\n");
const installed = legacy.slice(legacy.indexOf("CREATE OR REPLACE FUNCTION public.reverse_calendar_reschedule("),
  legacy.indexOf("CREATE OR REPLACE FUNCTION public.preview_schedule_deletion("));

describe("calendar reversal dependency guard", () => {
  it("guards the existing locked, audit-validated write loop and compares row versions safely", () => {
    const anchor = migration.match(/\$loop\$([^$]+)\$loop\$/)?.[1];
    expect(anchor).toBeDefined();
    expect(installed.split(anchor!)).toHaveLength(2);
    for (const beforeWrite of ["AND id = p_product_id AND active = true FOR UPDATE", "IF v_change.audit_matches IS NOT TRUE THEN",
      "IF NOT FOUND OR v_activity.version <> v_change.version_after OR"]) {
      expect(installed.indexOf(beforeWrite)).toBeGreaterThanOrEqual(0);
      expect(installed.indexOf(beforeWrite)).toBeLessThan(installed.indexOf(anchor!));
    }
    expect(migration).toContain("v_change.version_after IS NULL OR v_activity.version IS DISTINCT FROM v_change.version_after");
    expect(migration).toContain("AND id = v_change.activity_id AND deleted_at IS NULL FOR UPDATE;");
    expect(migration).toContain("jsonb_array_length(v_proposals) IS DISTINCT FROM v_count");
    expect(migration).toMatch(/IF v_conflict IS NOT NULL THEN RETURN v_conflict; END IF;\s+END IF;\s+\$guard\$ \|\| v_write_loop/);
  });

  it("projects both restored boundaries and all children while retaining explicit D065 stage dates", () => {
    expect(migration).toContain("'proposedStartDate', c.previous_start, 'proposedEndDate', c.previous_end");
    expect(migration).toContain("min(COALESCE(proposed.new_start, child.planned_start)), max(COALESCE(proposed.new_finish, child.planned_end))");
    expect(migration).toContain("stage.planned_start IS NULL AND stage.planned_end IS NULL");
    expect(migration).toContain("LEFT JOIN projected_intervals AS predecessor");
    expect(migration).toContain("LEFT JOIN projected_intervals AS successor");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("allows improvements and equal violations when a reversal moves both boundaries", () => {
    const before = { predecessorFinish: "2026-11-09", earliestStart: "2026-11-10", successorStart: "2026-11-05" };
    const after = { predecessorFinish: "2026-11-11", earliestStart: "2026-11-12", successorStart: "2026-11-09" };
    expect(assessDependencyBoundaryChange(before, after)).toBeNull();
    expect(assessDependencyBoundaryChange(before, { ...after, successorStart: "2026-11-07" })).toBeNull();
    expect(assessDependencyBoundaryChange(before, { ...after, successorStart: "2026-11-06" })).toBe("finish_to_start");
  });

  it("retains the empty-graph path, append-only audit and restricted execution", () => {
    expect(migration).toMatch(/IF NOT EXISTS \(SELECT 1 FROM public.product_schedule_dependencies\s+WHERE workspace_id = p_workspace AND product_id = p_product\) THEN RETURN NULL;/);
    expect(installed).toContain("INSERT INTO public.calendar_reschedule_reversals");
    expect(migration).not.toMatch(/\b(?:UPDATE|DELETE FROM) public\.(?:activity_date_changes|calendar_reschedule_changes|calendar_reschedule_reversals)\b/i);
    expect(migration).not.toMatch(/GRANT\s+EXECUTE/i);
    expect(migration).toContain("FROM PUBLIC, jlproject_worker, neondb_owner;");
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
  });
});
