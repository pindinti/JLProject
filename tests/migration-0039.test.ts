import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0039_guard_calendar_reschedule_apply.sql", "utf8").replace(/\r\n/g, "\n");
const legacy = readFileSync("db/migrations/0025_root_activities.sql", "utf8").replace(/\r\n/g, "\n");
const installed = legacy.slice(legacy.indexOf("CREATE OR REPLACE FUNCTION public.apply_calendar_reschedule("),
  legacy.indexOf("CREATE OR REPLACE FUNCTION public.reverse_calendar_reschedule("));
const afterIndividualDateGuard = installed.replace("v_result := public.change_activity_planning(",
  "v_result := public.write_reviewed_activity_planning(");

describe("calendar apply dependency migration", () => {
  it("installs the guard between validation and the existing transactional write loop", () => {
    const anchors = [...migration.matchAll(/constant text := (\$\w+\$)([\s\S]*?)\1;/g)].map((match) => match[2]);
    expect(anchors).toHaveLength(3);
    const [writeLoop, staleCheck, endCheck] = anchors;
    expect(afterIndividualDateGuard.split(writeLoop!)).toHaveLength(2);
    expect(afterIndividualDateGuard.split(staleCheck!)).toHaveLength(2);
    expect(afterIndividualDateGuard.split(endCheck!)).toHaveLength(2);
    expect(installed.indexOf("v_activity.version <>")).toBeLessThan(installed.indexOf(writeLoop!));
    expect(afterIndividualDateGuard.indexOf("FOR UPDATE;", afterIndividualDateGuard.indexOf("FROM public.products")))
      .toBeLessThan(afterIndividualDateGuard.indexOf(writeLoop!));
    expect(afterIndividualDateGuard).toContain("v_result := public.write_reviewed_activity_planning(");
    expect(afterIndividualDateGuard).not.toContain("public.guard_calendar_reschedule_dependencies(");
    expect(migration).toMatch(/IF v_result IS NOT NULL THEN RETURN v_result; END IF;\s+\$guard\$ \|\| v_write_loop/);
    expect(migration).toContain("v_activity.version IS DISTINCT FROM (v_item->>'expectedVersion')::bigint");
    expect(migration).toContain("v_activity.working_day_duration IS DISTINCT FROM (v_item->>'workingDays')::integer");
    expect(migration).toContain("v_activity.planning_calendar_version IS DISTINCT FROM (v_item->>'savedCalendarVersion')::bigint");
    expect(migration).toContain("IF v_item->>'proposedEndDate' IS NULL");
    expect(migration).not.toContain("reverse_calendar_reschedule");
  });

  it("overlays every proposed child finish, leaves explicit stages independent, and reuses the calendar boundary rules", () => {
    expect(migration).toContain("max(COALESCE(proposed.proposed_finish, child.planned_end))");
    expect(migration).toContain("LEFT JOIN proposed_activities AS proposed ON proposed.id = child.id");
    expect(migration).toContain("stage.planned_start IS NULL AND stage.planned_end IS NULL");
    expect(migration).toContain("child.deleted_at IS NULL");
    expect(migration).toContain("public.dependency_effective_date_interval(");
    expect(migration).toContain("public.dependency_first_working_start(p_workspace, v_edge.proposed_finish)");
    expect(migration).toContain("v_proposed_bound > v_previous_bound");
  });

  it("keeps the empty-graph short circuit and the Worker privilege boundary", () => {
    expect(migration).toMatch(/IF NOT EXISTS \(SELECT 1 FROM public.product_schedule_dependencies\s+WHERE workspace_id = p_workspace AND product_id = p_product\) THEN RETURN NULL;/);
    expect(migration).toContain("FROM PUBLIC, jlproject_worker, neondb_owner;");
    expect(migration).not.toMatch(/GRANT\s+EXECUTE/i);
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
  });
});
