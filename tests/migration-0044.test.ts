import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0044_clone_schedule_dependencies.sql", "utf8").replace(/\r\n/g, "\n");
const fixture = readFileSync("db/verification/phase4b3c4-clone-dependencies.sql", "utf8");
const preflight = readFileSync("db/verification/phase4b3c4-clone-preflight-owner.sql", "utf8");
const postflight = readFileSync("db/verification/phase4b3c4-clone-postflight-owner.sql", "utf8");
const seedOwner = readFileSync("db/verification/phase4b3c4-clone-seed-owner.sql", "utf8");
const seedImport = readFileSync("db/verification/phase4b3c4-clone-seed-worker-import.sql", "utf8");
const seedSchedule = readFileSync("db/verification/phase4b3c4-clone-seed-worker-schedule.sql", "utf8");
const seedStageDate = readFileSync("db/verification/phase4b3c4-clone-seed-worker-stage-date.sql", "utf8");
const seedDependencies = readFileSync("db/verification/phase4b3c4-clone-seed-owner-dependencies.sql", "utf8");
const seedStatus = readFileSync("db/verification/phase4b3c4-clone-seed-worker-status.sql", "utf8");
const archivedClone = readFileSync("db/migrations/0035_product_cloning_compatibility.sql", "utf8");

describe("clone dependency migration contract", () => {
  it("patches the existing clone and captures IDs from all three copy paths", () => {
    expect(migration).toContain("pg_get_functiondef('public.clone_product(uuid,uuid,uuid,text)'::regprocedure)");
    for (const mapping of ["v_stage.id::text, v_stage_id", "v_activity.id::text, v_activity_id",
      "v_root_activity.id::text, v_activity_id"]) expect(migration).toContain(mapping);
    expect(migration).toContain("AND product.active IN (true, false) FOR UPDATE");
    expect(migration).toContain("planning_classification = 'em_estudo'");
  });

  it("copies only scoped, one-to-one mappings and rolls back incomplete edge copies", () => {
    expect(migration).toContain("source.workspace_id = p_workspace AND source.product_id = p_source");
    expect(migration).toContain("target.workspace_id = p_workspace AND target.product_id = p_target");
    expect(migration).toContain("source_count = 1 AND target_count = 1");
    expect(migration).toContain("target.planned_start IS NOT DISTINCT FROM source.planned_start");
    expect(migration).toContain("target.planned_end IS NOT DISTINCT FROM source.planned_end");
    expect(migration).toContain("target.planning_calendar_version IS NOT DISTINCT FROM source.planning_calendar_version");
    expect(migration).toMatch(/INSERT INTO public\.product_schedule_dependencies\s+\(workspace_id/);
    expect(migration).toMatch(/FROM copied;\s+IF jsonb_array_length\(v_graph\) <> v_expected THEN\s+RAISE EXCEPTION/);
    for (const kind of ["activity", "stage"]) {
      expect(migration).toContain(`CASE WHEN edge.endpoint_kind = '${kind}' THEN predecessor.target_id END`);
      expect(migration).toContain(`CASE WHEN edge.endpoint_kind = '${kind}' THEN successor.target_id END`);
    }
  });

  it("writes the exact inserted graph to R00 while retaining empty import and legacy clone paths", () => {
    expect(migration).toContain("jsonb_set(p_snapshot, '{dependencies}', v_graph)");
    expect(migration).toContain("ORDER BY id), '[]'::jsonb)");
    expect(migration).toContain("IF v_expected = 0 THEN RETURN NULL; END IF;");
    expect(migration).toContain("IF v_revision_id IS NULL THEN");
    expect(migration).toContain("(import_batch_id IS NULL OR snapshot->'dependencies' = '[]'::jsonb)");
    expect(migration).toContain("initial_schedule_revisions_immutable");
    expect(migration).toContain("current_user <> 'jlproject_date_executor'");
    expect(migration).not.toMatch(/(?:UPDATE|DELETE FROM) public\.initial_schedule_revisions/i);
  });

  it("keeps general graph permissions dormant and records linked details in the clone operation", () => {
    expect(migration).toContain("active AND role IN ('admin', 'editor') FOR SHARE");
    expect(migration).toContain("xmin::text::bigint = txid_current() % 4294967296");
    expect(migration).toContain("transaction_id = pg_current_xact_id()");
    expect(migration).toContain("write_product_schedule_operation_event(p_workspace, p_target, p_actor, v_operation,");
    expect(migration).toContain("GRANT EXECUTE ON FUNCTION public.clone_schedule_dependencies");
    expect(migration).toContain("REVOKE TRIGGER ON public.initial_schedule_revisions FROM jlproject_date_executor");
    expect(migration).toContain("has_any_column_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT, INSERT, UPDATE')");
    expect(migration).not.toMatch(/GRANT EXECUTE ON FUNCTION public\.(?:confirm|read)_schedule_dependenc/);
  });

  it("runs clone mutations in a direct authenticated Worker session without role switching", () => {
    expect(fixture).toContain("current_user <> 'jlproject_worker'");
    expect(fixture).toContain("session_user <> 'jlproject_worker'");
    expect(fixture).toContain("active AND role = 'admin'");
    expect(fixture).toContain("active AND role = 'editor'");
    expect(fixture).toContain("active AND role = 'viewer'");
    expect(fixture).toContain("workspace_id = (v_scope->>'otherWorkspace')::uuid");
    expect(fixture).toContain("auth_user_id = v_editor");
    expect(fixture).not.toMatch(/\b(?:SET|RESET)\s+(?:LOCAL\s+)?ROLE\b/i);
    expect(fixture).toContain("has_table_privilege(current_user, 'public.product_schedule_dependencies', 'SELECT')");
    expect(fixture).toContain("v_reply#>>'{product,id}'");
    expect(fixture).toContain("MISSING_REMAP_TARGET");
    expect(fixture).toContain("EXCEPTION WHEN check_violation THEN");
    expect(fixture).toContain("v_error_state <> '23514'");
    expect(fixture).toContain("A dependency endpoint could not be remapped.");
    expect(fixture).toContain("v_source := (v_scope->>'vigente')::uuid");
    expect(fixture).toContain("VALUES (v_workspace, v_target, '{\"dependencies\":[{}]}'");
    expect(fixture).not.toContain("RESET ROLE;");
  });

  it("separates read-only owner snapshots and postflight from Worker execution", () => {
    expect(preflight).toContain("BEGIN READ ONLY;");
    expect(preflight).toContain("current_user <> 'neondb_owner'");
    expect(preflight).toContain("SOURCE_FINGERPRINT");
    expect(preflight).toContain("ROOT_EDGE");
    expect(preflight).toContain("edge.product_id = (v_scope->>'vigente')::uuid");
    expect(preflight).toContain("OWNER_CAN_SET_WORKER");
    expect(preflight).toContain("pg_has_role('neondb_owner', 'jlproject_worker', 'SET')");
    expect(postflight).toContain("BEGIN READ ONLY;");
    expect(postflight).toContain("current_user <> 'neondb_owner'");
    expect(postflight).toContain("source product %, its schedule, graph, R00 or audit");
    expect(postflight).toContain("product_schedule_operations WHERE product_id = v_missing) <> 1");
    expect(postflight).toContain("schedule_version FROM public.product_schedule_state WHERE product_id = v_missing) <> 1");
    expect(fixture).toContain("A dependency endpoint could not be remapped.");
    expect(postflight).toContain("snapshot->'dependencies'");
    expect(postflight).toContain("event.new_values = edge.value");
    expect(postflight).toContain("Copied dependency events are not grouped in one clone operation.");
    expect(preflight).toMatch(/ROLLBACK;\s*$/);
    expect(postflight).toMatch(/ROLLBACK;\s*$/);
    expect(fixture).toMatch(/COMMIT;\s*$/);
  });

  it("keeps archived root cloning in the public workflow and checks both clone roots in R00", () => {
    expect(archivedClone).toContain("replace(v_definition, v_anchor, 'AND id = p_source_product_id')");
    expect(archivedClone).toContain("AND created_by = p_actor_id AND xmin::text::bigint = txid_current()");
    expect(migration).toContain("v_root_activity.id::text, v_activity_id");
    expect(preflight).toContain("edge.product_id = (v_scope->>'archived')::uuid");
    expect(postflight).toContain("target_pred.stage_id IS NULL AND target_pred.discipline_id IS NULL");
    expect(postflight).toContain("target_succ.stage_id IS NULL AND target_succ.discipline_id IS NULL");
    expect(postflight).toContain("A linked source root edge did not reach the clone root schedule and R00.");
    expect(postflight).toContain("r.snapshot->'rootActivities' @> jsonb_build_array(");
    expect(postflight).toContain("jsonb_build_object('id', target_pred.id), jsonb_build_object('id', target_succ.id)");
  });

  it("seeds clone sources through authorized public workflows without fabricating R00", () => {
    for (const seed of [seedImport, seedSchedule, seedStageDate, seedStatus]) {
      expect(seed).toContain("phase4b5_disposable_child_verified");
      expect(seed).toContain("current_user <> 'jlproject_worker'");
      expect(seed).toContain("session_user <> 'jlproject_worker'");
      expect(seed).not.toMatch(/INSERT\s+INTO\s+public\.initial_schedule_revisions/i);
    }
    expect(seedOwner).toContain("phase4b5-seed-safety-owner.sql");
    expect(seedOwner).toContain("phase4b5-seed-r00-postflight-owner.sql");
    expect(seedImport).toContain("public.import_initial_schedule(");
    expect(seedImport).toContain("snapshot->'dependencies' = '[]'::jsonb");
    expect(seedStageDate).toContain("public.change_discipline_stage_dates(");
    expect(seedSchedule).toContain("public.create_activity_with_working_plan(");
    expect(seedDependencies).toContain("phase4b5-seed-one-dependency.sql");
    expect(seedDependencies).not.toMatch(/INSERT\s+INTO\s+public\.product_schedule_dependencies/i);
    expect(seedStatus).toContain("public.change_product_status(");
    expect(seedStatus).toContain("'arquivado'");
  });

  it("requires two distinct root creation events under each committed root setup operation", () => {
    for (const source of ["vigente", "archived"]) {
      const operationId = seedSchedule.match(
        new RegExp(String.raw`\\set test_product :${source}_product\s+\\set test_operation ([0-9a-f-]+)\s+BEGIN;`),
      )?.[1];
      expect(operationId, source).toBeDefined();
      expect(seedDependencies).toContain(`((v_scope->>'${source}')::uuid, '${source}', '${operationId}'::uuid)`);
    }
    expect(seedDependencies).toContain("event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id");
    expect(seedDependencies).toContain("event.schedule_version = operation.schedule_version AND event.operation_id = operation.operation_id");
    expect(seedDependencies).toContain("operation.operation_id = v_source.root_operation_id AND operation.actor_id = v_actor");
    expect(seedDependencies).toContain("root.id = event.entity_id AND root.deleted_at IS NULL");
    expect(seedDependencies).toContain("root.stage_id IS NULL AND root.discipline_id IS NULL");
    expect(seedDependencies).toContain("AND event.entity_type = 'stage_activities' AND event.change_type = 'stage_activities_created'");
    expect(seedDependencies).toContain("HAVING count(*) = 2 AND count(DISTINCT root.id) = 2");
    expect(seedDependencies).not.toMatch(/'stage_activities_created'\)\s*<>\s*4/);
    expect(seedDependencies).toContain("AND stage_id IS NOT NULL) <> 41");
    expect(seedDependencies).toContain("AND discipline_id IS NULL) <> (CASE WHEN v_source.root_operation_id IS NOT NULL THEN 2 ELSE 0 END)");
    for (const auditSnapshot of [preflight, postflight]) {
      expect(auditSnapshot).toContain("FROM public.product_schedule_operation_events e WHERE e.product_id = p.id");
    }
  });

  it("compares the original six R00 rows across source seeding and clone execution", () => {
    expect(seedOwner).toContain("historical_r00_fingerprint");
    expect(seedDependencies).toContain("'historicalFingerprint'");
    expect(preflight).toContain("HISTORICAL_R00_BASELINE");
    expect(postflight).toContain("historicalR00Fingerprint");
    expect(postflight).toContain("v_historical_count + 8");
  });
});
