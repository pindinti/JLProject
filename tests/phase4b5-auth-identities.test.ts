import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");
const verification = "db/verification/";
const identitySeed = read(verification + "phase4b5-seed-auth-identities-owner.sql");
const safetySeed = read(verification + "phase4b5-seed-safety-owner.sql");
const runbook = read("docs/verification/PHASE-4B5-EXECUTION-ORDER.md");
const manifest = JSON.parse(read(verification + "phase4b5-handoff-manifest.json"));

const ownerSeeds = [
  "phase4b3c1-activity-creation-seed-owner.sql",
  "phase4b3c2-hierarchy-move-seed-owner.sql",
  "phase4b3c3-schedule-deletion-seed-owner.sql",
  "phase4b3c4-clone-seed-owner.sql",
];

describe("Phase 4B.5 branch-scoped actor identities", () => {
  it("uses SQL failures instead of unreliable embedded-psql conditional flow", () => {
    expect(identitySeed).toContain("\\set ON_ERROR_STOP on");
    expect(identitySeed).toContain("BEGIN READ ONLY;");
    expect(identitySeed).toContain("DO $phase4b5_identity_preflight$");
    expect(identitySeed).toContain("RAISE EXCEPTION USING");
    expect(identitySeed).toContain("COMMIT;");
    expect(identitySeed).not.toMatch(/^\\if\b/m);
    expect(identitySeed).not.toMatch(/^\\else\b/m);
    expect(identitySeed).not.toMatch(/^\\quit\b/m);

    for (const variable of ["phase4b5_branch_id", "phase4b5_admin_user_id", "phase4b5_viewer_user_id"]) {
      expect(identitySeed).toContain(`:'${variable}'`);
    }

    expect(identitySeed).toContain("current_user <> 'neondb_owner'");
    expect(identitySeed).toContain("v_branch_id !~ '^br-[a-z0-9-]+$'");
    expect(identitySeed).toContain("v_admin_id = v_viewer_id");
    expect(identitySeed).toContain("Invalid Neon Auth identity input;");
    expect(identitySeed).toContain("Synthetic admin identity is missing or does not match this child branch");
    expect(identitySeed).toContain("Synthetic viewer identity is missing or does not match this child branch");
  });

  it("validates exact branch-scoped Auth rows before exposing actor aliases", () => {
    expect(manifest.fixtures["phase4b5-seed-auth-identities-owner.sql"]).toEqual({
      role: "neondb_owner",
      readOnly: true,
      inputs: ["phase4b5_branch_id", "phase4b5_admin_user_id", "phase4b5_viewer_user_id"],
    });
    expect(identitySeed).toContain("neon_auth.\"user\"");
    expect(identitySeed).toContain("id = v_admin_id");
    expect(identitySeed).toContain("id = v_viewer_id");
    expect(identitySeed).toContain("'jlproject-phase4b5-admin-' || v_branch_id");
    expect(identitySeed).toContain("'jlproject-phase4b5-viewer-' || v_branch_id");
    expect(identitySeed).toContain("current_setting('jlproject.phase4b5.admin_user_id')::uuid::text AS test_actor");
    expect(identitySeed).toContain("current_setting('jlproject.phase4b5.viewer_user_id')::uuid::text AS test_viewer");
    expect(identitySeed).toContain("\\set editor :test_actor");
    expect(identitySeed).toContain("\\set viewer :test_viewer");
    expect(identitySeed).not.toMatch(/(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+neon_auth/i);
    expect(identitySeed).not.toMatch(/\b(?:GRANT|REVOKE|SET\s+ROLE)\b/i);
  });

  it("keeps the shared disposable-child gate fail-closed without psql conditionals", () => {
    expect(safetySeed).toContain("\\set ON_ERROR_STOP on");
    expect(safetySeed).toContain(":'phase4b5_disposable_child_verified'");
    expect(safetySeed).toContain("current_setting('jlproject.phase4b5.disposable_child_verified') <> 'true'");
    expect(safetySeed).toContain("A verified disposable Development child is required");
    expect(safetySeed).toContain("RESET jlproject.phase4b5.disposable_child_verified;");
    expect(safetySeed).not.toMatch(/^\\if\b/m);
    expect(safetySeed).not.toMatch(/^\\else\b/m);
    expect(safetySeed).not.toMatch(/^\\quit\b/m);
    expect(safetySeed).toContain("to_regclass('public.product_schedule_dependencies') IS NULL");
    expect(safetySeed).toContain("count(*) FROM public.initial_schedule_revisions) <> 6");
  });

  it("runs the shared preflight before fixture writes in every owner seed", () => {
    for (const filename of ownerSeeds) {
      const seed = read(verification + filename);
      const preflightIndex = seed.indexOf("phase4b5-seed-auth-identities-owner.sql");
      const firstWriteTransactionIndex = seed.indexOf("BEGIN;");
      const membershipInsertIndex = seed.indexOf("INSERT INTO public.workspace_memberships");

      expect(seed, filename).toContain("\\i db/verification/phase4b5-seed-auth-identities-owner.sql");
      expect(firstWriteTransactionIndex, filename).toBeGreaterThan(preflightIndex);
      expect(membershipInsertIndex, filename).toBeGreaterThan(firstWriteTransactionIndex);
    }
  });

  it("removes incidental membership selectors from every affected owner seed", () => {
    for (const filename of ownerSeeds) {
      const seed = read(verification + filename);
      expect(seed, filename).toContain("phase4b5-seed-auth-identities-owner.sql");
      expect(seed, filename).not.toMatch(/SELECT\s+auth_user_id::text\s+AS\s+(?:test_actor|test_viewer|editor|viewer)[\s\S]{0,180}?FROM\s+public\.workspace_memberships/i);
      expect(seed, filename).toContain("INSERT INTO public.workspace_memberships");
    }
    const cloneSeed = read(verification + "phase4b3c4-clone-seed-owner.sql");
    expect(cloneSeed).toContain(":'test_actor'::text AS editor");
    expect(cloneSeed).toContain(":'test_viewer'::text AS viewer");
    expect(cloneSeed).toContain("(:'workspace', :'editor', 'admin', true)");
    expect(cloneSeed).toContain("(:'workspace', :'viewer', 'viewer', true)");
  });

  it("keeps viewer authorization assertions tied to the seeded viewer", () => {
    const activity = read(verification + "phase4b3c1-activity-creation.sql");
    const hierarchy = read(verification + "phase4b3c2-hierarchy-move.sql");
    const deletion = read(verification + "phase4b3c3-schedule-deletion.sql");
    const cloning = read(verification + "phase4b3c4-clone-dependencies.sql");

    expect(activity).toContain("auth_user_id = v_viewer AND active AND role = 'viewer'");
    expect(activity).toContain("auth_user_id = v_actor AND active AND role = 'admin'");
    expect(activity).toContain("v_viewer, 'Synthetic unauthorized child'");
    expect(activity).toContain("Viewer activity creation was accepted.");
    expect(hierarchy).toContain("auth_user_id = v_viewer AND active AND role = 'viewer'");
    expect(hierarchy).toContain("auth_user_id = v_actor AND active AND role = 'admin'");
    expect(hierarchy).toContain("Viewer move was accepted.");
    expect(deletion).toContain("auth_user_id = v_viewer AND active AND role = 'viewer'");
    expect(deletion).toContain("auth_user_id = v_actor AND active AND role = 'admin'");
    expect(deletion).toContain("Viewer deletion was accepted.");
    expect(cloning).toContain("auth_user_id = (v_scope->>'viewer')::uuid AND active AND role = 'viewer'");
    expect(cloning).toContain("auth_user_id = v_editor AND active AND role = 'admin'");
    expect(cloning).toContain("AND active AND role = 'editor'");
    expect(cloning).toContain("Viewer clone was not denied");
  });

  it("documents supported branch-local Neon Auth provisioning before owner fixture seeds", () => {
    expect(runbook).toContain("embedded TypeScript psql");
    expect(runbook).toContain("-v ON_ERROR_STOP=1");
    expect(runbook).toContain("temporary read-only `-f` probes");
    expect(runbook).toContain("verify `-v` expansion, `\\i`, `\\if`, and `\\gset`");
    expect(runbook).toContain("it executed both sides of a `\\if`/`\\else`");
    expect(runbook).toContain("`\\quit 3` returned process status 0");
    expect(runbook).toContain("A missing psql variable causes SQL parsing to fail with a non-zero process status");
    expect(runbook).toContain("preflight uses a read-only transaction");
    expect(runbook).toContain("The embedded fallback remains incompatible");
    expect(runbook).toContain("Do not start the full rehearsal unless the validated native psql remains discoverable");
    expect(runbook).toContain("/api/v2/projects/{project_id}/branches/{branch_id}/auth/users");
    expect(runbook).toContain("jlproject-phase4b5-admin-<branch-id>@example.invalid");
    expect(runbook).toContain("jlproject-phase4b5-viewer-<branch-id>@example.invalid");
    expect(runbook).toContain("phase4b5_admin_user_id=<Auth-response-UUID>");
    expect(runbook).toContain("phase4b5_viewer_user_id=<Auth-response-UUID>");
    expect(runbook).toContain("Do not insert directly into `neon_auth`");
    expect(runbook).toContain("or fabricate a JWT");
    expect(runbook).toContain("viewer denial");
  });

  it("pins the verified native psql path and delegated argument syntax", () => {
    expect(runbook).toContain("C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe");
    expect(runbook).toContain("PostgreSQL psql 18.7");
    expect(runbook).toContain("$env:NEONCTL_PSQL_FALLBACK = '0'");
    expect(runbook).toContain("where.exe psql");
    expect(runbook).toContain("The validated Neon CLI command then reported `Connecting to the database; launching psql...`");
    expect(runbook).toContain("npx neon@latest --no-analytics psql <verified-child-branch-id>");
    expect(runbook).toContain("-- -X -v ON_ERROR_STOP=1 -f");
  });
});
