import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0030_multi_entity_audit_grouping.sql", "utf8");
const integration = readFileSync("db/verification/phase1-0030-rollback.sql", "utf8");
const stageDateAudit = readFileSync("db/migrations/0028_stage_date_planning_audit.sql", "utf8");
const scheduleAudit = readFileSync("db/migrations/0029_living_schedule_audit_concurrency.sql", "utf8");

describe("migration 0030 multi-entity audit grouping", () => {
  it("is a guarded transactional Development correction with additive audit storage", () => {
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
    expect(migration).toContain("current_user <> 'neondb_owner'");
    expect(migration).toContain("current_database() <> 'neondb'");
    expect(migration).toContain("public.stage_date_changes");
    expect(migration).toContain("public.product_schedule_operation_source_events");
    expect(migration).toContain("LOCK TABLE public.stage_date_changes");
    expect(migration).not.toMatch(/^\s*(DROP\s+(TABLE|COLUMN)|TRUNCATE\s)/im);
    expect(migration).not.toMatch(/(?:INSERT|UPDATE|DELETE)\s+public\.initial_schedule_revisions/i);
    expect(migration).not.toMatch(/(?:INSERT|UPDATE|DELETE)\s+public\.(products|product_disciplines|discipline_stages|stage_activities|business_targets)\b/i);
  });

  it("separates stable operation groups from exact immutable stage-date events", () => {
    expect(migration).toContain("ALTER TABLE public.stage_date_changes ADD COLUMN event_id uuid");
    expect(migration).toContain("UPDATE public.stage_date_changes SET event_id = operation_id");
    expect(migration).toContain("ALTER COLUMN event_id SET DEFAULT gen_random_uuid()");
    expect(migration).toContain("ALTER COLUMN event_id SET NOT NULL");
    expect(migration).toContain("PRIMARY KEY USING INDEX stage_date_changes_event_id_uidx");
    expect(migration).toContain("stage_date_changes_stage_version_unique");
    expect(migration).toContain("stage_date_changes_operation_group_idx");
    expect(migration).toContain("stage_date_changes_append_only");
    expect(migration).toMatch(/DISABLE TRIGGER stage_date_changes_append_only[\s\S]*?UPDATE public\.stage_date_changes SET event_id = operation_id[\s\S]*?ENABLE TRIGGER stage_date_changes_append_only/);
  });

  it("stores exact source event IDs while retaining the old operation links", () => {
    expect(migration).toContain("product_schedule_operation_source_events_pkey PRIMARY KEY");
    expect(migration).toContain("source_operation_id uuid NOT NULL");
    expect(migration).toContain("source_event_id uuid NOT NULL");
    expect(migration).toContain("product_schedule_operation_events_source_links");
    expect(migration).toContain("audit.operation_id = NEW.operation_id");
    expect(migration).toContain("audit.event_id, 'audit_detail'");
    expect(migration).toContain("reversal.reversal_date_operation_id");
    expect(migration).toContain("reversal.original_date_operation_id");
    expect(migration).toContain("'activity_date_changes', reversal.reversal_date_operation_id");
    expect(migration).toContain("source.source_event_id = audit.reversal_date_operation_id");
    expect(migration).toContain("source.source_event_id = reversal.original_date_operation_id");
    expect(migration).not.toMatch(/UPDATE\s+public\.product_schedule_operation_links/i);
    expect(migration).not.toMatch(/DELETE\s+FROM\s+public\.product_schedule_operation_links/i);
  });

  it("associates standalone stage-date ledger events after the Living Schedule event exists", () => {
    const stageAuditLink = migration.match(/CREATE OR REPLACE FUNCTION public\.link_product_schedule_audit_source\(\)[\s\S]*?\n\$\$;/)?.[0];
    const operationEventLink = migration.match(/CREATE FUNCTION public\.link_product_schedule_operation_source_events\(\)[\s\S]*?\n\$\$;/)?.[0];

    expect(stageAuditLink).toBeDefined();
    expect(stageAuditLink).toContain("IF NOT FOUND THEN RETURN NEW; END IF;");
    expect(stageAuditLink).toContain("product_schedule_operation_links");
    expect(stageDateAudit).toMatch(/CREATE TRIGGER discipline_stages_dates_audited\s+BEFORE INSERT OR UPDATE ON public\.discipline_stages/);
    expect(stageDateAudit).toContain("INSERT INTO public.stage_date_changes (");
    expect(scheduleAudit).toMatch(/CREATE TRIGGER discipline_stages_schedule_audit\s+AFTER INSERT OR UPDATE OR DELETE ON public\.discipline_stages/);
    expect(scheduleAudit).toMatch(/CREATE TRIGGER stage_date_changes_schedule_link\s+AFTER INSERT ON public\.stage_date_changes/);
    expect(operationEventLink).toBeDefined();
    expect(operationEventLink).toContain("'stage_date_changes', audit.operation_id, audit.event_id, 'audit_detail'");
    expect(migration).toContain("CREATE TRIGGER product_schedule_operation_events_source_links");
    expect(migration).toContain("AFTER INSERT ON public.product_schedule_operation_events");
  });

  it("preserves history keys, returns operation IDs, and keeps privileged readers private", () => {
    expect(migration).toContain("change.operation_id::text");
    expect(migration).toContain("change.event_id::text");
    expect(migration).toContain("'operationId', change.operation_id::text");
    expect(migration).toContain("'eventId', source.source_event_id");
    expect(migration).toContain("SECURITY DEFINER SET search_path = pg_catalog, pg_temp");
    expect(migration).toContain("REVOKE ALL ON public.product_schedule_operation_source_events FROM PUBLIC, jlproject_worker");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.list_product_schedule_operations");
    expect(migration).toContain("has_table_privilege('jlproject_worker'");
    expect(migration).toContain("REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor");
    expect(migration).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner");
    expect(migration).toContain("function.proconfig @> ARRAY['search_path=pg_catalog, pg_temp']");
  });

  it("asserts complete exact backfill for grouped, calendar, and reversal source links", () => {
    expect(migration).toContain("Migration 0030 left an ambiguous or missing specialized audit source link.");
    expect(migration).toContain("legacy.source_ledger = 'calendar_reschedule_reversals'");
    expect(migration).toContain("legacy.source_ledger IN ('calendar_reschedule_reversals'");
    expect(migration).toContain("source.link_kind = 'reversal_of'");
    expect(migration).toContain("source.source_event_id = audit.event_id");
    expect(migration).toContain("source.source_event_id = audit.operation_id");
    expect(migration).toContain("source.source_event_id = audit.date_operation_id");
    expect(migration).toContain("source.source_event_id = audit.reversal_date_operation_id");
  });

  it("prepares rollback-only database coverage for grouped stages, failure atomicity, and exact reversals", () => {
    expect(integration).toContain("Rollback-only integration coverage for Living Schedule migration 0030");
    expect(integration).toContain("v_distinct_stage_event_ids <> 3");
    expect(integration).toContain("$single_stage_test$");
    expect(integration).toContain("Intentional rollback-only audit atomicity probe.");
    expect(integration).toContain("activity.value->>'eventId' = calendar.value->>'eventId'");
    expect(integration).toContain("original.value->>'eventId' = reversal_of.value->>'eventId'");
    expect(integration).not.toContain("COMMIT;");
    expect(integration.match(/^ROLLBACK;$/gm)?.length).toBe(4);
  });
});
