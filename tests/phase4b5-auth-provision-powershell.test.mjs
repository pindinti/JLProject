import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env, execPath, platform } from "node:process";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const branch = "br-synthetic-child";
const admin = "10000000-0000-4000-8000-000000000001";
const viewer = "10000000-0000-4000-8000-000000000002";
const sensitive = "must-never-appear-in-output";

describe.skipIf(platform !== "win32")("Phase 4B.5 Auth provisioning through Windows PowerShell", () => {
  let directory;

  beforeAll(() => {
    directory = mkdtempSync(join(tmpdir(), "phase4b5-auth-test-"));
    copyFileSync("db/verification/phase4b5-provision-auth.ps1", join(directory, "provision.ps1"));
    writeFileSync(join(directory, "neon.cmd"), `@"${execPath}" "%~dp0fake-neon.cjs" %*\r\n`);
    writeFileSync(join(directory, "fake-neon.cjs"), `
const { appendFileSync } = require("node:fs");
const args = process.argv.slice(2);
const config = JSON.parse(process.env.PHASE4B5_TEST_CASE);
const log = (entry) => appendFileSync(process.env.PHASE4B5_TEST_LOG, entry + "\\n");
if (args.includes("branches") && args.includes("get")) {
  log("metadata");
  console.log(JSON.stringify({
    id: "${branch}", project_id: "rapid-mud-63974868", parent_id: config.parent || "br-delicate-glitter-b6mj0051",
    name: "phase4b5-rehearsal-synthetic", default: false, primary: false, current_state: "ready",
    expires_at: new Date(Date.now() + 600000).toISOString()
  }));
} else if (args.includes("api") && args.includes("-i") && args.includes("POST") &&
  args.includes("/projects/rapid-mud-63974868/branches/${branch}/auth/users")) {
  const email = args.find((arg) => arg.startsWith("email=")).slice(6);
  const role = email.split("-")[2];
  log(role);
  const spec = config[role] || {};
  const status = spec.status === undefined ? "HTTP 201 Created" : spec.status;
  if (status) console.log(status);
  console.log("content-type: application/json");
  console.log("authorization: ${sensitive}");
  console.log("");
  const user = {
    id: spec.id || (role === "admin" ? "${admin}" : "${viewer}"),
    email: spec.email || email,
    private: "${sensitive}"
  };
  if (spec.idOnly) delete user.email;
  console.log(spec.body || JSON.stringify(spec.envelope ? { user } : user, null, 2));
  console.error("${sensitive}");
  process.exitCode = spec.exitCode || 0;
} else {
  throw Error("Unexpected mock CLI arguments");
}
`);
    writeFileSync(join(directory, "phase4b5-run-fixture.ps1"), `
param([string]$Fixture, [string]$BranchId, [string]$NeonCli, [string[]]$Bindings)
Add-Content -LiteralPath $env:PHASE4B5_TEST_LOG -Value 'identity-preflight'
if ($Fixture -cne 'phase4b5-seed-auth-identities-owner.sql' -or $BranchId -cne '${branch}' -or
    $Bindings.Count -ne 3 -or $Bindings[0] -cne 'phase4b5_branch_id=${branch}' -or
    $Bindings[1] -cne 'phase4b5_admin_user_id=${admin}' -or $Bindings[2] -cne 'phase4b5_viewer_user_id=${viewer}') { exit 99 }
Write-Output '${sensitive}'
if ((ConvertFrom-Json $env:PHASE4B5_TEST_CASE).identityMismatch) { exit 3 }
exit 0
`);
  });

  afterAll(() => {
    if (directory) rmSync(directory, { recursive: true, force: true });
  });

  function run(config, branchId = branch) {
    const log = join(directory, "calls.txt");
    writeFileSync(log, "");
    const result = spawnSync("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned",
      "-Command", `$ids = & './provision.ps1' -NeonCli './neon.cmd' -BranchId '${branchId}'; $ids | ConvertTo-Json -Compress`,
    ], {
      cwd: directory,
      env: { ...env, PHASE4B5_TEST_CASE: JSON.stringify(config), PHASE4B5_TEST_LOG: log },
      encoding: "utf8",
      timeout: 10_000,
    });
    expect(result.error).toBeUndefined();
    expect(result.stdout + result.stderr).not.toContain(sensitive);
    const calls = readFileSync(log, "utf8").trim().split(/\r?\n/).filter(Boolean);
    return { ...result, calls };
  }

  it("accepts CLI 9.9.3 and versioned status lines and checks both Auth rows before emitting IDs", () => {
    const result = run({ admin: { status: "HTTP 201" }, viewer: { status: "HTTP/2 201 Created", envelope: true } });
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ AdminUserId: admin, ViewerUserId: viewer });
    expect(result.calls).toEqual(["metadata", "admin", "viewer", "identity-preflight"]);
  });

  it("accepts the documented ID-only response for both roles and still verifies the branch Auth rows", () => {
    const result = run({ admin: { idOnly: true }, viewer: { idOnly: true } });
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ AdminUserId: admin, ViewerUserId: viewer });
    expect(result.calls).toEqual(["metadata", "admin", "viewer", "identity-preflight"]);
  });

  it.each([
    [400, 1], [401, 1], [409, 1], [500, 1], [409, 0], [200, 0],
  ])("rejects HTTP %i with CLI exit %i", (status, exitCode) => {
    const result = run({ admin: { status: `HTTP ${status} Rejected`, exitCode } });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain(`HTTP ${status}, CLI exit ${exitCode}`);
    expect(result.calls).toEqual(["metadata", "admin"]);
  });

  it.each([
    "", "status message contains HTTP 201", "HTTP/ 201", "HTTP 2010 Created",
    "HTTP 201 Created\nHTTP 201 Created", "HTTP 201 Created\nHTTP/1.1 409 Conflict",
    "HTTP 201 Created\nStatus: 409 Conflict",
  ])("rejects missing, malformed or ambiguous status evidence %j", (status) => {
    const result = run({ admin: { status } });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toMatch(/malformed HTTP status|ambiguous HTTP headers/i);
    expect(result.calls).toEqual(["metadata", "admin"]);
  });

  it.each([
    { status: "HTTP/1.1 201 Created", exitCode: 2 },
    { id: "not-a-provider-uuid" },
    { id: "00000000-0000-0000-0000-000000000000" },
    { email: "different@example.invalid" },
    { body: '{"unexpected":' },
    { body: `{"id":"${admin}","email":"admin@example.invalid","user":{"id":"${viewer}"}}` },
  ])("requires a successful process and a valid, unambiguous identity %j", (response) => {
    const result = run({ admin: response });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.calls).toEqual(["metadata", "admin"]);
  });

  it("stops after viewer failure without emitting the admin ID, invoking SQL, or retrying", () => {
    const result = run({ viewer: { status: "HTTP 500 Server Error", exitCode: 1 } });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("viewer creation failed (HTTP 500, CLI exit 1)");
    expect(result.stderr).not.toContain(admin);
    expect(result.calls).toEqual(["metadata", "admin", "viewer"]);
  });

  it("withholds both IDs if the read-only database identity check fails", () => {
    const result = run({ admin: { idOnly: true }, viewer: { idOnly: true }, identityMismatch: true });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("identity preflight failed (exit 3)");
    expect(result.calls).toEqual(["metadata", "admin", "viewer", "identity-preflight"]);
  });

  it("rejects Development and a mismatched parent before sending any create", () => {
    expect(run({}, "br-delicate-glitter-b6mj0051").calls).toEqual([]);
    const result = run({ parent: "br-unrelated" });
    expect(result.status).toBe(1);
    expect(result.calls).toEqual(["metadata"]);
  });
});
