// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0023_activity_color_overrides.sql", "utf8");

describe("activity color override migration", () => {
  it("adds only a nullable validated override and a narrow Worker update grant", () => {
    expect(migration).toContain("ADD COLUMN color_override text");
    expect(migration).toContain("color_override IS NULL OR color_override ~ '^#[0-9A-Fa-f]{6}$'");
    expect(migration).toContain("GRANT UPDATE (color_override) ON public.stage_activities TO jlproject_worker");
    expect(migration).not.toMatch(/GRANT UPDATE ON public\.stage_activities/);
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE')");
  });

  it("copies overrides into the clone and its independent R00 snapshot", () => {
    expect(migration).toContain("v_activity.color_override, p_actor_id, p_actor_id");
    expect(migration).toContain("'colorOverride', v_activity.color_override");
    expect(migration).toContain("'revisionLabel', 'R00'");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE')");
  });
});
