import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0032_unified_living_schedule_change_history.sql", "utf8");

describe("migration 0032 unified Living Schedule history", () => {
  it("is a guarded transaction that leaves schedule rows and R00 snapshots untouched", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("pg_get_functiondef(v_signature::regprocedure)");
    expect(migration).toContain("public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)");
    expect(migration).not.toMatch(/^\s*(DROP\s+(TABLE|COLUMN|FUNCTION)|TRUNCATE\s)/im);
    expect(migration).not.toMatch(/(?:UPDATE|DELETE)\s+public\.(products|product_disciplines|discipline_stages|stage_activities|business_targets|initial_schedule_revisions)\b/i);
    expect(migration).not.toMatch(/INSERT\s+INTO\s+public\.initial_schedule_revisions\b/i);
  });

  it("keeps the function signature and replaces only the reviewed history query", () => {
    expect(migration).toContain("v_anchor constant text := '  ), eligible AS MATERIALIZED ('");
    expect(migration).toContain("v_old_event_source constant text := 'SELECT event.* FROM event_feed AS event'");
    expect(migration).toContain("v_new_event_source constant text := 'SELECT event.* FROM logical_feed AS event'");
    expect(migration).toContain("event.operation_id::text");
    expect(migration).toContain("event.reversal_of_operation_id::text");
    expect(migration).toContain("event.source_event_types");
    expect(migration).toContain("event.details");
    expect(migration).toContain("event.occurred_at DESC, event.event_id COLLATE \"C\" DESC");
    expect(migration).toContain("LIMIT p_limit + 1");
    expect(migration).toContain("candidate_operations AS MATERIALIZED");
    expect(migration).toContain("product_schedule_operations_history_time_idx");
    expect(migration).toContain("FROM logical_feed AS event");
    const sourceLinkCte = migration.slice(
      migration.indexOf("), source_event_entities AS ("),
      migration.indexOf("), generic_entity_counts AS (")
    );
    expect(sourceLinkCte.match(/WHERE source\.workspace_id = p_workspace_id AND source\.product_id = p_product_id/g)).toHaveLength(9);
  });

  it("deduplicates only unambiguous exact source-event matches", () => {
    expect(migration).toContain("audit.event_id = source.source_event_id");
    expect(migration).toContain("generic.detail_count = 1 AND source.source_count = 1");
    expect(migration).toContain("source.source_ledger");
    expect(migration).toContain("source.entity_type = generic.entity_type");
    expect(migration).toContain("source.entity_id = generic.entity_id");
    expect(migration).toContain("source.source_operation_id = split_part(event.event_id, ':', 2)::uuid");
    expect(migration).toContain("source.source_event_id = split_part(event.event_id, ':', 2)::uuid");
    expect(migration).toContain("generic_details AS (");
    expect(migration).toContain("position('dates_changed' IN event.change_type) > 0");
    expect(migration).not.toContain("DISTINCT ON (operation.operation_id)");
  });

  it("forms complete operation groups before applying the stable cursor and page limit", () => {
    const groupPosition = migration.indexOf("), logical_feed AS (");
    const eligiblePosition = migration.indexOf("), eligible AS MATERIALIZED ($feed$");
    expect(groupPosition).toBeGreaterThan(-1);
    expect(eligiblePosition).toBeGreaterThan(groupPosition);
    expect(migration).toContain("CASE WHEN event.operation_id IS NULL THEN 'legacy:' || event.event_id");
    expect(migration).toContain("'operation:' || event.operation_id::text");
    expect(migration).toContain("array_agg(DISTINCT event.event_type ORDER BY event.event_type)");
    expect(migration).toContain("jsonb_array_elements(event.details) WITH ORDINALITY");
  });

  it("keeps the Worker execute-only and confines provenance writes to an executor trigger", () => {
    expect(migration).toContain("CREATE FUNCTION public.link_product_schedule_history_provenance()");
    expect(migration).toContain("SECURITY DEFINER SET search_path = pg_catalog, pg_temp");
    expect(migration).toContain("CREATE CONSTRAINT TRIGGER products_z_history_source_link");
    expect(migration).toContain("CREATE CONSTRAINT TRIGGER import_batches_z_history_source_link");
    expect(migration).toContain("DEFERRABLE INITIALLY DEFERRED");
    expect(migration).toContain("'products', product.id, product.id, 'audit_detail'");
    expect(migration).toContain("'import_batches', batch.id, batch.id, 'audit_detail'");
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.link_product_schedule_history_provenance() FROM PUBLIC, jlproject_worker");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT')");
    expect(migration).toContain("has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT')");
    expect(migration).toContain("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
    expect(migration).not.toMatch(/GRANT\s+(SELECT|INSERT|UPDATE|DELETE|ALL)\s+ON\s+public\.(product_schedule_operation_events|product_schedule_operation_source_events)\s+TO\s+jlproject_worker/i);
  });
});
