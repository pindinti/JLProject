import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync("db/migrations/0043_guard_schedule_deletion_dependencies.sql", "utf8").replace(/\r\n/g, "\n");
const verification = readFileSync("db/verification/phase4b3c3-schedule-deletion.sql", "utf8").replace(/\r\n/g, "\n");

describe("schedule deletion dependency guard migration", () => {
  it("requires the reviewed dependency guards and preserves the private Worker deletion boundary", () => {
    expect(migration).toContain("public.guard_activity_reparent_dependencies(uuid,uuid,uuid,uuid,uuid)");
    expect(migration).toContain("public.dependency_effective_date_interval(uuid,uuid,text,uuid,text,uuid,date,date)");
    expect(migration).toContain("public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)");
    expect(migration).toContain("public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)");
    expect(migration).toContain("product_disciplines_deletion_guard");
    expect(migration).toContain("discipline_stages_deletion_guard");
    expect(migration).toContain("stage_activities_deletion_guard");
    expect(migration).toContain("FROM PUBLIC, jlproject_worker, neondb_owner;");
    expect(migration).toContain("has_column_privilege('jlproject_worker', 'public.stage_activities', 'deleted_at', 'UPDATE')");
    expect(migration).toMatch(/^BEGIN;\s/);
    expect(migration).toMatch(/COMMIT;\s*$/);
  });

  it("names every postflight failure and treats indeterminate privileges as failures", () => {
    const postflight = migration.slice(migration.indexOf("DO $postflight$"));
    const checks = [
      "dependency_stage_interval_after_deletion_owner",
      "guard_schedule_deletion_dependencies_owner",
      "preview_calls_deletion_guard",
      "delete_invokes_guarded_preview",
      "delete_handles_dependency_conflict_before_writes",
      "delete_takes_workspace_lock",
      "worker_cannot_execute_deletion_guard",
      "worker_cannot_execute_stage_interval_helper",
      "worker_can_execute_preview",
      "worker_can_execute_delete",
      "worker_cannot_update_activity_deleted_at",
      "worker_cannot_update_stage_deleted_at",
      "worker_cannot_update_discipline_deleted_at",
      "worker_is_not_date_executor_member",
      "owner_cannot_set_date_executor",
      "date_executor_has_no_public_create"
    ];

    for (const check of checks) expect(postflight).toContain(`'${check}'`);
    expect(postflight).toContain("WHERE checks.failed IS DISTINCT FROM false;");
    expect(postflight).toContain("IF cardinality(v_failed) > 0 THEN");
    expect(postflight).toContain("USING DETAIL = array_to_string(v_failed, ', ');");
    expect(postflight).toContain("IS DISTINCT FROM 'jlproject_date_executor'");
    expect(postflight).toContain("IS DISTINCT FROM true");
    expect(postflight).toContain("v_preview_call IN v_delete_definition");
    expect(postflight).toContain("v_conflict_handler IN v_delete_definition");
    expect(postflight).toContain("v_conflict_stale_check IN v_delete_definition");
    expect(postflight).toContain("v_conflict_return IN v_delete_definition");
    expect(postflight).toContain("position(v_preview_call IN v_delete_definition) >=\n        position(v_conflict_handler IN v_delete_definition)");
    expect(postflight).toContain("position(v_conflict_stale_check IN v_delete_definition) <=\n        position(v_conflict_handler IN v_delete_definition)");
    expect(postflight).toContain("position(v_conflict_return IN v_delete_definition) <=\n        position(v_conflict_stale_check IN v_delete_definition)");
    for (const write of ["INSERT INTO public.schedule_deletion_events",
      "UPDATE public.stage_activities AS a SET deleted_at =",
      "UPDATE public.discipline_stages AS s SET deleted_at =",
      "UPDATE public.product_disciplines AS d SET deleted_at ="]) {
      expect(postflight).toContain(write);
      expect(postflight).toContain(
        `position(v_conflict_handler IN v_delete_definition) >=\n        position('${write}' IN v_delete_definition)`
      );
    }
  });

  it("blocks every deleted dependency endpoint, including endpoints in descendants", () => {
    expect(migration).toContain("'reason', 'linked_endpoint'");
    expect(migration).toContain("'linkedEndpoint', v_edge.linked_endpoint");
    expect(migration).toContain("jsonb_to_recordset(p_deleted_items)");
    expect(migration).toContain("edge.predecessor_activity_id");
    expect(migration).toContain("edge.successor_activity_id");
    expect(migration).toContain("edge.predecessor_stage_id");
    expect(migration).toContain("edge.successor_stage_id");
    expect(migration).toContain("v_dependency_conflict->'conflict'");
  });

  it("projects all removed children together and keeps explicit or partial D065 stage dates fixed", () => {
    expect(migration).toContain("NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_deleted_items)");
    expect(migration).toContain("stage.planned_start IS NULL AND stage.planned_end IS NULL");
    expect(migration).toContain("public.dependency_stage_interval_after_deletion");
    expect(migration).toContain("activity.discipline_id IS NOT DISTINCT FROM stage.discipline_id");
    expect(migration).toContain("edge.predecessor_stage_id IN (SELECT activity.stage_id");
    expect(migration).toContain("edge.successor_stage_id IN (SELECT activity.stage_id");
    expect(migration).toContain("v_new_bound - v_new_start > v_old_bound - v_old_start");
  });

  it("rechecks under workspace and product locks before writes and checks stale fingerprints first", () => {
    expect(migration).toContain("PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE;");
    expect(migration).toContain("AND p.workspace_id = p_workspace_id AND p.active = true FOR UPDATE");
    expect(migration).toContain("IF v_preview->>'fingerprint' <> p_fingerprint THEN RETURN jsonb_build_object('status', 'stale'); END IF;");
    expect(migration).toContain("IF v_preview->>'status' = 'dependency_conflict' THEN");
    expect(migration).toContain("v_preview := public.preview_schedule_deletion(p_workspace_id,p_product_id,p_actor_id,p_kind,p_target_id);");
    expect(migration).toContain("INSERT INTO public.schedule_deletion_events");
    expect(migration).toContain("public.guard_schedule_deletion_dependencies(p_workspace_id, p_product_id, v_items)");
    expect(migration).toContain("position('PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR SHARE'");
  });

  it("prepares rollback-only coverage for linked endpoints, boundaries, atomicity, and empty graphs", () => {
    expect(verification).toMatch(/^--[\s\S]*?\nBEGIN;\s/);
    expect(verification).toMatch(/ROLLBACK;\s*$/);
    const lowerVerification = verification.toLowerCase();
    for (const expected of ["directly linked activity", "directly linked stage", "linked descendant",
      "stale fingerprint", "missing boundary", "safe unlinked activity", "explicit-stage", "partial-stage",
      "viewer authorization", "empty dependency graphs", "unique_violation", "schedule or audit writes"]) {
      expect(lowerVerification).toContain(expected);
    }
    expect(verification).toContain("'partialProduct', :'test_partial_product'");
    expect(verification).toContain("product_id = v_partial_product AND id = v_partial_stage");
    expect(verification).toContain("preview_schedule_deletion(v_workspace, v_partial_product");
    expect(verification).toContain("delete_schedule_subtree(v_workspace, v_partial_product");
  });

  it("requires the first matching child edge and independently checks a direct stage edge", () => {
    const seed = readFileSync("db/verification/phase4b3c3-schedule-deletion-seed-owner.sql", "utf8");
    const edges = readFileSync("db/verification/phase4b3c3-schedule-deletion-seed-owner-dependencies.sql", "utf8");
    expect(migration).toContain("ORDER BY edge.id LIMIT 1;");
    expect(seed).toContain("000000000101'::uuid AS test_linked_activity_dependency");
    expect(seed).toContain("000000000102'::uuid AS test_linked_stage_dependency");
    expect(seed).toContain(":'test_linked_activity', :'test_workspace', :'test_linked_product', :'linked_discipline', :'test_linked_stage'");
    const isolated = edges.slice(edges.indexOf("\\set test_product :test_descendant_product"), edges.indexOf("\\set test_product :test_missing_product"));
    expect(isolated).toContain("\\set test_edge_id :test_descendant_dependency");
    expect(isolated).toContain("\\set test_endpoint_kind stage");
    expect(isolated).toContain("\\set test_predecessor_id :test_descendant_stage");
    expect(isolated.match(/\\i db\/verification\/phase4b5-seed-one-dependency\.sql/g)).toHaveLength(1);
    expect(verification).toMatch(/'stage containing a linked activity', v_linked_product, 'stage', v_linked_stage,\s+v_linked_activity_dependency, 'activity', v_linked_activity/);
    expect(verification).toMatch(/'directly linked stage', v_descendant_product, 'stage', v_descendant_stage,\s+v_descendant_dependency, 'stage', v_descendant_stage/);
    expect(verification).toContain("v_preview#>>'{conflict,linkedEndpoint,id}' IS DISTINCT FROM v_rejection.endpoint_id::text");
    expect(verification).toContain("v_preview#>>'{conflict,linkedEndpoint,kind}' IS DISTINCT FROM v_rejection.endpoint_kind");
    expect(verification).toContain("v_result IS DISTINCT FROM v_preview");
    expect(verification).toContain("v_tree_state IS DISTINCT FROM v_tree_before");
    expect(verification).toContain("v_collision_constraint IS DISTINCT FROM 'schedule_deletion_events_pkey'");
  });
});
