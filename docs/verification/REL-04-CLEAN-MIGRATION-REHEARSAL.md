# REL-04 — clean 0010-to-0027 migration rehearsal

This procedure now prepares the second clean rehearsal, `rel04-clean-0010-0027-r02`, with evidence in `%LOCALAPPDATA%\JLProject\rel04-evidence-r02`. The operator reports that the original child `br-tiny-moon-b6b1k5gm` reached a committed migration 0014 and the REL-04 Run then failed. Preserve that child and everything in `rel04-evidence`; never resume Run on it. Repository inspection has not independently verified that environment state. The second rehearsal requires separate approval for Create, Preflight, Run, Verify, Restore, and Cleanup. Never use the Production branch as a SQL target. Never attach an application or Worker to a disposable child during the migration chain.

## Inputs and reviewed files

- Project: `crimson-glade-72578238`; database: `neondb`.
- Production ID (comparison only, never a SQL target): `br-orange-shadow-b6yu9uxu`.
- Completed REL-03 reference: `br-snowy-wave-b6vn905p` (read-only final comparison).
- Verified 0010 checkpoint: `br-dark-tree-b67h0344`, expected name `rel03-baseline-0010`, expected parent `br-snowy-wave-b6vn905p`. The operator reports that it currently has no automatic expiration. The runner retains its historical `2026-11-19T03:03:30Z` conservative deadline; if that gate blocks Create, stop for a separate reviewed change rather than bypassing it.
- Operator: [rel04-operator.ps1](../../db/verification/rel04-operator.ps1); reviewed [17-file SHA-256 manifest](../../db/verification/rel04-migration-manifest.csv).
- Read-only [snapshot](../../db/verification/rel04-readonly-snapshot.sql), [committed-stage gate](../../db/verification/rel04-stage-gate.sql), and [final integrity gate](../../db/verification/rel04-final-gate.sql).

The manifest is calculated from repository files. The operator and release owner must compare it with approved REL-03 checksum evidence before authorizing Run; no repository ledger proves live migration history. All 17 files have one top-level `BEGIN` and terminal `COMMIT` in the reviewed source. This static check is repeated before execution; an independent connection checks each committed result.

Migration 0014 was corrected after the failed rehearsal: its `neondb_owner` grant now covers only `public.workspaces`. The calendar tables belong to `jlproject_calendar_executor`, so the former grant on `workspace_calendar_versions` and `workspace_calendar_exceptions` emitted warnings and did not give `jlproject_date_executor` SELECT. Migration 0015 grants the required version-table SELECT through temporary calendar-owner membership; reviewed date-executor functions do not require direct exception-table SELECT. The revised 0014 SHA-256 is `53189BF65F01BEC0B79773DDE4B5C2EF27720B5B23E1B5180B0A4BF84AA19385` (previously `41D350A09EB5582F923F33BF3ECEB37C3A557CBDA2A355A175840E3DABD0ED8D`). The revised manifest SHA-256 is `572DBEA243924CBE0DF52FA9677AC0703C24BF2F47190E9619F7D471C2F07153`. Preserve the original checksum and logs with the failed child; do not describe its committed 0014 as the revised file.

The stage gate requires the planning constraint at 0014 and calendar-version SELECT from 0015 onward. It requires no calendar-table SELECT at 0014, so its SQL and pinned checksum remain unchanged.

The second rehearsal pins the distinct child name `rel04-clean-0010-0027-r02` and uses the separate external evidence directory below. Verify the 0010 checkpoint's identity, readiness and current expiration metadata before separately approving Create, Preflight and Run. Never use the failed child, Production or the completed REL-03 branch as the new source.

## Execution policy

Use PowerShell from the repository root. Set an evidence directory **outside** the repository with restricted access. Preserve every report, branch ID, timestamped migration log, and sanitized snapshot. The operator script uses explicit branch IDs, `--project-id`, `--role-name neondb_owner`, `--database-name neondb`, `--ssl verify-full`, `psql -X`, and `ON_ERROR_STOP=1`. It never uses an implicit default branch. [Neon branch CLI](https://neon.com/docs/cli/branches) documents explicit `--parent` and `--no-secrets`; [Neon psql CLI](https://neon.com/docs/cli/psql) documents `verify-full`.

Before Create, confirm in the Neon console that the checkpoint has no automatic expiration and retain that observation as operational evidence. The runner still requires at least 24 hours before its historical conservative deadline; do not change or bypass that gate during execution. After each disposable child exists, confirm it is not attached to any application, integration, or scheduled writer. The script checks for Worker sessions and compares all original core-row hashes after every migration; those checks do not prove the absence of every possible privileged external writer.

```powershell
$evidence = Join-Path $env:LOCALAPPDATA 'JLProject\rel04-evidence-r02'
```

### Create — separate approval

```powershell
.\db\verification\rel04-operator.ps1 -Phase Create -EvidenceDir $evidence `
  -OperatorApproved -ExpiryVerifiedInConsole
$child = (Get-Content (Join-Path $evidence 'rel04-report.json') -Raw | ConvertFrom-Json).child
```

Create verifies checkpoint and reference ancestry without connecting to Production. It checks the checkpoint's 0010 objects, exact products (5), disciplines (19), stages (40), activities (73), activity audits (3), R00 (1), and canonical date fingerprint `41276cac3ad96dcf6377af00f5b7e733`. It creates only `rel04-clean-0010-0027-r02` with `--parent br-dark-tree-b67h0344 --no-secrets`, waits for ready, then compares the child with the checkpoint's exact core-row and catalog fingerprints. A failed child is retained. The child ID is saved outside the repository before further checks.

### Preflight — separate approval, read-only

Inspect deployed Worker/application configuration, release routing, background jobs, and scheduled writers. Confirm the disposable child ID is absent from every deployed binding and that a change freeze will keep it isolated throughout Run. Save a sanitized JSON attestation **inside `$evidence`**, with no endpoints, credentials, or personal data:

```json
{
  "project_id": "crimson-glade-72578238",
  "child_branch_id": "<the exact $child branch ID>",
  "deployed_app_bindings": 0,
  "scheduled_writer_bindings": 0,
  "recorded_at_utc": "<inspection time in UTC, ISO 8601>",
  "freeze_until_utc": "<approved change-freeze end in UTC, ISO 8601>",
  "change_reference": "<approved change record ID>"
}
```

The attestation must be no more than two hours old at Preflight and at Run start; its freeze must extend at least two hours beyond Preflight. Run checks its SHA-256 and requires at least 30 minutes of remaining freeze before every migration. This is an operational attestation; the zero-session catalog check is additional evidence.
If the evidence or preflight expires before Run, refresh the attestation and repeat the read-only Preflight. Do not resume a Run that has already started.

```powershell
$isolation = Join-Path $evidence 'rel04-writer-isolation.json'
.\db\verification\rel04-operator.ps1 -Phase Preflight -EvidenceDir $evidence `
  -ChildBranchId $child -WriterIsolationEvidencePath $isolation -OperatorApproved
```

Preflight performs no migration writes. It creates a checksum-verified SQL wrapper in the external evidence directory containing the three session `SET` statements, a settings/identity diagnostic row, a fail-closed settings assertion, and the read-only stage gate. One `-f` invocation must return exactly the diagnostic row, settings assertion `1`, and stage-gate `1` under `-qAt` and `-v stage=0010`. A second invocation of the same wrapper uses Run's nonquiet `-At/-f` command shape and must show both assertion rows and the stage gate's standalone `ROLLBACK` tag. The wrapper SHA-256, SQL output and process exits are logged separately; errors distinguish exit failure, output shape, settings, and stage binding. Preflight also verifies snapshot JSON parsing, then requires a nonzero exit and the expected error text from a read-only `SELECT 1 / 0` negative control passed through the same logging pipeline used by Run. It saves that negative-control log, rechecks the 0010 data and catalog, and stops if any output shape or exit behavior differs.

### Run — separate approval

```powershell
.\db\verification\rel04-operator.ps1 -Phase Run -EvidenceDir $evidence `
  -ChildBranchId $child -WriterIsolationEvidencePath $isolation -OperatorApproved
```

Run requires the saved `preflight_passed` report (no more than two hours old), an unchanged isolation attestation and manifest, and an unchanged 0010 child baseline. It checks every migration checksum and transaction boundary, then applies `0011` through `0027` **individually and in numeric order** as `neondb_owner`. For each migration it generates a separate, checksum-verified SQL wrapper in the external evidence directory with `lock_timeout=15s`, `statement_timeout=10min`, and `idle_in_transaction_session_timeout=12min`, an in-session settings assertion, and the unchanged reviewed migration content. It executes the wrapper through one `-f` invocation. Before each file, it rechecks the writer-isolation attestation and Worker sessions. After each file it requires process exit code zero, the settings diagnostic and assertion, and **exactly one standalone `COMMIT` line in that file's persistent log**, then rechecks the original migration file hash, opens a fresh read-only connection for the stage gate, checks expected objects/privileges, and compares all original core-row counts/hashes, R00, and dates with 0010. It saves the wrapper path and SHA-256 in the report, plus a per-file log and stage snapshot before advancing. A missing `COMMIT`, failed SQL assertion, uncommitted result, catalog mismatch, permission drift, or changed original data stops the chain. The report becomes `failed`; Run refuses to resume it.

Critical transitions: `0011`/`0012` clone replacement; `0014` planning defaults and INSERT restriction; `0015`/`0016` executor grants; `0020`/`0021` deletion guard correction (no application cutover after `0020`); `0023`/`0024` color clone/grant pair; `0025` root constraints and rewritten functions; `0026` deferrable parent FK and protected movement ledger; `0027` history rewrite with expected definition MD5 `e8d5fca15b6f0d855c133bb960047a9c`. The existing migration preconditions remain authoritative; never relax grants or edit SQL to pass a gate.

### Verify — separate approval, read-only

```powershell
.\db\verification\rel04-operator.ps1 -Phase Verify -EvidenceDir $evidence `
  -ChildBranchId $child -OperatorApproved
```

Verify requires all 17 committed stages. It reads only the disposable child and completed REL-03 reference by explicit IDs. It compares a normalized public catalog digest covering columns/defaults, constraints/validation, indexes, triggers/enabled state, function definitions/owners/ACL/search paths, table and column ACLs, default ACLs, row-security flags, and JLProject role attributes/memberships. It compares original core-row counts/hashes, R00 and canonical dates. Final SQL checks activity ancestry, validated constraints, enabled guards, Worker ledger denial, function EXECUTE boundaries, manual planning defaults, exact baseline counts, and new audit/calendar/deletion/movement table counts and ledger fingerprints. Any mismatch is a stop, not an automatic repair. Save both sanitized final snapshots.

Rollback-only Worker integration tests from REL-03O/P/R may be scheduled **after** this migration-only verification on the disposable child, with separate operator approval and fresh checksum review. They are outside this four-phase migration runner; an exit code or matching catalog digest does not replace functional testing.

The SQL snapshot covers public JLProject rows and catalog objects; it does not prove Auth identity counts, deployed Worker revision, or external backup health. Reconcile those from the existing operational evidence before a Production release decision.

### Restore drill — separate approval

```powershell
.\db\verification\rel04-operator.ps1 -Phase Restore -EvidenceDir $evidence `
  -OperatorApproved -RestoreApproved -ExpiryVerifiedInConsole
```

Restore is available after a verified, failed, or interrupted Run. It creates a **second** disposable branch directly from the 0010 checkpoint, verifies its ancestry, readiness, exact core rows, R00, canonical dates and catalog against the saved 0010 evidence, and saves its branch ID. It does not reset the migrated or failed child. This proves branch-based recovery of the 0010 database snapshot while the checkpoint exists. It does not establish Production backup restoration, application routing recovery, or Worker compatibility; those remain separate release gates.

### Cleanup — separate approval for each child

```powershell
$report = Get-Content (Join-Path $evidence 'rel04-report.json') -Raw | ConvertFrom-Json
.\db\verification\rel04-operator.ps1 -Phase Cleanup -EvidenceDir $evidence `
  -CleanupBranchId $report.child -OperatorApproved -CleanupApproved
# After separately approving restore-child cleanup:
.\db\verification\rel04-operator.ps1 -Phase Cleanup -EvidenceDir $evidence `
  -CleanupBranchId $report.restore_branch -OperatorApproved -CleanupApproved
```

Cleanup of the main child requires a verified migration report and saved final evidence. Cleanup of the independent restore child requires saved restore-drill evidence, even if the main Run failed. Each deletion also requires exact disposable child ID/name/parent/non-default checks and a typed confirmation. A failed main migration child is retained for investigation. Cleanup never deletes Production, the completed rehearsal, or the 0010 checkpoint. Preserve logs and reports before approving any deletion. No phase performs automatic cleanup.

## Failure and recovery

Stop on any unexpected branch metadata, expiry, writer-isolation attestation, Worker session, checksum, SQL error, nonzero process exit, missing standalone `COMMIT`, unsuccessful postcheck, count/fingerprint change, structural difference, or reference mismatch. Save the failed file log, completed-stage list and latest read-only snapshot. Do **not** rerun the failed migration or continue from a partially upgraded branch: a file may have committed even if subsequent verification failed, and predecessor files remain committed. Keep the failed child for investigation. After diagnosis and a new approval, create a **new** disposable child from the still-valid 0010 checkpoint and run the reviewed manifest from the start. If the checkpoint has expired, stop and establish a new independently verified 0010 recovery source; never substitute Production or the completed rehearsal branch.

## Operator review gates

1. Approve the 17 hashes against REL-03 evidence and inspect the new SQL/PowerShell files.
2. Verify checkpoint metadata/expiry before Create; inspect deployed bindings and attest writer isolation after the child exists.
3. Approve Run only after read-only Preflight passes and the saved child 0010 baseline matches the checkpoint.
4. Review every per-migration log, the consolidated report, final REL-03 comparison, and later functional regression results before release decisions.
5. Approve the restore drill and each cleanup separately. Production remains untouched throughout REL-04.
