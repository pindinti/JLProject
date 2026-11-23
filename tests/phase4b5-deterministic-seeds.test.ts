import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { calculateWorkingDayEndDate } from "../domain/working-day-calculation";

const read = (path: string) => readFileSync(path, "utf8");
const verificationDir = "db/verification/";
const runbook = read("docs/verification/PHASE-4B5-EXECUTION-ORDER.md");

const fixtureStages: Array<{
  migration: string;
  owner: string;
  runtime: string;
  extra?: string[];
  ownerAfter?: string;
  postOwner?: string[];
}> = [
  {
    migration: "0038_guard_individual_schedule_dates.sql",
    owner: "phase4b3a-date-guard-seed-owner.sql",
    runtime: "phase4b3a-guard-date-writers.sql",
  },
  {
    migration: "0039_guard_calendar_reschedule_apply.sql",
    owner: "phase4b3b1-calendar-apply-seed-owner.sql",
    runtime: "phase4b3b1-calendar-apply.sql",
    extra: ["phase4b3b1-calendar-setup-worker.sql"],
  },
  {
    migration: "0040_guard_calendar_reschedule_reversal.sql",
    owner: "phase4b3b2-calendar-reversal-seed-owner.sql",
    runtime: "phase4b3b2-calendar-reversal.sql",
    extra: [
      "phase4b3b2-calendar-reversal-seed-worker.sql",
      "phase4b3b2-calendar-reversal-dependencies-owner.sql",
    ],
  },
  {
    migration: "0041_guard_activity_creation_dependencies.sql",
    owner: "phase4b3c1-activity-creation-seed-owner.sql",
    runtime: "phase4b3c1-activity-creation.sql",
    extra: ["phase4b3c1-activity-creation-seed-worker-stage-dates.sql"],
    ownerAfter: "phase4b3c1-activity-creation-seed-owner-dependencies.sql",
  },
  {
    migration: "0042_guard_hierarchy_move_dependencies.sql",
    owner: "phase4b3c2-hierarchy-move-seed-owner.sql",
    runtime: "phase4b3c2-hierarchy-move.sql",
    extra: ["phase4b3c2-hierarchy-move-seed-worker-stage-dates.sql"],
    ownerAfter: "phase4b3c2-hierarchy-move-seed-owner-dependencies.sql",
  },
  {
    migration: "0043_guard_schedule_deletion_dependencies.sql",
    owner: "phase4b3c3-schedule-deletion-seed-owner.sql",
    runtime: "phase4b3c3-schedule-deletion.sql",
    extra: ["phase4b3c3-schedule-deletion-seed-worker-stage-dates.sql"],
    ownerAfter: "phase4b3c3-schedule-deletion-seed-owner-dependencies.sql",
    postOwner: [
      "phase4b3c3-schedule-deletion-collision-preflight-owner.sql",
      "phase4b3c3-schedule-deletion-seed-worker.sql",
      "phase4b3c3-schedule-deletion-collision-postflight-owner.sql",
    ],
  },
];

describe("Phase 4B.5 deterministic fixture seeds", () => {
  it("places each stage-specific seed after its migration and before its runtime fixture", () => {
    for (const stage of fixtureStages) {
      const migrationPosition = runbook.indexOf(stage.migration);
      const ownerPosition = runbook.indexOf(stage.owner);
      const runtimePosition = runbook.indexOf(stage.runtime);
      expect(migrationPosition, stage.migration).toBeGreaterThanOrEqual(0);
      expect(ownerPosition, stage.owner).toBeGreaterThan(migrationPosition);
      expect(runtimePosition, stage.runtime).toBeGreaterThan(ownerPosition);
      for (const extra of stage.extra ?? []) {
        expect(runbook.indexOf(extra), extra).toBeGreaterThan(ownerPosition);
        expect(runbook.indexOf(extra), extra).toBeLessThan(runtimePosition);
      }
      if (stage.ownerAfter) {
        const ownerAfterPosition = runbook.indexOf(stage.ownerAfter);
        expect(ownerAfterPosition, stage.ownerAfter).toBeGreaterThan(ownerPosition);
        expect(ownerAfterPosition, stage.ownerAfter).toBeLessThan(runtimePosition);
        for (const extra of stage.extra ?? []) {
          expect(ownerAfterPosition, `${stage.ownerAfter} follows ${extra}`).toBeGreaterThan(runbook.indexOf(extra));
        }
      }
      for (const postOwner of stage.postOwner ?? []) {
        const postOwnerPosition = runbook.indexOf(postOwner);
        expect(postOwnerPosition, postOwner).toBeGreaterThan(runbook.indexOf(stage.ownerAfter ?? stage.owner));
        expect(postOwnerPosition, postOwner).toBeLessThan(runtimePosition);
      }
    }
  });

  it("keeps owner setup behind the child gate and fingerprints the historical R00 rows", () => {
    const owners = fixtureStages.map((stage) => read(verificationDir + stage.owner));
    owners.push(...fixtureStages.flatMap((stage) => stage.ownerAfter
      ? [read(verificationDir + stage.ownerAfter)] : []));
    owners.push(read(verificationDir + "phase4b3b2-calendar-reversal-dependencies-owner.sql"));
    for (const source of owners) {
      expect(source).toContain("phase4b5-seed-safety-owner.sql");
      expect(source).toContain("phase4b5-seed-r00-postflight-owner.sql");
      expect(source.includes("COMMIT;") || source.includes("phase4b5-seed-one-dependency.sql")).toBe(true);
      expect(source).not.toMatch(/\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+public\.initial_schedule_revisions\b/i);
    }
    const safety = read(verificationDir + "phase4b5-seed-safety-owner.sql");
    const postflight = read(verificationDir + "phase4b5-seed-r00-postflight-owner.sql");
    expect(safety).toContain("phase4b5_disposable_child_verified");
    expect(safety).toContain("count(*) FROM public.initial_schedule_revisions) <> 6");
    expect(postflight).toContain("phase4b5_seed_r00_baseline");
    expect(postflight).toContain("changed historical R00 rows");
  });

  it("matches every runtime psql variable to its committed setup output", () => {
    for (const stage of fixtureStages) {
      const runtime = read(verificationDir + stage.runtime);
      const seed = read(verificationDir + stage.owner);
      const variables = [...runtime.matchAll(/:'(test_[a-z0-9_]+)'/g)].map((match) => match[1]);
      const emittedVariables = seed.split(/\r?\n/)
        .filter((line) => line.startsWith("\\echo Worker psql variables"))
        .join("\n");
      for (const variable of new Set(variables)) {
        if (variable === "test_calendar_version") {
          expect(runbook).toContain("calendar versions 1 and 2");
          expect(emittedVariables).toContain("test_calendar_version=2");
          continue;
        }
        expect(seed, `${stage.owner} must emit ${variable}`).toMatch(
          new RegExp(`(?:AS\\s+${variable}\\b|\\\\set\\s+${variable}\\b|\\\\echo[^\\n]*:${variable}\\b)`, "i"),
        );
        expect(emittedVariables, `${stage.owner} must print ${variable}`).toContain(`${variable}=`);
      }
    }
  });

  it("creates dependency rows only through one audited confirmation per transaction", () => {
    const helper = read(verificationDir + "phase4b5-seed-one-dependency.sql");
    expect(helper).toContain("public.confirm_schedule_dependencies(");
    expect(helper).toContain("change_type = 'dependency_added'");
    expect(helper).toContain("edge.predecessor_activity_id = v_predecessor");
    expect(helper).toContain("edge.predecessor_stage_id = v_predecessor");
    expect(helper).toContain("GRANT jlproject_date_executor TO neondb_owner");
    expect(helper).toContain("RESET ROLE;");
    expect(helper).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
    expect(helper).toContain("COMMIT;");
    expect(helper).not.toMatch(/INSERT\s+INTO\s+public\.product_schedule_dependencies/i);
  });

  it("commits the deletion collision through the authorized Worker preview and writer", () => {
    const seed = read(verificationDir + "phase4b3c3-schedule-deletion-seed-worker.sql");
    expect(seed).toContain("current_user <> 'jlproject_worker'");
    expect(seed).toContain("public.preview_schedule_deletion(");
    expect(seed).toContain("public.delete_schedule_subtree(");
    expect(seed).toContain("has_table_privilege(current_user, 'public.schedule_deletion_events', 'SELECT')");
    expect(seed).toContain("v_result->>'operationId' IS DISTINCT FROM v_operation::text");
    expect(seed).toContain("version = (v_scope->>'versionBefore')::bigint + 1");
    expect(seed).toContain("v_after IS DISTINCT FROM v_before + 1");
    expect(seed).toMatch(/COMMIT;\s*$/);
    expect(seed).not.toContain("SET ROLE");
  });

  it("keeps 0043 Worker reads on the public authorization path and compares the committed owner snapshot", () => {
    const base = verificationDir + "phase4b3c3-schedule-deletion";
    for (const source of [
      read(base + "-seed-worker-stage-dates.sql"), read(base + "-seed-worker.sql"), read(base + ".sql"),
      read(verificationDir + "phase4b5-seed-one-stage-date.sql"),
    ]) {
      expect(source).not.toMatch(/\b(?:FROM|JOIN)\s+public\.(?:schedule_deletion_events|product_schedule_(?:dependencies|state|operations|operation_events|operation_links|operation_source_events)|(?:activity|stage)_date_changes)\b/i);
      expect(source).not.toMatch(/\b(?:SET\s+(?:LOCAL\s+)?ROLE|GRANT)\b/i);
    }
    const preflight = read(base + "-collision-preflight-owner.sql");
    const postflight = read(base + "-collision-postflight-owner.sql");
    const snapshot = read(base + "-collision-state-owner.sql");
    for (const file of [preflight, postflight]) {
      expect(file).toContain("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;");
      expect(file).toContain("-collision-state-owner.sql");
      expect(file).toContain("ROLLBACK;");
      expect(file).not.toMatch(/^\s*(?:grant|revoke|insert|update|delete|alter)\b/im);
    }
    expect(preflight).toContain("FROM public.schedule_deletion_events WHERE operation_id = v_operation");
    expect(snapshot).toContain("FROM public.product_schedule_dependencies");
    expect(postflight).toContain("(v_baseline->>'current') IS DISTINCT FROM (v_baseline->>'before')");
    expect(postflight).toContain("source_event_id = v_operation AND link_kind = 'audit_detail'");
    expect(postflight).toContain("affected_items = v_items");
    expect(postflight).toContain("schedule_version = v_cursor AND history_watermark");
    const runtime = read(base + ".sql");
    expect(runtime).toContain("v_collision_constraint IS DISTINCT FROM 'schedule_deletion_events_pkey'");
    expect(runtime).toContain("v_audit_after IS DISTINCT FROM v_audit_before");
  });

  it("uses committed calendar reversal history before adding its graph edges", () => {
    const owner = read(verificationDir + "phase4b3b2-calendar-reversal-seed-owner.sql");
    const worker = read(verificationDir + "phase4b3b2-calendar-reversal-seed-worker.sql");
    const edgeOwner = read(verificationDir + "phase4b3b2-calendar-reversal-dependencies-owner.sql");
    expect(worker).toContain("public.change_workspace_calendar(");
    expect(worker).toContain("public.apply_calendar_reschedule(");
    expect(worker).toContain("public.reverse_calendar_reschedule(");
    expect(worker.match(/\bCOMMIT;/g)?.length).toBeGreaterThan(4);
    expect(owner).toContain("After Worker history setup, run phase4b3b2-calendar-reversal-dependencies-owner.sql");
    expect(edgeOwner).toContain("phase4b5-seed-one-dependency.sql");
    expect(runbook.indexOf("phase4b3b2-calendar-reversal-seed-worker.sql")).toBeLessThan(
      runbook.indexOf("phase4b3b2-calendar-reversal-dependencies-owner.sql"),
    );
  });

  it("seeds a real derived-stage reversal conflict and asserts its payload and rollback state", () => {
    const owner = read(verificationDir + "phase4b3b2-calendar-reversal-seed-owner.sql");
    const worker = read(verificationDir + "phase4b3b2-calendar-reversal-seed-worker.sql");
    const runtime = read(verificationDir + "phase4b3b2-calendar-reversal.sql");
    expect(owner).toContain("'Synthetic blocked activity', DATE '2026-11-09', DATE '2026-11-13', 'working_days', 3");
    expect(owner).toContain("'Synthetic blocked successor activity', DATE '2026-11-12', DATE '2026-11-12', 'manual'");
    expect(worker).toContain("'Synthetic reversal calendar closure', DATE '2026-11-13', DATE '2026-11-13'");
    expect(worker).toContain("'proposedEndDate', DATE '2026-11-11'");
    expect(runtime).toContain("'blockedDependency', '4b400000-0000-4000-8000-000000000201'");
    expect(runtime).toContain("'2026-11-11'");
    expect(runtime).toContain("'2026-11-12'");
    expect(runtime).toContain("'2026-11-13'");
    expect(runtime).toContain("'2026-11-16'");
    expect(runtime).toContain("v_result#>>'{conflict,dependencyId}'");
    expect(runtime).toContain("v_result#>>'{conflict,reason}' IS DISTINCT FROM 'finish_to_start'");
    expect(runtime).toContain("v_result#>>'{conflict,predecessor,id}' IS DISTINCT FROM v_blocked_predecessor_stage::text");
    expect(runtime).toContain("v_result#>>'{conflict,successor,id}' IS DISTINCT FROM v_blocked_successor_stage::text");
    for (const payloadPath of [
      "{conflict,before,predecessorFinish}",
      "{conflict,before,successorStart}",
      "{conflict,before,earliestStart}",
      "{conflict,after,predecessorFinish}",
      "{conflict,after,successorStart}",
      "{conflict,after,earliestStart}",
    ]) {
      expect(runtime).toContain(`v_result#>>'${payloadPath}'`);
    }
    expect(runtime).toContain("Expected derived-stage reversal conflict payload: %");
    expect(runtime).toContain("v_rows_after IS DISTINCT FROM v_rows_before");
    expect(runtime).toContain("v_operations_after IS DISTINCT FROM v_operations_before");
    expect(runtime).toContain("v_cursor_after IS DISTINCT FROM v_cursor_before");
  });

  it("calculates the before and after FS bounds across the configured shutdown", () => {
    const shutdown = [{
      kind: "company_shutdown" as const,
      startDate: "2026-11-13",
      endDate: "2026-11-13",
    }];
    const recalculatedFinish = calculateWorkingDayEndDate("2026-11-09", 3, shutdown).endDate;
    const beforeBound = calculateWorkingDayEndDate("2026-11-12", 1, shutdown).endDate;
    const afterBound = calculateWorkingDayEndDate("2026-11-14", 1, shutdown).endDate;
    expect(recalculatedFinish).toBe("2026-11-11");
    expect(beforeBound).toBe("2026-11-12");
    expect(afterBound).toBe("2026-11-16");

    const dayNumber = (value: string) => Date.parse(`${value}T00:00:00Z`) / 86_400_000;
    expect(dayNumber("2026-11-12") - dayNumber(beforeBound)).toBe(0);
    expect(dayNumber("2026-11-12") - dayNumber(afterBound)).toBe(-4);
  });

  it("orders the 0044 clone source seeds across owner and direct Worker sessions", () => {
    const cloneOrder = [
      "phase4b3c4-clone-seed-owner.sql",
      "phase4b3c4-clone-seed-worker-import.sql",
      "phase4b3c4-clone-seed-worker-schedule.sql",
      "phase4b3c4-clone-seed-owner-dependencies.sql",
      "phase4b3c4-clone-seed-worker-status.sql",
      "phase4b3c4-clone-preflight-owner.sql",
      "phase4b3c4-clone-dependencies.sql",
      "phase4b3c4-clone-postflight-owner.sql",
    ].map((name) => runbook.indexOf(name));
    expect(cloneOrder.every((position) => position >= 0)).toBe(true);
    expect(cloneOrder).toEqual([...cloneOrder].sort((left, right) => left - right));
    expect(runbook).toContain("test_workspace");
    expect(runbook).toContain("historical_r00_fingerprint");
  });

  it("uses the supported import routine to create source R00 snapshots with empty graphs", () => {
    const owner = read(verificationDir + "phase4b3c4-clone-seed-owner.sql");
    const imports = read(verificationDir + "phase4b3c4-clone-seed-worker-import.sql");
    const schedule = read(verificationDir + "phase4b3c4-clone-seed-worker-schedule.sql");
    const stageDate = read(verificationDir + "phase4b3c4-clone-seed-worker-stage-date.sql");
    const status = read(verificationDir + "phase4b3c4-clone-seed-worker-status.sql");
    expect(owner).toContain("phase4b5-seed-safety-owner.sql");
    expect(owner).toContain("phase4b5-seed-r00-postflight-owner.sql");
    expect(owner).toContain("historical_r00_fingerprint");
    expect(imports).toContain("current_user <> 'jlproject_worker'");
    expect(imports).toContain("public.import_initial_schedule(");
    expect(imports).toContain("snapshot->'dependencies' = '[]'::jsonb");
    expect(imports).toContain("'sourceId'");
    expect(imports).toContain("generate_series(1, 7)");
    expect(imports).toContain("generate_series(1, 3)");
    expect(imports).toContain("generate_series(1, 41)");
    expect(imports).toContain("generate_series(42, 46)");
    expect(imports).not.toMatch(/INSERT\s+INTO\s+public\.initial_schedule_revisions/i);
    expect(imports).not.toContain("product_schedule_dependencies");
    expect(imports).not.toMatch(/predecessor|predecessora/i);
    expect(imports).toContain("ON_ERROR_STOP on");
    expect(imports).toMatch(/COMMIT;\s*$/);
    for (const workerSeed of [imports, schedule, stageDate, status]) {
      expect(workerSeed).not.toContain("product_schedule_dependencies");
    }
  });

  it("keeps D065 edits individually audited and root activity pairs in one Worker operation", () => {
    const schedule = read(verificationDir + "phase4b3c4-clone-seed-worker-schedule.sql");
    const stageHelper = read(verificationDir + "phase4b3c4-clone-seed-worker-stage-date.sql");
    expect(schedule.match(/phase4b3c4-clone-seed-worker-stage-date\.sql/g)?.length).toBe(8);
    expect(stageHelper).toContain("public.change_discipline_stage_dates(");
    expect(stageHelper).toContain("jlproject.schedule_operation_id");
    expect(stageHelper).toContain("jlproject.schedule_justification");
    expect(stageHelper).toContain("COMMIT;");
    expect(schedule).toContain("public.create_activity_with_working_plan(");
    expect(schedule).toContain("DATE '2026-11-12'");
    expect(schedule).toContain("DATE '2026-11-13'");
    expect(schedule).toContain("'activity_created_with_dates'");
    expect(schedule).toContain("900000");
    expect(schedule).toContain("900001");
    expect(schedule).toMatch(/COMMIT;[\s\S]*?\$root_pair\$;\s*COMMIT;/);
    expect(schedule).not.toMatch(/INSERT\s+INTO\s+public\.initial_schedule_revisions/i);
  });

  it("seeds 0041 stage dates through four independently committed audited Worker operations", () => {
    const owner = read(verificationDir + "phase4b3c1-activity-creation-seed-owner.sql");
    const worker = read(verificationDir + "phase4b3c1-activity-creation-seed-worker-stage-dates.sql");
    const helper = read(verificationDir + "phase4b5-seed-one-stage-date.sql");
    const dependencyOwner = read(verificationDir + "phase4b3c1-activity-creation-seed-owner-dependencies.sql");

    expect(owner).toMatch(/INSERT INTO public\.discipline_stages[\s\S]*?VALUES[\s\S]*?;[\s\S]*?INSERT INTO public\.stage_activities/i);
    const stageInsert = owner.match(/INSERT INTO public\.discipline_stages[\s\S]*?;\s*INSERT INTO public\.stage_activities/i)?.[0];
    expect(stageInsert).toBeDefined();
    expect(stageInsert).not.toMatch(/DATE\s*'/i);
    expect(owner).not.toContain("phase4b5-seed-one-dependency.sql");
    expect(owner).toContain("pg_temp.phase4b5_seed_r00_baseline");
    expect(owner).toContain("test_r00_fingerprint");

    expect(worker.match(/\\i db\/verification\/phase4b5-seed-one-stage-date\.sql/g)?.length).toBe(4);
    expect(worker).toContain("current_user <> 'jlproject_worker'");
    expect(worker).toContain("session_user <> 'jlproject_worker'");
    expect(worker).toContain("'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)'");
    expect(worker).toContain("'test_explicit_stage'");
    expect(worker).toContain("'test_partial_stage'");
    expect(worker).toContain("'fixed_successor_stage'");
    expect(worker).toContain("'violation_successor_stage'");
    expect(worker).toContain("test_linked_schedule_version_before");
    expect(worker).toContain("test_violation_schedule_version_before");
    expect(worker).toContain("test_linked_schedule_version=:test_linked_schedule_version");
    expect(worker).toContain("test_violation_schedule_version=:test_violation_schedule_version");
    expect(worker).not.toMatch(/BEGIN\s*;/i);
    expect(helper.match(/\bBEGIN;/g)?.length).toBe(1);
    expect(helper.match(/\bCOMMIT;/g)?.length).toBe(1);
    expect(helper).toContain("public.change_discipline_stage_dates(");
    expect(helper).toContain("v_stage_version <> v_expected_version");
    expect(helper).toContain("v_version_after <> v_version_before + 1");
    expect(helper).not.toContain("product_schedule_dependencies");
    expect(helper).not.toMatch(/INSERT\s+INTO\s+public\.stage_date_changes/i);

    expect(dependencyOwner).toContain("test_r00_fingerprint");
    expect(dependencyOwner).toContain("'Synthetic activity creation D065 date setup'");
    expect(dependencyOwner).toContain("public.stage_date_changes");
    expect(dependencyOwner).toContain("public.product_schedule_operations");
    expect(dependencyOwner).toContain("public.product_schedule_operation_events");
    expect(dependencyOwner).toContain("public.product_schedule_operation_source_events");
    expect(dependencyOwner).not.toContain("public.product_schedule_operation_links");
    expect(dependencyOwner).toContain("v_linked_after <> v_linked_before + 3");
    expect(dependencyOwner).toContain("v_violation_after <> v_violation_before + 1");
    expect(dependencyOwner).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
    expect(dependencyOwner.match(/phase4b5-seed-one-dependency\.sql/g)?.length).toBe(4);
  });

  it("keeps 0042–0044 stage date setup on allowed D065 paths", () => {
    const hierarchy = read(verificationDir + "phase4b3c2-hierarchy-move-seed-owner.sql");
    const hierarchyWorker = read(verificationDir + "phase4b3c2-hierarchy-move-seed-worker-stage-dates.sql");
    const hierarchyDependencies = read(verificationDir + "phase4b3c2-hierarchy-move-seed-owner-dependencies.sql");
    const deletion = read(verificationDir + "phase4b3c3-schedule-deletion-seed-owner.sql");
    const deletionWorker = read(verificationDir + "phase4b3c3-schedule-deletion-seed-worker-stage-dates.sql");
    const deletionDependencies = read(verificationDir + "phase4b3c3-schedule-deletion-seed-owner-dependencies.sql");
    const cloneImport = read(verificationDir + "phase4b3c4-clone-seed-worker-import.sql");
    const cloneSchedule = read(verificationDir + "phase4b3c4-clone-seed-worker-schedule.sql");
    const cloneStageDates = read(verificationDir + "phase4b3c4-clone-seed-worker-stage-date.sql");

    for (const source of [hierarchy, deletion]) {
      const stageInsert = source.match(/INSERT INTO public\.discipline_stages[\s\S]*?;\s*INSERT INTO public\.stage_activities/i)?.[0];
      expect(stageInsert).toBeDefined();
      expect(stageInsert).not.toMatch(/DATE\s*'/i);
      expect(source).toContain("set_config('jlproject.schedule_operation_type', 'product_created'");
    }
    expect(hierarchy).not.toMatch(/UPDATE\s+public\.discipline_stages/i);
    expect(deletion).not.toMatch(/UPDATE\s+public\.discipline_stages/i);
    expect(hierarchy).not.toContain("phase4b5-seed-one-dependency.sql");
    expect(deletion).not.toContain("phase4b5-seed-one-dependency.sql");
    expect(hierarchyWorker.match(/\\i db\/verification\/phase4b5-seed-one-stage-date\.sql/g)?.length).toBe(3);
    expect(hierarchyWorker).toContain("current_user <> 'jlproject_worker'");
    expect(hierarchyWorker).not.toMatch(/BEGIN\s*;/i);
    expect(hierarchyWorker).not.toContain("SET ROLE");
    expect(hierarchyDependencies).toContain("'Synthetic hierarchy movement D065 date setup'");
    expect(hierarchyDependencies).toContain("public.stage_date_changes");
    expect(hierarchyDependencies).toContain("public.product_schedule_operation_events");
    expect(hierarchyDependencies).toContain("public.product_schedule_operation_source_events");
    expect(hierarchyDependencies).not.toContain("public.product_schedule_operation_links");
    expect(hierarchyDependencies.match(/phase4b5-seed-one-dependency\.sql/g)?.length).toBe(6);
    expect(hierarchyDependencies).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
    expect(deletionWorker.match(/\\i db\/verification\/phase4b5-seed-one-stage-date\.sql/g)?.length).toBe(2);
    expect(deletionWorker).not.toMatch(/BEGIN\s*;/i);
    expect(deletionWorker).not.toContain("SET ROLE");
    expect(deletionDependencies).toContain("'Synthetic schedule deletion D065 date setup'");
    expect(deletionDependencies).toContain("public.stage_date_changes");
    expect(deletionDependencies).toContain("public.product_schedule_operation_events");
    expect(deletionDependencies).toContain("public.product_schedule_operation_source_events");
    expect(deletionDependencies).not.toContain("public.product_schedule_operation_links");
    expect(deletionDependencies.match(/phase4b5-seed-one-dependency\.sql/g)?.length).toBe(5);
    expect(deletionDependencies).toContain("REVOKE jlproject_date_executor FROM neondb_owner");
    expect(deletion).not.toContain("phase4b5-seed-one-dependency.sql");
    expect(cloneImport).toContain("public.import_initial_schedule(");
    expect(cloneImport).toContain("'schedule_imported'");
    expect(cloneSchedule).toContain("phase4b3c4-clone-seed-worker-stage-date.sql");
    expect(cloneStageDates).toContain("public.change_discipline_stage_dates(");
    expect(cloneStageDates).not.toMatch(/INSERT\s+INTO\s+public\.discipline_stages|UPDATE\s+public\.discipline_stages/i);
  });

  it("verifies D065 stage-date audit associations through exact source events", () => {
    const stageDateVerifiers = [
      {
        source: read(verificationDir + "phase4b3c1-activity-creation-seed-owner-dependencies.sql"),
        expectedCount: 4,
      },
      {
        source: read(verificationDir + "phase4b3c2-hierarchy-move-seed-owner-dependencies.sql"),
        expectedCount: 3,
      },
      {
        source: read(verificationDir + "phase4b3c3-schedule-deletion-seed-owner-dependencies.sql"),
        expectedCount: 2,
      },
    ];

    for (const { source, expectedCount } of stageDateVerifiers) {
      expect(source).toContain("public.product_schedule_operation_source_events");
      expect(source).toContain("source.source_ledger = 'stage_date_changes'");
      expect(source).toContain("source.source_operation_id = change.operation_id");
      expect(source).toContain("source.source_event_id = change.event_id");
      expect(source).toContain("source.link_kind = 'audit_detail'");
      expect(source).toContain("source.workspace_id = change.workspace_id");
      expect(source).toContain("source.product_id = change.product_id");
      expect(source).toContain("source.operation_id = operation.operation_id");
      expect(source).toContain("source.schedule_version = operation.schedule_version");
      expect(source).toContain("operation.actor_id = v_actor");
      expect(source).toContain("operation.operation_type = 'stage_dates_changed'");
      expect(source).toContain("event.entity_type = 'discipline_stages'");
      expect(source).toContain("event.change_type = 'discipline_stages_dates_changed'");
      expect(source).toContain(`) <> ${expectedCount} OR`);
      expect(source).not.toContain("public.product_schedule_operation_links");
    }
  });

  it("adds source edges only through audited confirmation and archives through the status API", () => {
    const dependencies = read(verificationDir + "phase4b3c4-clone-seed-owner-dependencies.sql");
    const status = read(verificationDir + "phase4b3c4-clone-seed-worker-status.sql");
    expect(dependencies.match(/phase4b5-seed-one-dependency\.sql/g)?.length).toBe(9);
    expect(dependencies).toContain("'historicalFingerprint'");
    expect(dependencies.toLowerCase()).toContain("root-to-root activity");
    expect(dependencies).toContain("test_endpoint_kind stage");
    expect(dependencies).not.toMatch(/INSERT\s+INTO\s+public\.product_schedule_dependencies/i);
    expect(status).toContain("current_user <> 'jlproject_worker'");
    expect(status).toContain("public.change_product_status(");
    expect(status).toContain("'em_estudo'");
    expect(status).toContain("'arquivado'");
    expect(status).toContain("COMMIT;");
    expect(status).not.toContain("product_schedule_dependencies");
  });

  it("carries the six historical R00 rows through clone preflight and postflight", () => {
    const preflight = read(verificationDir + "phase4b3c4-clone-preflight-owner.sql");
    const postflight = read(verificationDir + "phase4b3c4-clone-postflight-owner.sql");
    expect(preflight).toContain("HISTORICAL_R00_BASELINE");
    expect(preflight).toContain("revision.workspace_id <> :'workspace'::uuid");
    expect(postflight).toContain("historical_r00_count");
    expect(postflight).toContain("historicalR00Fingerprint");
    expect(postflight).toContain("v_historical_count + 8");
    expect(postflight).toContain("Historical R00 rows changed");
    expect(preflight).toMatch(/ROLLBACK;\s*$/);
    expect(postflight).toMatch(/ROLLBACK;\s*$/);
  });
});
