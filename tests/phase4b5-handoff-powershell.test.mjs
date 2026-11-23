import { spawnSync } from "node:child_process";
import { Buffer } from "node:buffer";
import { platform } from "node:process";
import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const { fixtures } = JSON.parse(readFileSync("db/verification/phase4b5-handoff-manifest.json", "utf8"));

function echoTemplates(file) {
  const lines = readFileSync("db/verification/" + file, "utf8").split(/\r?\n/);
  return fixtures[file].exports.map(({ prefix }) => {
    const line = lines.find((entry) => entry.startsWith("\\echo " + prefix));
    if (!line) throw new Error("Missing fixture output for " + prefix);
    return line.slice("\\echo ".length);
  });
}

it.skipIf(platform !== "win32")("parses mixed names and rejects a typo before CLI resolution", () => {
  const seed = "phase4b3c1-activity-creation-seed-owner.sql";
  const output = fixtures[seed].exports?.[0];
  if (!output) throw new Error("Missing seed export contract");
  const id = "10000000-0000-4000-8000-000000000001";
  const assignments = output.names.map((name) => {
    const value = name === "test_r00_count" ? "6" : name === "test_r00_fingerprint" ? "a".repeat(32) : id;
    return name + "=" + value;
  });
  const work = [
    "$ErrorActionPreference = 'Stop'",
    "$runner = './db/verification/phase4b5-run-fixture.ps1'",
    "$values = & $runner -Fixture '" + seed + "' -SeedOutput @('" + output.prefix + assignments.join(" ") + "')",
    "if ($values.fixed_successor_stage -cne '" + id + "' -or $values.violation_successor_stage -cne '" + id + "') { exit 9 }",
    "try { & $runner -Fixture phase4b5-handoff-probe.sql -NeonCli 'missing-neon.cmd' -BranchId br-synthetic -Bindings @('unexpected=" + id + "'); exit 8 }",
    "catch { if ($_.Exception.Message -cne 'Unexpected fixture variable: unexpected') { throw } }",
    "exit 0",
  ].join("\n");
  const encoded = Buffer.from(work, "utf16le").toString("base64");
  const result = spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned", "-EncodedCommand", encoded,
  ], { encoding: "utf8" });
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr).toBe(0);

  const invalid = Buffer.from(
    "& './db/verification/phase4b5-run-fixture.ps1' -Fixture phase4b5-handoff-probe.sql " +
    "-NeonCli 'missing-neon.cmd' -BranchId br-synthetic -Bindings @()",
    "utf16le",
  ).toString("base64");
  const rejected = spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned", "-EncodedCommand", invalid,
  ], { encoding: "utf8" });
  expect(rejected.status).toBe(1);
  expect(rejected.stderr).toContain("Missing fixture variables");
});

it.skipIf(platform !== "win32")("passes both 0044 bootstrap UUIDs into the edge seed and rejects unresolved aliases", () => {
  const base = "phase4b3c4-clone";
  const bootstrap = base + "-seed-owner.sql";
  const edges = base + "-seed-owner-dependencies.sql";
  const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
  const array = (values) => "@(" + values.map(quote).join(", ") + ")";
  const work = String.raw`
$ErrorActionPreference = 'Stop'
$runner = './db/verification/phase4b5-run-fixture.ps1'
$bootstrap = ${quote(bootstrap)}
$edges = ${quote(edges)}
$manifest = Get-Content db/verification/phase4b5-handoff-manifest.json -Raw | ConvertFrom-Json

# Render the actual psql echo templates locally. An undefined variable remains literal, as it did in the failed run.
function Render-Echo([string[]]$Templates, [hashtable]$Variables) {
  foreach ($line in $Templates) {
    [regex]::Replace($line, ':(\w+)', {
      param($match)
      $key = $match.Groups[1].Value
      if ($Variables.ContainsKey($key)) { $Variables[$key] } else { $match.Value }
    })
  }
}
$bootstrapVars = @{
  test_workspace='10000000-0000-4000-8000-000000000001'
  test_actor='10000000-0000-4000-8000-000000000002'
  test_viewer='10000000-0000-4000-8000-000000000003'
  test_other_workspace='10000000-0000-4000-8000-000000000004'
  historical_r00_count='6'
  historical_r00_fingerprint=('a' * 32)
}
$seed = & $runner -Fixture $bootstrap -SeedOutput @(Render-Echo ${array(echoTemplates(bootstrap))} $bootstrapVars)
$seed['phase4b5_disposable_child_verified'] = 'true'
$bound = @{}
foreach ($key in $manifest.fixtures.$edges.inputs) {
  if (!$seed.ContainsKey($key)) { throw "No bootstrap value for $key" }
  $bound[$key] = $seed[$key]
}
$edgeVars = $bound.Clone()
$edgeVars['vigente_source'] = '10000000-0000-4000-8000-000000000005'
$edgeVars['study_source'] = '10000000-0000-4000-8000-000000000006'
$edgeVars['archived_source'] = '10000000-0000-4000-8000-000000000007'
$edgeVars['empty_source'] = '10000000-0000-4000-8000-000000000008'
$templates = ${array(echoTemplates(edges))}
$export = & $runner -Fixture $edges -SeedOutput @(Render-Echo $templates $edgeVars)
if ($export.viewer -cne $bootstrapVars.test_viewer -or $export.other_workspace -cne $bootstrapVars.test_other_workspace) {
  throw 'The aliases did not retain their bootstrap UUIDs.'
}
foreach ($pair in @('test_viewer:viewer', 'test_other_workspace:other_workspace')) {
  $key, $alias = $pair.Split(':')
  $unbound = $edgeVars.Clone()
  $unbound.Remove($key)
  $emitted = @(Render-Echo $templates $unbound)
  if (!($emitted -cmatch [regex]::Escape("$alias=:$key"))) { throw "Original unresolved alias was not reproduced: $alias" }
  try {
    & $runner -Fixture $edges -SeedOutput $emitted
    throw 'Unresolved output was accepted.'
  } catch {
    if ($_.Exception.Message -cne "Malformed fixture value for: $alias") { throw }
  }
  $bindings = @($bound.Keys | Where-Object { $_ -cne $key } | ForEach-Object { "$_=$($bound[$_])" })
  try {
    & $runner -Fixture $edges -BranchId br-synthetic -NeonCli 'missing-neon.cmd' -Bindings $bindings
    throw 'Missing input was accepted.'
  } catch {
    if ($_.Exception.Message -cne "Missing fixture variables: $key") { throw }
  }
  try {
    & $runner -Fixture $edges -BranchId br-synthetic -NeonCli 'missing-neon.cmd' -Bindings ($bindings + @("$key=not-a-uuid"))
    throw 'Malformed input was accepted.'
  } catch {
    if ($_.Exception.Message -cne "Malformed fixture value for: $key") { throw }
  }
}
exit 0
`;
  const result = spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned",
    "-EncodedCommand", Buffer.from(work, "utf16le").toString("base64"),
  ], { encoding: "utf8" });
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr).toBe(0);
});
