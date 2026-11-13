# REL-05G — Production incremental migration execution

The existing backup's read-write compute was replaced with one read-only compute and the branch was revalidated for REL-05I. The preliminary Baseline and REL-05L Preflight have passed; no Run or Verify phase has been executed. The release owner must approve Production migrations separately. Never use the REL-04 runner against Production: it pins an older 5-product/73-activity checkpoint. Keep all evidence outside the repository and do not delete any branch automatically.

## Reviewed target and files

- Release commit: `c7303dd464efde744e6abc3847844c5f0972e9bf`.
- Neon project `crimson-glade-72578238`; Production branch `br-orange-shadow-b6yu9uxu`; endpoint `ep-tiny-union-b6r07ej7`; database `neondb`.
- Existing pre-upgrade checkpoint: `backup-pre-release-20261113`, branch `br-round-band-b6qslh9d`, direct child of Production, ready, non-default, and with no automatic expiration reported. Its sole endpoint is `ep-bold-queen-b6a5ql7l`, type `read_only`.
- Runner: `db/verification/rel05g-production-operator.ps1`; original-data gate: `db/verification/rel05g-production-invariants.sql`; final gate: `db/verification/rel05g-production-final-gate.sql`.
- Reused, hash-pinned REL-04 files: `rel04-migration-manifest.csv`, `rel04-readonly-snapshot.sql`, and `rel04-stage-gate.sql`. The saved REL-04 r02 report records 17/17 migrations verified. Its independent restore snapshot matches its 0010 baseline data, dates and catalog. That older snapshot is not the Production preservation baseline.

The current Production baseline is 1 workspace, 4 active memberships (1 admin, 3 editors), 6 active products, 21 disciplines, 11 stage definitions, 47 stages, 99 dated activities, 19 targets (4 logically deleted), 1 import batch, 51 source rows, and 1 R00. The canonical activity-date fingerprint is `548d37609a8773701c88907741716336`. The R00 fingerprint using the reused snapshot SQL is `1f4e4ebde42f6a10db014f2dda707e6b`. The two protected date-audit counts were unavailable to `jlproject_auditor`; the **existing** migration role can collect count and row hashes with the reused snapshot SQL in a `BEGIN READ ONLY` transaction during the approved window. This adds no grants and returns no individual records. No aggregate-only Neon Auth count mechanism has been identified; no Auth identity change is in the migration plan.

## Stop gates before any Production mutation

1. The release owner reconciles the REL-05F older-copy evidence: rows with later creation timestamps explain the 5/73 versus 6/99 counts, but the earlier 73 activities' date fingerprint differs. Record acceptance of the current Production baseline, not the REL-04 fingerprint, as the preservation target.
2. Independently confirm the current endpoint-to-branch mapping, deployed Worker version, release commit, and absence of an authoritative migration ledger. The runner checks endpoint and branch metadata itself. Its stage-0010 gate checks current schema; catalog compatibility is not historical proof of which SQL files ran.
3. Collect the preliminary Baseline before maintenance. Then establish and document an **actual** freeze of Worker business-data writes, scheduled writers, and known direct database writers. Preflight requires a new post-freeze snapshot matching the preliminary baseline; a zero connected-Worker-session query alone is insufficient. Save the sanitized attestation below only after the controls and writer inventory are verified. Do not put credentials, endpoint URLs, identities, or project contents in it.
4. Confirm the existing owner migration credential is available through the approved credential manager. The runner uses `neondb_owner` only; it never reads a credential value or accepts a connection string. The release owner authorizes its read-only baseline use and later migration use separately.
5. Confirm the adopted backup still reports no automatic expiration during Preflight. Project history retention was six hours when checked; the retained branch, not short time-travel history, is the primary pre-upgrade recovery source. Validate restoration on an isolated branch under a separate recovery approval if that evidence is required for the change window.

The writer-freeze attestation must be an operator-produced JSON file named `rel05g-writer-freeze.json` inside `$evidence`. Its `application_writes_blocked` field means Worker business-data API writes are blocked; it does not claim that Neon Managed Auth's separate endpoint is disabled:

```json
{
  "project_id": "crimson-glade-72578238",
  "production_branch_id": "br-orange-shadow-b6yu9uxu",
  "application_writes_blocked": true,
  "scheduled_writes_blocked": true,
  "isolation_method": "<verified operational control>",
  "recorded_at_utc": "<UTC ISO-8601 timestamp ending Z>",
  "freeze_until_utc": "<UTC ISO-8601 timestamp ending Z>",
  "change_reference": "<approved change record>"
}
```

The runner requires an attestation no more than two hours old at Preflight and Run start, recorded after the preliminary Baseline, unchanged SHA-256 at Run and Verify, and at least 30 minutes of remaining freeze before each file. The preliminary Baseline does not require zero current `jlproject_worker` sessions; the post-freeze Preflight snapshot does. Auth actions can still write to Neon Managed Auth independently of the Worker. The release migrations do not change Auth objects; do not perform account or Auth administration during the window. If the change owner requires a freeze of every schema including Auth, stop until a separate, approved Auth service control is defined and verified.

## Production business-data writer freeze

The production Worker serves the frontend and `/api/*` from the same `jlproject` Worker. Read-only Cloudflare API inventory on 2026-11-13 identified the account's `workers.dev` hostname as `jlproject.pauloelp.workers.dev`. `GET /accounts/{account_id}/workers/scripts/jlproject/subdomain` returned `enabled=true` and `previews_enabled=true`; this means both the canonical `workers.dev` route and Version/Preview URLs were enabled. `GET /accounts/{account_id}/workers/domains?service=jlproject` returned no custom domains; Worker script metadata returned `routes: null`; `GET /accounts/{account_id}/workers/scripts/jlproject/schedules` returned no Cron triggers; and `GET /zones?account.id={account_id}` returned zero zones. These are the observed settings at inspection time, not a guarantee they remain unchanged; repeat the GET inventory at the start of the window and stop on any difference. Cloudflare documents that the subdomain GET returns the two enabled flags and that the corresponding POST updates them ([subdomain API](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/subdomain/), [update operation](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/subdomain/methods/create/)).

The repository has no Worker `scheduled` handler (`worker/index.ts`) and `wrangler.jsonc` declares no routes, custom domains, or Cron triggers. Repository inspection found the Worker as the configured application database writer; the release runner is an operator-controlled migration client, not a background business-data writer. External scheduled jobs, scripts, integrations, and direct SQL clients are not enumerable from this repository or the Cloudflare Worker APIs used above. The release owner must produce the external writer inventory and confirm each business-data writer is paused; unknown or unconfirmed writers block the freeze attestation. Neon Managed Auth is a separate service path: frontend auth calls use build-time `VITE_NEON_AUTH_URL` in `src/auth.ts` and do not pass through this Worker.

Use this freeze sequence after the preliminary Baseline and before Preflight:

1. Repeat and save sanitized read-only API results for the `jlproject` script subdomain, Worker domains, script routes, Worker schedules, and account zones. Verify the expected current state above. Record the exact prior values; do not assume a toggle's current value.
2. Pause every external business-data writer identified by the release owner, including scheduled jobs, integrations, scripts, and manual SQL sessions. The owner must attest to the actual pause and its duration. Verify the Worker's Production database binding without displaying its value. A zero `jlproject_worker` session count is a supplementary observation, not proof of the pause.
3. With release-owner authorization, disable the two observed Worker ingress flags using the Cloudflare API `POST /accounts/{account_id}/workers/scripts/jlproject/subdomain` with `{"enabled":false,"previews_enabled":false}`. This API operation requires a Cloudflare Workers Scripts Write permission; do not use a read-only token or an unapproved permission expansion. There are no observed custom domains, routes, or Cron Triggers to disable. If the new read-only inventory finds any, stop and get an approved, reversible per-path freeze plan before continuing.
4. Repeat the subdomain GET and require `enabled=false` and `previews_enabled=false`; repeat the domains, routes, schedules, and zone checks. From an external client, verify the recorded public and Version URLs no longer serve the Worker. Keep all ingress and external writers paused through migrations and database Verify.
5. Create the attestation only after every check passes. Include the change reference, verification time, and freeze end time; do not include a credential, URL, user identity, or project content.

The reviewed Worker subdomain API operations use this endpoint. The write call is future operator procedure only and must not be run without the release-owner approval and the required scoped token; keep the token in the process environment, never in a command transcript or file:

```powershell
$cfAccountId = '8c4dffce7be1030cad7780c38a1b470f'
$subdomainUri = "https://api.cloudflare.com/client/v4/accounts/$cfAccountId/workers/scripts/jlproject/subdomain"
$cfHeaders = @{ Authorization = "Bearer $env:CLOUDFLARE_API_TOKEN" }
$freezeBody = ConvertTo-Json -InputObject @{ enabled = $false; previews_enabled = $false } -Compress
$freezeResponse = Invoke-RestMethod -Method Post -Uri $subdomainUri `
  -Headers $cfHeaders -ContentType 'application/json' -Body $freezeBody
if ($freezeResponse.success -ne $true -or $freezeResponse.result.enabled -ne $false -or
    $freezeResponse.result.previews_enabled -ne $false) { throw 'Cloudflare ingress freeze was not confirmed.' }
$verifiedIngress = Invoke-RestMethod -Method Get -Uri $subdomainUri -Headers $cfHeaders
if ($verifiedIngress.result.enabled -ne $false -or
    $verifiedIngress.result.previews_enabled -ne $false) { throw 'Cloudflare ingress remains enabled.' }
```

After smoke, and only if that invocation did not already restore public ingress before smoke, restore the exact values saved in `$recordedIngress` (the fresh GET response captured before freeze), then require both the POST response and follow-up GET to match them:

```powershell
$restoreBody = ConvertTo-Json -InputObject @{
  enabled = [bool]$recordedIngress.result.enabled
  previews_enabled = [bool]$recordedIngress.result.previews_enabled
} -Compress
$restoreResponse = Invoke-RestMethod -Method Post -Uri $subdomainUri `
  -Headers $cfHeaders -ContentType 'application/json' -Body $restoreBody
$restoredIngress = Invoke-RestMethod -Method Get -Uri $subdomainUri -Headers $cfHeaders
if ($restoreResponse.success -ne $true -or
    $restoreResponse.result.enabled -ne [bool]$recordedIngress.result.enabled -or
    $restoreResponse.result.previews_enabled -ne [bool]$recordedIngress.result.previews_enabled -or
    $restoredIngress.result.enabled -ne [bool]$recordedIngress.result.enabled -or
    $restoredIngress.result.previews_enabled -ne [bool]$recordedIngress.result.previews_enabled) {
  throw 'Cloudflare ingress restoration differs from its recorded pre-freeze state.'
}
```

The public smoke-test ordering has an unresolved operational constraint. With both `workers.dev` and Preview URLs disabled and no custom domain/route, there is no verified HTTP path to the deployed Worker. Re-enabling the public hostname before smoke tests ends the ingress freeze and may allow business-data writes by users even if the smoke actions themselves are read-only. No operator-only access path is established by the repository or the inspected Worker ingress metadata. Before approving the release window, either verify an already-existing operator-restricted smoke path that keeps general business-data writes blocked, or explicitly approve that restoring the public hostname ends the freeze before read-only smoke testing. If neither is acceptable, stop after deployment metadata verification; do not claim a full HTTP smoke pass. Do not introduce an unreviewed Access policy or maintenance feature as part of this runbook.

Neon Managed Auth remains a separate write path for login sessions, verification, and password flows. The Worker route freeze does not block it. The public-schema migration chain does not alter Auth tables or identities, but this procedure is not a whole-database write freeze. If any Auth writes must be prohibited during the window, that requires a separately approved and verified control before proceeding.

## Continuous release-window order

1. Before the maintenance window, run the read-only Preliminary Baseline and review its saved report.
2. At the window start, repeat the Cloudflare GET inventory; pause and attest external business-data writers; disable and verify the Worker hostname and Version URLs.
3. Run Preflight. It verifies the attestation and captures the new frozen baseline. Stop if it differs from the preliminary snapshot or the adopted backup.
4. Run migrations 0011–0027 sequentially. Keep Worker ingress and identified external writers paused; stop on any failed gate.
5. Run Verify while the freeze is still valid. Do not deploy if the frozen baseline, catalog, privilege, audit, or integrity assertions fail.
6. Deploy with the temporary Wrangler config that keeps both ingress flags disabled; verify deployment metadata and recheck the disabled flags.
7. Smoke through an already verified operator-restricted path while frozen, if one exists. Otherwise obtain explicit approval to restore the public hostname before read-only smoke; recognize that this ends the ingress freeze and may permit user writes.
8. After successful smoke, restore only the original ingress settings that were changed and resume the confirmed external writers. Verify the restored settings and record the end of the change window. If the smoke-path decision is unresolved, stop before step 7 and leave ingress and external writers frozen.

## Phase 1 — Preliminary Baseline (read only, before maintenance)

Use Windows PowerShell from the repository root. Retain the original REL-04 evidence; use a new, access-restricted directory outside Git:

```powershell
$evidence = Join-Path $env:LOCALAPPDATA 'JLProject\rel05g-production-20261113-r01'
.\db\verification\rel05g-production-operator.ps1 -Phase Baseline `
  -EvidenceDir $evidence -OperatorApproved
```

This phase does not create a branch or require maintenance. It checks HEAD, tracked cleanliness, manifest and tool hashes, Production branch and endpoint metadata, stage 0010, and original-data invariants, then saves an owner-role snapshot and report outside Git. The SQL inspection scripts use explicit `BEGIN ... READ ONLY` transactions and `ROLLBACK`; the phase makes no database changes. The snapshot includes exact counts and hashes for protected public audit tables. It fails on a different 6/99 baseline, date/R00 fingerprint, role, schema, or invariant. It records the preliminary baseline only; it is not sufficient authorization to migrate. Do not use REL-04 count/hash values.

## Phase 2 — Adopt the existing checkpoint (read only)

Do not create a branch. Pin the already verified backup ID and confirm its identity in Neon metadata before Preflight:

```powershell
$checkpoint = 'br-round-band-b6qslh9d'
$backup = & npx.cmd neon@latest branches get $checkpoint `
  --project-id crimson-glade-72578238 --output json --no-analytics
if ($LASTEXITCODE -ne 0) { throw 'Existing backup lookup failed.' }
$backup = $backup | Out-String | ConvertFrom-Json
if ($backup.id -cne $checkpoint -or $backup.project_id -cne 'crimson-glade-72578238' -or
    $backup.name -cne 'backup-pre-release-20261113' -or
    $backup.parent_id -cne 'br-orange-shadow-b6yu9uxu' -or
    $backup.default -ne $false -or $backup.current_state -cne 'ready' -or
    $null -ne $backup.expires_at) { throw 'Existing backup identity, state, or retention differs.' }
```

The runner also pins the checkpoint branch ID, name, parent, readiness, non-default state, no-expiration metadata, and sole read-only endpoint ID. Its read-only SQL calls explicitly select `--endpoint-type read_only` for this branch; Production snapshots use the pinned Production `read_write` endpoint inside read-only transactions. Preflight compares the backup with the frozen Production baseline, including public table hashes, protected audit aggregates, dates, R00, catalog digest, invariants, and stage 0010. Stop on any mismatch.

## Phase 3 — Preflight (read only, separately approved)

```powershell
.\db\verification\rel05g-production-operator.ps1 -Phase Preflight `
  -EvidenceDir $evidence -CheckpointBranchId $checkpoint `
  -WriterFreezeEvidencePath $freeze -OperatorApproved
```

This phase requires the writer-freeze attestation, verifies it was recorded after the preliminary Baseline, confirms no Worker session remains, and captures `rel05g-frozen-baseline.json`. This fresh snapshot is compared to the preliminary snapshot and is the preservation baseline for every later stage. It also compares the existing backup against this frozen baseline. All snapshots and gates are read-only transactions. Preflight then tests the same one-file SQL wrapper that Run uses: session `SET`s, exact JSON settings row, `ON_ERROR_STOP=1`, `-qAt` and Run-shaped `-At` output, stage binding, strict process exit, and a negative `SELECT 1 / 0` propagation control. It records both baseline hashes, the checkpoint snapshot, and the freeze-attestation hash. The runner marks Preflight `preflight_running` before checks, so any failed attempt remains ineligible for Run. A successful preflight expires after two hours; repeat Preflight before **any** migration write if stale. Once Run starts, a failure is never resumed automatically.

### REL-05K diagnostic handling and retry

The first Production Preflight reached the SQL wrapper with the expected settings row and assertion rows, but its diagnostic gate rejected Neon CLI `DEBUG:` messages on stderr. Inspection of the cached Neon CLI 9.4.0 source confirmed that its `isDebug()` check is `Boolean(process.env.DEBUG)` and that debug logging writes to stderr only when that variable is set. The runner now removes `DEBUG` only from the native Neon CLI child process and restores the parent PowerShell environment immediately afterward. This changes CLI logging only; it does not alter the SQL, connection settings, or PostgreSQL session. Any remaining or unknown stderr is still rejected.

The runner captures `$LASTEXITCODE` immediately after each native psql process and before teeing output, writes the captured code to a sibling `.exit` file, and rejects an unavailable or nonzero code before considering SQL output. The negative `SELECT 1 / 0` control uses the same process-scoped `DEBUG` suppression and captures its exit code before logging. REL-05L requires PostgreSQL 18.7 at `C:\Program Files\PostgreSQL\18\bin\psql.exe` and the installed Git CA bundle at `C:\Program Files\Git\usr\ssl\cert.pem`; these are explicit Windows operator-host prerequisites, not portable defaults. The runner prepends the native binary directory to PATH, supplies the CA bundle for `verify-full`, and removes the Neon TypeScript fallback flag only for each child process, restoring all parent environment values afterward. Exactly one native startup message is required; embedded fallback, SQL errors, warnings, missing assertions, connection errors, and nonzero exits remain failures. Read-only Production probes confirmed native `-qAt` emits query rows and `-At` emits standalone `SET`, `BEGIN`, `ROLLBACK`, and read-only `COMMIT` tags. Local behavioral tests cover native startup, environment isolation, the exact final COMMIT gate, SQL errors, nonzero exits, and unexpected stderr. They passed with process-scoped `RemoteSigned`; no machine-wide execution policy was changed.

A failed Preflight report remains `preflight_running`; this status is not a pass. The runner permits that state as a retry input and reruns all identity, attestation, stage, preservation, SQL-output, and exit-code gates. Never edit the report to `preflight_passed`. To preserve the failed attempt and its snapshot files, start a new evidence subdirectory and copy only the original report, preliminary baseline, and writer-freeze attestation into it. The retry writes its report and new frozen/checkpoint snapshots there, leaving the first attempt unchanged:

```powershell
$sourceEvidence = Join-Path $env:LOCALAPPDATA 'JLProject\rel05g-production-20261113-r01'
$retryEvidence = Join-Path $sourceEvidence 'preflight-retry-02'
if (Test-Path -LiteralPath $retryEvidence) { throw 'Retry evidence directory already exists.' }
New-Item -ItemType Directory -Path $retryEvidence | Out-Null
$runner = '.\db\verification\rel05g-production-operator.ps1'
if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -cne
  'CF4CB2F5293B154CADCB8BE6C406E7591AD919A7710F2F42ADEB5D06948FD71F') {
  throw 'REL-05L runner checksum mismatch.'
}
$expected = @{
  'rel05g-report.json' = '24B04E6774407C89AAA831E67D71330A7BA0E81C185442D1E99FE094E228EC9E'
  'rel05g-baseline.json' = 'F74ADCE4A225CBF1D8D9DC9889EEF592E774CD88E3C5F51978E1B76E49B229F9'
  'rel05g-writer-freeze.json' = 'AA96BE856826D61FC359F6837D0FECCD5B8D91E866E640A7CD5815A9259AED38'
}
foreach ($name in $expected.Keys) {
  $source = Join-Path $sourceEvidence $name
  if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $expected[$name]) {
    throw "Source evidence checksum mismatch: $name"
  }
  Copy-Item -LiteralPath $source -Destination $retryEvidence
  if ((Get-FileHash -LiteralPath (Join-Path $retryEvidence $name) -Algorithm SHA256).Hash -cne $expected[$name]) {
    throw "Copied evidence checksum mismatch: $name"
  }
}
$freeze = Join-Path $retryEvidence 'rel05g-writer-freeze.json'
& .\db\verification\rel05g-production-operator.ps1 -Phase Preflight `
  -EvidenceDir $retryEvidence -CheckpointBranchId 'br-round-band-b6qslh9d' `
  -WriterFreezeEvidencePath $freeze -OperatorApproved
```

Verify that the copied baseline and attestation SHA-256 values match their originals before running. At the time of REL-05K preparation, the existing attestation was still within the runner's two-hour freshness rule and had more than 30 minutes remaining; its recorded expiry was `2026-11-13T14:38:21.8075868Z`. Recheck freshness immediately before retry. If the attestation is stale or has 30 minutes or less remaining, re-verify the live freeze and create a new truthful attestation; never extend its timestamps artificially. A successful retry must end with a new report status of `preflight_passed`, all identity/preservation/stage gates passing, expected settings and assertion rows, zero exit codes for the quiet and Run-shape probes, and a nonzero exit plus the expected division-by-zero diagnostic for the negative SQL control. Stop before Run until separate migration approval.

The REL-05L runner and test SHA-256 values are recorded below. Recalculate them before the retry command; do not use a different runner revision. Preserve both earlier failed Preflight evidence directories.

REL-05L Preflight retry in `preflight-retry-02` passed at `2026-11-13T13:41:59.9907054Z`. The quiet native probe returned three assertion rows with exit 0; the Run-shaped native probe returned nine rows ending in `ROLLBACK` with exit 0. The negative read-only SQL control exited 1 with the expected division-by-zero error. The frozen Production and checkpoint snapshots matched the approved baseline hash. The report is `preflight_passed` with zero completed migrations. This establishes the client output contract; Run still requires separate authorization and all live freeze, freshness, and per-migration gates.

| File | SHA-256 |
| --- | --- |
| `db/verification/rel05g-production-operator.ps1` | `CF4CB2F5293B154CADCB8BE6C406E7591AD919A7710F2F42ADEB5D06948FD71F` |
| `db/verification/rel05k-runner-diagnostics.tests.ps1` | `DFD2BF332473D0BBF763B113FC996001DA896E93217865CB97FC2F4AEFC5CA8F` |

## Phase 4 — Migrations (separate approval; Production writes)

Before the first irreversible Production mutation, review the saved baseline and checkpoint snapshot, exact branch ID, checkpoint retention, protected audit counts, writer-freeze control, manifest hash, and deployment/rollback identifiers. Then, only after explicit release approval:

```powershell
.\db\verification\rel05g-production-operator.ps1 -Phase Run `
  -EvidenceDir $evidence -CheckpointBranchId $checkpoint `
  -WriterFreezeEvidencePath $freeze -OperatorApproved
```

Run executes only `0011` through `0027`, individually and in order, against the pinned Production branch as `neondb_owner`. Each file is checked against the approved 17-entry manifest, wrapped with session timeouts, executed once with TLS verification and `ON_ERROR_STOP=1`, and logged outside Git. A zero exit, exactly one standalone final `COMMIT`, unchanged source/wrapper checksums, a fresh committed-state gate, and unchanged original row/audit/R00/date fingerprints are required **before the next migration**. It stops on unknown stderr, SQL warning/error output, role/branch mismatch, unexpected schema/grant state, changed data, or lost write-freeze evidence. `0020` and `0021`, and `0023` and `0024`, are not application cutover points. The corrected 0014 is the manifest-pinned file; warnings about calendar-table grants are a stop.

If Run fails or its outcome becomes uncertain, keep the freeze, old Worker, checkpoint, logs, wrapper, and report. Never rerun Run or the failed migration blindly: earlier files may already have committed. Independently reconcile the last committed stage and decide a separately approved forward repair or checkpoint-based recovery. Do not reverse SQL files automatically.

## Phase 5 — Verify, deploy, smoke test, restore access

```powershell
.\db\verification\rel05g-production-operator.ps1 -Phase Verify `
  -EvidenceDir $evidence -CheckpointBranchId $checkpoint `
  -WriterFreezeEvidencePath $freeze -OperatorApproved
```

Verify requires all 17 committed stages, stage 0027, the unchanged freeze attestation, the 99-activity canonical fingerprint, independent R00, original public and protected-audit row hashes, valid constraints/guards, expected least-privilege grants, and zero new calendar/deletion/movement events. It compares against the **post-freeze** snapshot, not the preliminary snapshot. Record the final catalog digest and exact audit counts. Do not deploy if any assertion differs.

Build the approved release with the existing verified Production public Auth URL supplied through the approved build environment; never substitute Development/E2E Auth or print credentials. The Vite gate in `scripts/production-auth-url.ts` rejects a different public Auth URL. Inspect the generated configuration and client assets for `targetEnvironment=production`, Worker `jlproject`, `JLPROJECT_ENV=production`, same-origin `/api/*` routing, and absence of `.dev.vars` or local/E2E configuration. The generated `dist/worker/wrangler.json` points its assets at `../client`.

```powershell
$env:CLOUDFLARE_ENV = 'production'
npm.cmd run build
.\node_modules\.bin\wrangler.cmd deployments status --config wrangler.jsonc `
  --env production --name jlproject --json
$deployConfigPath = (Resolve-Path 'dist/worker/wrangler.json').Path
$freezeConfigPath = Join-Path (Split-Path $deployConfigPath) 'wrangler.rel05g-freeze.json'
$deployConfig = Get-Content -LiteralPath $deployConfigPath -Raw | ConvertFrom-Json
$deployConfig | Add-Member -NotePropertyName workers_dev -NotePropertyValue $false -Force
$deployConfig | Add-Member -NotePropertyName preview_urls -NotePropertyValue $false -Force
[IO.File]::WriteAllText($freezeConfigPath,
  ($deployConfig | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
$checkedConfig = Get-Content -LiteralPath $freezeConfigPath -Raw | ConvertFrom-Json
if ($checkedConfig.workers_dev -ne $false -or $checkedConfig.preview_urls -ne $false) {
  throw 'Temporary release config would reopen public or Version URL ingress.'
}
.\node_modules\.bin\wrangler.cmd deploy --config $freezeConfigPath `
  --name jlproject --strict
.\node_modules\.bin\wrangler.cmd deployments status --config wrangler.jsonc `
  --env production --name jlproject --json
```

The checked-in Production config has `workers_dev: true`, which can reopen public ingress during deploy. To keep the freeze through migration verification and deployment, create a temporary deployment config alongside `dist/worker/wrangler.json` with `workers_dev: false` and `preview_urls: false`; keep the asset paths relative to that same directory. Wrangler documents both fields and their URL effects in its [configuration reference](https://developers.cloudflare.com/workers/wrangler/configuration/). Validate the temporary config, deploy it with `wrangler deploy --config <temporary-config>`, and then use the read-only Cloudflare API to confirm both subdomain flags remain false. Do not deploy with the ordinary config while the freeze is expected to remain active. Save prior and new deployment/version IDs.

The full root and `/api/health` smoke checks at `https://jlproject.pauloelp.workers.dev/`, followed by authorized read-only workspace/product, hierarchy/Gantt, calendar, milestone, synchronized row-highlighting, editor-visibility, CORS, and browser/Worker checks, can run only after an HTTP path is available. Use a previously verified operator-restricted path if one exists. Otherwise the release owner must explicitly approve restoring public ingress before smoke: POST the exact previously observed values (`{"enabled":true,"previews_enabled":true}` only if the fresh inventory still shows both as true), then verify the response and a follow-up GET before making read-only smoke requests. Reopening public ingress ends the ingress freeze, so users could still submit writes; keep identified external direct writers paused until smoke completes and monitor for unexpected business writes. With a verified operator-restricted path, restore the original public flags only after smoke; without one, access is already restored before smoke. Do not create a synthetic Production product or change real schedules. If policy forbids public access before smoke and there is no operator-restricted path, stop and report deployment metadata validation only rather than claiming smoke completion.

## Recovery boundary

- **Application rollback:** if the deployment fails while the database is healthy, use the recorded prior Worker version with `wrangler rollback <prior-version-id> --config wrangler.jsonc --env production --name jlproject`, then verify the root assets, API health, and existing reads. The old Worker may not support writes after migration 0026 revokes direct ordering grants; keep writes blocked until compatibility is reviewed. Do not assume Worker rollback reverses the schema.
- **Database recovery:** retain the pre-upgrade checkpoint and all original Production evidence. A branch restore/reset or routing change is a separate high-impact decision requiring DBA and release-owner approval, confirmation of post-checkpoint writes, and validation on an isolated restore child. Never automatically reset Production or delete the checkpoint. If Production writes resumed after the checkpoint, restoring it would lose those writes; reconcile them first.
- **Checkpoint retention:** retain it until final application smoke tests and an approved recovery window end. No cleanup command is included.

## Remaining execution blockers

The observed Cloudflare ingress inventory is complete for the inspected account and Worker as of 2026-11-13: `workers.dev` and Version URLs were enabled; no custom domains, Worker routes, account zones, or Cron triggers were returned. Repeat it at the release window. The remaining operational gates are the post-freeze snapshot matching the preliminary snapshot, a time-bounded attestation, confirmation and pause of external direct database writers, an approved safe HTTP smoke path or explicit acceptance that public ingress reopens before smoke, release-owner acceptance of the older REL-04 copy/date difference, and separate approval for Production mutations. The adopted backup has passed branch, read-only endpoint, stage-0010, data, audit, fingerprint, and catalog comparisons. No authoritative Production migration ledger is present; the runner records exact per-file logs/checksums but does not fabricate historical ledger rows. Auth aggregate counts remain unavailable to the auditor; the migration plan makes no Auth identity or membership changes. Neon Managed Auth remains independently reachable unless separately controlled.
