import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0027_product_change_history_hierarchy_movement.sql", "utf8");

describe("migration 0027 product hierarchy movement history integration", () => {
  it("is transactional, versioned, and fails closed on unexpected schema or role state", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("public.hierarchy_movement_events");
    expect(migration).toContain("<> 'jlproject_date_executor'");
    expect(migration).toContain("history function source differs from the reviewed migration 0022 definition");
    expect(migration).toContain("v_anchor constant text := '  ), eligible AS MATERIALIZED ('");
    expect(migration).toContain("length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor)");
  });

  it("adds one product-scoped event per immutable movement row with names, hierarchy, positions, and actor time", () => {
    expect(migration.match(/SELECT 'hierarchy-movement:' \|\| movement\.operation_id::text/g)).toHaveLength(1);
    expect(migration).toContain("movement.changed_at");
    expect(migration).toContain("movement.actor_id");
    expect(migration).toContain("'hierarchy_moved'");
    expect(migration).toContain("movement.item_kind");
    expect(migration).toContain("movement.original_display_order + 1");
    expect(migration).toContain("movement.new_display_order + 1");
    expect(migration).toContain("movement.original_discipline_id");
    expect(migration).toContain("movement.original_stage_id");
    expect(migration).toContain("movement.new_discipline_id");
    expect(migration).toContain("movement.new_stage_id");
    expect(migration).toContain("movement.descendant_activity_ids");
    expect(migration).toContain("WHERE movement.workspace_id = p_workspace_id AND movement.product_id = p_product_id");
    expect(migration).toContain("'scope', 'product_root'");
    expect(migration).toContain("LEFT JOIN public.discipline_stages AS stage");
    expect(migration).toContain("LEFT JOIN public.product_disciplines AS discipline");
    expect(migration).toContain("CASE WHEN activity.stage_id IS NULL");
    expect(migration).not.toMatch(/INSERT\s+INTO\s+public\.hierarchy_movement_events/i);
  });

  it("keeps Worker access limited to the function and restores temporary owner privileges", () => {
    expect(migration).toContain("GRANT CREATE ON SCHEMA public TO jlproject_date_executor");
    expect(migration).toContain("WITH INHERIT FALSE, SET TRUE");
    expect(migration).toContain("SET ROLE jlproject_date_executor");
    expect(migration).toContain("RESET ROLE");
    expect(migration).toContain("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
    expect(migration).toContain("has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')");
    expect(migration).toContain("has_function_privilege('jlproject_worker'");
    expect(migration).toContain("has_function_privilege('public'");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')");
  });
});
