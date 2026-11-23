import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const runbook = readFileSync("docs/verification/PHASE-4B5-EXECUTION-ORDER.md", "utf8");
const concurrency = readFileSync("docs/verification/PHASE-4B5-POSTGRESQL-CONCURRENCY.md", "utf8");

describe("Phase 4B.5 stage-aware verification order", () => {
  it("runs the storage-only privilege assertion after 0036 and before 0037", () => {
    const orderedRun = runbook.slice(
      runbook.indexOf("## Ordered migration and fixture run"),
      runbook.indexOf("## Permission checkpoints"),
    );
    const migration36 = orderedRun.indexOf("0036_schedule_dependency_storage.sql");
    const storagePostflight = orderedRun.indexOf("phase4b1-storage-postflight.sql");
    const migration37 = orderedRun.indexOf("0037_controlled_schedule_dependencies.sql");

    expect(migration36).toBeGreaterThanOrEqual(0);
    expect(storagePostflight).toBeGreaterThan(migration36);
    expect(migration37).toBeGreaterThan(storagePostflight);
    expect(orderedRun).toContain("Immediately run");
    expect(orderedRun).toContain("Run it before any 0037 command.");
  });

  it("places each runtime fixture after the migration that installs its guard", () => {
    const orderedRun = runbook.slice(
      runbook.indexOf("## Ordered migration and fixture run"),
      runbook.indexOf("## Permission checkpoints"),
    );
    const expectedOrder = [
      "0037_controlled_schedule_dependencies.sql",
      "phase4b2-confirmation-rollback.sql",
      "0038_guard_individual_schedule_dates.sql",
      "phase4b3a-guard-date-writers.sql",
      "0039_guard_calendar_reschedule_apply.sql",
      "phase4b3b1-calendar-apply.sql",
      "0040_guard_calendar_reschedule_reversal.sql",
      "phase4b3b2-calendar-reversal.sql",
      "0041_guard_activity_creation_dependencies.sql",
      "phase4b3c1-activity-creation.sql",
      "0042_guard_hierarchy_move_dependencies.sql",
      "phase4b3c2-hierarchy-move-seed-owner-dependencies.sql",
      "phase4b3c2-hierarchy-move-postflight-owner.sql",
      "phase4b3c2-hierarchy-move.sql",
      "0043_guard_schedule_deletion_dependencies.sql",
      "phase4b3c3-schedule-deletion-seed-owner-dependencies.sql",
      "phase4b3c3-schedule-deletion-collision-preflight-owner.sql",
      "phase4b3c3-schedule-deletion-seed-worker.sql",
      "phase4b3c3-schedule-deletion-collision-postflight-owner.sql",
      "phase4b3c3-schedule-deletion.sql",
      "0044_clone_schedule_dependencies.sql",
      "phase4b3c4-clone-seed-owner.sql",
      "phase4b3c4-clone-seed-worker-import.sql",
      "phase4b3c4-clone-seed-worker-schedule.sql",
      "phase4b3c4-clone-seed-owner-dependencies.sql",
      "phase4b3c4-clone-seed-worker-status.sql",
      "phase4b3c4-clone-preflight-owner.sql",
      "phase4b3c4-clone-dependencies.sql",
      "phase4b3c4-clone-postflight-owner.sql",
      "phase4b5-concurrency-seed.sql",
    ];
    const positions = expectedOrder.map((item) => orderedRun.indexOf(item));

    expect(positions.every((position) => position >= 0)).toBe(true);
    expect(positions).toEqual([...positions].sort((left, right) => left - right));
  });

  it("reruns the same read-only collision postflight after the Worker rollback", () => {
    const stage = runbook.split(/\r?\n/).find((line) => line.startsWith("| 8 | Apply"));
    const runtime = "phase4b3c3-schedule-deletion.sql";
    const postflight = "phase4b3c3-schedule-deletion-collision-postflight-owner.sql";
    expect(stage?.slice((stage?.indexOf(runtime) ?? -1) + runtime.length)).toContain(postflight);
  });

  it("preserves the intentional 0037 and 0044 privilege expectations", () => {
    expect(runbook).toContain("`SELECT`, `INSERT`, and `DELETE` on the edge table");
    expect(runbook).toContain("The Worker still has no direct table privilege");
    expect(runbook).toContain("grants the Worker `EXECUTE` only on the clone helper");
    expect(runbook).toContain("Do not rerun the 0036 storage-only fixture here");
    expect(runbook).toContain("no Worker membership in `jlproject_date_executor`");
  });

  it("keeps the concurrency seed's product and dated-activity audit grouping intact", () => {
    const seed = readFileSync("db/verification/phase4b5-concurrency-seed.sql", "utf8");
    const productInsert = seed.indexOf("INSERT INTO public.products");
    const activityInsert = seed.indexOf("INSERT INTO public.stage_activities");

    expect(productInsert).toBeGreaterThan(0);
    expect(activityInsert).toBeGreaterThan(productInsert);
    expect(seed).toContain("created_by, updated_by");
    expect(seed).toMatch(/COMMIT;\s*$/);
    expect(runbook).toContain("verify one initial operation per product");
  });

  it("keeps committed setup, direct Worker sessions, and read-only clone observers explicit", () => {
    for (const phrase of [
      "direct `jlproject_worker` connection",
      "In another direct Worker session",
      "separate read-only owner session",
      "Calendar changes commit",
      "Synthetic clone products commit",
      "four source products",
      "six-row historical R00",
      "Each stage-date edit commits in its own Worker transaction",
      "Keep fixture seed writes in committed setup transactions",
    ]) expect(runbook).toContain(phrase);
  });

  it("requires four observed races and bounded, sleep-free synchronization", () => {
    expect(runbook).toContain("cycle-prevention, duplicate-edge, graph-vs-date, and calendar-vs-graph");
    expect(concurrency).toContain("SET LOCAL lock_timeout = '90s'");
    expect(concurrency).toContain("SET LOCAL statement_timeout = '2min'");
    expect(concurrency).toContain("pg_blocking_pids(:'b_pid'::int)");
    expect(concurrency).toContain("Do not use sleeps as synchronization.");
    expect(concurrency).toContain("REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner RESTRICT");
    expect(concurrency).toContain("phase4b5_expect_owner_set=false");
  });
});
