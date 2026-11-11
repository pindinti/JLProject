import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0025_root_activities.sql", "utf8");
const verification = readFileSync(
  "db/verification/phase3a6b-root-activities-development-worker.sql",
  "utf8",
);

describe("migration 0025 root activity data model", () => {
  it("is transactional and rejects unexpected target or schema state", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("jlproject_worker");
    expect(migration).toContain("jlproject_date_executor");
    expect(migration).toContain("prerequisites or limited-role grants differ");
  });

  it("allows only an empty pair or a complete stage parent pair with direct product scope", () => {
    expect(migration).toContain("ALTER COLUMN discipline_id DROP NOT NULL");
    expect(migration).toContain("ALTER COLUMN stage_id DROP NOT NULL");
    expect(migration).toContain("discipline_id IS NULL AND stage_id IS NULL");
    expect(migration).toContain("discipline_id IS NOT NULL AND stage_id IS NOT NULL");
    expect(migration).toContain("FOREIGN KEY (workspace_id, product_id)");
    expect(migration).toContain("REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT");
    expect(migration).toContain("FOREIGN KEY (workspace_id, product_id, activity_id)");
    expect(migration).toContain("REFERENCES public.stage_activities(workspace_id, product_id, id)");
    expect(migration).toContain("stage_activities_parent_fk");
    expect(migration).toContain("GRANT REFERENCES (workspace_id, product_id, id)");
    expect(migration).toContain("REVOKE REFERENCES (workspace_id, product_id, id)");
    expect(migration).toContain("activity_date_changes_product_scope_fk");
  });

  it("updates date planning, rescheduling, reversal, deletion, and history for roots", () => {
    for (const functionName of [
      "change_activity_planning",
      "create_activity_with_working_plan",
      "apply_calendar_reschedule",
      "reverse_calendar_reschedule",
      "preview_schedule_deletion",
      "list_product_change_history",
    ]) expect(migration).toContain(`CREATE OR REPLACE FUNCTION public.${functionName}`);
    expect(migration).toContain("discipline_id IS NOT DISTINCT FROM p_discipline_id");
    expect(migration).toContain("stage_id IS NOT DISTINCT FROM p_stage_id");
    expect(migration).toContain("LEFT JOIN public.discipline_stages AS stage");
    expect(migration).toContain("activity_date_changes_parent_pair_check");
    expect(migration).toContain("stage_activities_root_order_idx");
    expect(migration).toMatch(/IF TG_TABLE_NAME = 'discipline_stages' THEN[\s\S]*?ELSIF TG_TABLE_NAME = 'stage_activities' THEN/);
  });

  it("clones root planning and color data into a separate baseline with a narrow helper grant", () => {
    expect(migration).toContain("CREATE FUNCTION public.clone_root_activity");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.clone_root_activity(uuid,uuid,uuid,uuid,uuid) TO jlproject_worker");
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.clone_root_activity(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC");
    expect(migration).toContain("'rootActivities', v_root_activities");
    expect(migration).toMatch(/FOR v_root_activity IN SELECT activity\.\* FROM public\.stage_activities[\s\S]*?ORDER BY activity\.display_order, activity\.id/);
    expect(migration).toMatch(/public\.clone_root_activity\(p_workspace_id, p_source_product_id,[\s\S]*?v_root_activity\.id\)/);
    expect(migration).toContain("'effectiveColor', COALESCE(v_root_activity.color_override, '#8D9A89')");
    expect(migration).toContain("'planningMode', v_root_activity.planning_mode");
    expect(migration).toContain("'revisionLabel', 'R00'");
    expect(migration).not.toMatch(/UPDATE\s+public\.initial_schedule_revisions/i);
    expect(migration).not.toMatch(/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)\b[^;]*\bTO\s+jlproject_worker/i);
  });

  it("prepares only rollback-only synthetic database verification", () => {
    expect(verification).toMatch(/^--[\s\S]*?\nBEGIN;\s/);
    expect(verification).toMatch(/ROLLBACK;\s*$/);
    for (const required of [
      "Synthetic root working plan",
      "Synthetic stage working plan",
      "Mixed root/stage parent pair was accepted",
      "nullable-parent audit rows",
      "apply_calendar_reschedule",
      "reverse_calendar_reschedule",
      "preview_schedule_deletion",
      "list_product_change_history",
      "public.clone_product",
      "effectiveColor",
      "Existing workspace activities, audit records, or R00 snapshots changed",
    ]) expect(verification).toContain(required);
    expect(verification).not.toContain("public.schedule_deletion_events AS");
    expect(verification).not.toContain("public.calendar_reschedule_changes AS");
  });
});
