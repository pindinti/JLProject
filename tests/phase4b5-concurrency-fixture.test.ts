import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(path, "utf8");
const seed = read("db/verification/phase4b5-concurrency-seed.sql");
const confirm = read("db/verification/phase4b5-concurrency-confirm.sql");
const state = read("db/verification/phase4b5-concurrency-state.sql");
const procedure = read("docs/verification/PHASE-4B5-POSTGRESQL-CONCURRENCY.md");
const roleCheck = read("db/verification/phase4b5-concurrency-role-check.sql");

describe("Phase 4B.5 two-session fixture contract", () => {
  it("prevents an early successful psql exit anywhere in the Phase 4 verification chain", () => {
    const directory = "db/verification";
    for (const filename of readdirSync(directory).filter((name) => /^phase4.*\.sql$/.test(name))) {
      expect(read(`${directory}/${filename}`), filename).not.toMatch(/^\s*\\q(?:uit)?(?:\s|$)/m);
    }
  });

  it("provisions separate synthetic cases behind a disposable branch gate", () => {
    const insert = seed.indexOf("INSERT INTO public.workspaces");
    expect(seed.indexOf(":'phase4b5_disposable_branch_verified' = 'true'")).toBeGreaterThan(0);
    expect(seed.indexOf(":'phase4b5_disposable_branch_verified' = 'true'")).toBeLessThan(insert);
    expect(seed.indexOf("phase4b5-seed-auth-identities-owner.sql")).toBeLessThan(insert);
    expect(seed).toContain(":'test_actor'::uuid AS actor");
    expect(seed).not.toMatch(/FROM public\.workspace_memberships|^\\quit\b/m);
    expect(seed).toContain("current_user = 'neondb_owner'");
    expect(seed).toContain("VALUES ('cycle'), ('duplicate'), ('date'), ('calendar')");
    expect(seed).toMatch(/COMMIT;\s*$/);
  });

  it("uses real entry points, observes the blocker, and rechecks both snapshot versions", () => {
    expect(procedure).toContain("BEGIN ISOLATION LEVEL READ COMMITTED");
    expect(procedure).toContain("pg_backend_pid() = ANY(pg_blocking_pids(:'b_pid'::int))");
    expect(procedure).not.toContain("pg_sleep");
    expect(procedure).toContain("Late → Early in the cycle case");
    expect(procedure).toContain("distinct edge ID in the duplicate case");
    expect(procedure).toContain("Expect `conflict` for both");
    expect(procedure).toContain("decrement only the captured schedule version");
    expect(procedure).toContain("pass only the old calendar version");
    expect(procedure).toContain("public.change_activity_dates");
    expect(procedure).toContain("dependency_preview_required");
    expect(procedure).toContain("public.change_workspace_calendar");
    expect(confirm).toContain("public.confirm_schedule_dependencies(");
    expect(confirm).toContain(":'schedule_version'::bigint, :'calendar_version'::bigint, :'fingerprint'");
    expect(confirm).toContain(":'confirmation_status' = :'expected_status'");
  });

  it("compares full loser state after commit and removes the temporary owner role access", () => {
    for (const table of ["stage_activities", "product_schedule_dependencies", "product_schedule_state",
      "product_schedule_operations", "product_schedule_operation_events", "product_schedule_operation_links",
      "product_schedule_operation_source_events",
      "activity_date_changes"]) expect(state).toContain(`public.${table}`);
    expect(procedure).toContain(":'winner_state'::jsonb = :'fixture_state'::jsonb");
    expect(procedure).toContain("Commit the rejected call");
    expect(procedure).toContain("WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner");
    expect(procedure).toMatch(/BEGIN;\s+GRANT jlproject_date_executor[\s\S]+?GRANTED BY neondb_owner;\s+COMMIT;/);
    expect(procedure).toMatch(/BEGIN;\s+REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner RESTRICT;\s+COMMIT;/);
    expect(roleCheck).toContain("BEGIN READ ONLY;");
    expect(roleCheck).toContain("grantor = 'cloud_admin' AND admin_option");
    expect(roleCheck).toContain("grantor = 'neondb_owner' AND NOT admin_option");
    expect(roleCheck).toContain("pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') = :'phase4b5_expect_owner_set'::boolean");
    expect(procedure).not.toMatch(/GRANT[^;]*TO jlproject_worker/i);
  });
});
