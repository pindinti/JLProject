import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assessDependencyBoundaryChange } from "../domain/schedule-dependencies";
import { calendarRulesForYear } from "../domain/working-calendar";

const migration = readFileSync("db/migrations/0038_guard_individual_schedule_dates.sql", "utf8");

describe("individual date guards", () => {
  it("uses exactly the Phase 4A built-in calendar dates across the complete supported range", () => {
    const fixed = new Set(migration.match(/\$fixed\$([^$]+)\$fixed\$/)?.[1].split(/\s+/));
    const dated = migration.match(/\$dated\$([^$]+)\$dated\$/)?.[1].split(/\s+/) ?? [];
    expect(fixed.size).toBe(9);
    expect(dated).toHaveLength(84);
    for (let year = 2026; year <= 2100; year++) {
      const fromSql = [...[...fixed].map((monthDay) => `${year}-${monthDay}`),
        ...dated.filter((date) => date.startsWith(`${year}-`))].sort();
      expect(fromSql).toEqual(calendarRulesForYear(year).rules.map(({ date }) => date));
    }
    expect(migration).toContain("v_day BETWEEN exception.start_date AND exception.end_date");
    expect(migration).toContain("exception.removed_at IS NULL");
  });

  it("preserves the named Worker entry points and closes the audited bypass functions", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("FROM PUBLIC, jlproject_worker, neondb_owner;");
    expect(migration).not.toMatch(/GRANT\s+EXECUTE/i);
    expect(migration).toContain("'confirm_schedule_dependencies', 'read_schedule_dependencies', 'read_schedule_dependency_receipt'");
    expect(migration).toContain("'activity', p_activity_id, p_stage_id, p_start, p_end");
    expect(migration).toContain("p_workspace_id, p_product_id, 'stage', p_stage_id, NULL, p_start, p_end");
    expect(migration).toContain("planned.start_date IS NULL AND planned.end_date IS NULL");
    expect(migration).toContain("touched(kind, id) AS (VALUES (p_kind, p_id), ('stage', p_parent_stage))");
    expect(migration).toContain("WHERE id = p_workspace_id FOR SHARE;");
    expect(migration).toContain("AND id = p_product_id AND active = true FOR UPDATE;");
  });

  it("allows slack and improvements and detects stricter outbound and inbound dates", () => {
    const before = { predecessorFinish: "2026-11-05", successorStart: "2026-11-09", earliestStart: "2026-11-06" };
    const delayed = { ...before, predecessorFinish: "2026-11-09", earliestStart: "2026-11-10" };
    expect(assessDependencyBoundaryChange(before, { ...before, predecessorFinish: "2026-11-06", earliestStart: "2026-11-09" })).toBeNull();
    expect(assessDependencyBoundaryChange(before, delayed)).toBe("finish_to_start");
    expect(assessDependencyBoundaryChange(delayed, { ...delayed, predecessorFinish: "2026-11-06", earliestStart: "2026-11-09" })).toBeNull();
    expect(assessDependencyBoundaryChange(before, { ...before, successorStart: "2026-11-05" })).toBe("finish_to_start");
    const existingConflict = { ...before, successorStart: "2026-11-03" };
    expect(assessDependencyBoundaryChange(existingConflict, { ...existingConflict, successorStart: "2026-11-04" })).toBeNull();
  });

  it("distinguishes new D065 boundary loss and unsupported calendar dates", () => {
    const before = { predecessorFinish: "2026-11-05", successorStart: "2026-11-09", earliestStart: "2026-11-06" };
    expect(assessDependencyBoundaryChange(before, { ...before, successorStart: null })).toBe("missing_boundary");
    expect(assessDependencyBoundaryChange(before, { ...before, predecessorFinish: null, earliestStart: null })).toBe("missing_boundary");
    expect(assessDependencyBoundaryChange(before, { ...before, predecessorFinish: "2100-12-31", earliestStart: null })).toBe("calendar_range");
    expect(assessDependencyBoundaryChange(before, before)).toBeNull();
  });
});
