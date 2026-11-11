import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0024_activity_color_insert_permission.sql", "utf8");

describe("migration 0024 activity color insert permission", () => {
  it("is transactional and refuses unexpected target or clone privilege state", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    for (const required of [
      "current_user <> 'neondb_owner'", "current_database() <> 'neondb'",
      "public.stage_activities", "public.clone_product(uuid,uuid,uuid,text)",
      "The color override INSERT privilege is not the only missing clone dependency."
    ]) expect(migration).toContain(required);
  });

  it("grants INSERT on color_override alone and rechecks existing security boundaries", () => {
    expect(migration).toContain("GRANT INSERT (color_override) ON public.stage_activities TO jlproject_worker");
    expect(migration).not.toMatch(/GRANT\s+INSERT\s+ON\s+public\.stage_activities/i);
    expect(migration).not.toMatch(/GRANT\s+(?:UPDATE|DELETE|ALL)\b/i);
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE')");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE')");
  });
});
