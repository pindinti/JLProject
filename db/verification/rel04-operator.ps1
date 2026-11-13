param(
  [Parameter(Mandatory)][ValidateSet('Create','Preflight','Run','Verify','Restore','Cleanup')][string]$Phase,
  [Parameter(Mandatory)][string]$EvidenceDir,
  [string]$ChildBranchId,
  [string]$CleanupBranchId,
  [switch]$OperatorApproved,
  [string]$WriterIsolationEvidencePath,
  [switch]$ExpiryVerifiedInConsole,
  [switch]$RestoreApproved,
  [switch]$CleanupApproved
)

$ErrorActionPreference = 'Stop'
$project = 'crimson-glade-72578238'
$production = 'br-orange-shadow-b6yu9uxu' # Metadata comparison only; never a SQL target.
$rehearsal = 'br-snowy-wave-b6vn905p'
$checkpoint = 'br-dark-tree-b67h0344'
$checkpointName = 'rel03-baseline-0010'
$childName = 'rel04-clean-0010-0027-r02'
$restoreName = 'rel04-restore-drill-0010'
$expiry = [datetimeoffset]::Parse('2026-11-19T03:03:30Z')
$manifestPath = Join-Path $PSScriptRoot 'rel04-migration-manifest.csv'
$snapshotPath = Join-Path $PSScriptRoot 'rel04-readonly-snapshot.sql'
$gatePath = Join-Path $PSScriptRoot 'rel04-stage-gate.sql'
$finalPath = Join-Path $PSScriptRoot 'rel04-final-gate.sql'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$reportPath = Join-Path $EvidenceDir 'rel04-report.json'
$baselinePath = Join-Path $EvidenceDir 'rel04-baseline-0010.json'

function Assert-FileHash([string]$path, [string]$hash) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
      (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hash) {
    throw "Missing file or SHA-256 mismatch: $path"
  }
}
function Assert-ToolFiles {
  Assert-FileHash $manifestPath '572DBEA243924CBE0DF52FA9677AC0703C24BF2F47190E9619F7D471C2F07153'
  Assert-FileHash $snapshotPath 'CF7EF434DA4698776BDE68C1FB1140D452B3B5F382B6984F3A131FAE892108BD'
  Assert-FileHash $gatePath 'CCFFDED439486F0146E3F5F9554FC6C81A9EE8CA17C1B88ED9E47D7C9D7D6488'
  Assert-FileHash $finalPath 'B9666BFE405719598EF4055970065E671C54CE21622B187A22C7855D96E1A862'
}
function Get-Manifest {
  $items = @(Import-Csv -LiteralPath $manifestPath)
  if ($items.Count -ne 17) { throw 'Migration manifest must contain exactly 17 files.' }
  for ($i=0; $i -lt 17; $i++) {
    $number = '{0:D4}' -f ($i + 11)
    $item = $items[$i]
    if ($item.number -cne $number -or $item.file -cnotmatch "^${number}_.+\.sql$" -or
        $item.sha256 -cnotmatch '^[0-9A-F]{64}$') {
      throw "Migration manifest order or format differs at $number."
    }
    $path = Join-Path $repoRoot (Join-Path 'db/migrations' $item.file)
    Assert-FileHash $path $item.sha256
    $source = [IO.File]::ReadAllText($path)
    if ([regex]::Matches($source,'(?m)^BEGIN;\s*$').Count -ne 1 -or
        [regex]::Matches($source,'(?m)^COMMIT;\s*$').Count -ne 1 -or
        -not $source.TrimEnd().EndsWith('COMMIT;') -or
        $source -match '(?m)^\\') {
      throw "Migration $number lacks the reviewed single transaction or contains psql commands."
    }
  }
  return $items
}
function Get-Branch([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id) -or $id -eq $production) {
    throw 'Missing or forbidden branch ID.'
  }
  $raw = & npx.cmd neon@latest branches get $id --project-id $project --output json --no-analytics
  if ($LASTEXITCODE -ne 0) { throw "Branch lookup failed: $id" }
  $branch = $raw | Out-String | ConvertFrom-Json
  if ($null -ne $branch.branch) { $branch = $branch.branch }
  if ($branch.id -cne $id -or $branch.project_id -cne $project) {
    throw "Branch/project identity differs: $id"
  }
  return $branch
}
function Assert-Checkpoint {
  if ([datetimeoffset]::UtcNow -ge $expiry.AddHours(-24)) {
    throw 'Checkpoint expiration is too close for a controlled rehearsal.'
  }
  $source = Get-Branch $checkpoint
  $parent = Get-Branch $rehearsal
  if ($source.name -cne $checkpointName -or $source.parent_id -cne $rehearsal -or
      $source.default -ne $false -or $source.current_state -cne 'ready' -or
      $parent.name -cne 'release-rehearsal-0010-0027' -or
      $parent.parent_id -cne $production -or $parent.default -ne $false -or
      $parent.current_state -cne 'ready') {
    throw 'Checkpoint or rehearsal ancestry, name, default status, or readiness differs.'
  }
  if ($null -ne $source.expires_at -and
      [datetimeoffset]::Parse($source.expires_at) -ne $expiry) {
    throw 'Checkpoint expiration metadata differs.'
  }
}
function Assert-Child([string]$id, [string]$name) {
  if ([string]::IsNullOrWhiteSpace($id) -or $id -in @($production,$rehearsal,$checkpoint)) {
    throw 'Child ID is missing or names a protected branch.'
  }
  $branch = Get-Branch $id
  if ($branch.name -cne $name -or $branch.parent_id -cne $checkpoint -or
      $branch.default -ne $false -or $branch.current_state -cne 'ready') {
    throw 'Child branch name, ancestry, default status, or readiness differs.'
  }
  return $branch
}
function Invoke-ReadSql([string]$branchId, [string]$path, [string]$stage = '') {
  if ($branchId -eq $production -or [string]::IsNullOrWhiteSpace($branchId)) {
    throw 'Forbidden or missing SQL branch ID.'
  }
  $args = @('neon@latest','psql',$branchId,'--project-id',$project,
    '--role-name','neondb_owner','--database-name','neondb','--ssl','verify-full','--',
    '-X','-qAt','-v','ON_ERROR_STOP=1')
  if ($stage -ne '') { $args += @('-v',"stage=$stage") }
  $args += @('-f',$path)
  $output = & npx.cmd @args
  if ($LASTEXITCODE -ne 0) { throw "Read-only SQL failed: $path on $branchId" }
  return @(($output | Out-String).Trim() -split "`r?`n" | Where-Object { $_ -ne '' })
}
function Get-Snapshot([string]$id) {
  $lines = @(Invoke-ReadSql $id $snapshotPath)
  if ($lines.Count -ne 1) { throw 'Snapshot did not return exactly one JSON row.' }
  $snap = $lines[0] | ConvertFrom-Json
  if ($snap.database -cne 'neondb' -or $snap.role -cne 'neondb_owner' -or
      $snap.worker_sessions -ne 0) {
    throw 'Database, role, or no-Worker-writes gate failed.'
  }
  return $snap
}
function Assert-Stage([string]$id, [int]$stage) {
  $result = @(Invoke-ReadSql $id $gatePath ('{0:D4}' -f $stage))
  if ($result.Count -ne 1 -or $result[0] -cne '1') {
    throw "Committed structural gate failed at $stage."
  }
}
function Assert-Markers($snap, [int]$stage) {
  $thresholds = @{
    clone=11; calendar=13; planning=14; reschedule=17; reversal=18;
    calendar_history=19; deletion=20; product_history=22; color=23;
    root_pair=25; movement=26; movement_history=27
  }
  foreach ($key in $thresholds.Keys) {
    if ($snap.markers.$key -ne ($stage -ge $thresholds[$key])) {
      throw "Unexpected $key catalog marker at stage $stage."
    }
  }
}
function Assert-Baseline($snap) {
  Assert-Markers $snap 10
  if ($snap.data.products.count -ne 5 -or
      $snap.data.product_disciplines.count -ne 19 -or
      $snap.data.discipline_stages.count -ne 40 -or
      $snap.data.stage_activities.count -ne 73 -or
      $snap.data.activity_date_changes.count -ne 3 -or
      $snap.data.initial_schedule_revisions.count -ne 1 -or
      $snap.dates -cne '41276cac3ad96dcf6377af00f5b7e733') {
    throw 'Exact 0010 counts or canonical activity-date fingerprint differ.'
  }
}
function Assert-Preserved($baseline, $current) {
  if (($baseline.data | ConvertTo-Json -Depth 10 -Compress) -cne
      ($current.data | ConvertTo-Json -Depth 10 -Compress) -or
      $baseline.dates -cne $current.dates -or $baseline.r00 -cne $current.r00) {
    throw 'Existing row counts/fingerprints, dates, or R00 changed.'
  }
}
function Save-Json([string]$path, $object) {
  $json = $object | ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}
function Get-Report {
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'REL-04 report missing.' }
  return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}
function Get-Baseline {
  if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) { throw '0010 evidence missing.' }
  return Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
}
function Assert-FinalEvidence([string]$id) {
  $lines = @(Invoke-ReadSql $id $finalPath)
  if ($lines.Count -ne 2 -or $lines[0] -cne '1') {
    throw "Final integrity/privilege gate failed on $id."
  }
  return $lines[1] | ConvertFrom-Json
}
function Assert-WriterIsolation([string]$id, [string]$expectedHash = '',
    [bool]$requireFresh = $false) {
  if ([string]::IsNullOrWhiteSpace($WriterIsolationEvidencePath) -or
      -not (Test-Path -LiteralPath $WriterIsolationEvidencePath -PathType Leaf)) {
    throw 'Sanitized application-writer isolation evidence is required.'
  }
  $hash = (Get-FileHash -LiteralPath $WriterIsolationEvidencePath -Algorithm SHA256).Hash
  if ($expectedHash -ne '' -and $hash -cne $expectedHash) {
    throw 'Application-writer isolation evidence changed after preflight.'
  }
  $attestationPath = (Resolve-Path -LiteralPath $WriterIsolationEvidencePath).Path
  $evidenceBoundary = [IO.Path]::GetFullPath($EvidenceDir).TrimEnd([char]'\') + '\'
  if (-not $attestationPath.StartsWith($evidenceBoundary,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Writer-isolation evidence must be saved in the external evidence directory.'
  }
  $evidence = Get-Content -LiteralPath $WriterIsolationEvidencePath -Raw | ConvertFrom-Json
  if ($evidence.project_id -cne $project -or $evidence.child_branch_id -cne $id -or
      ($evidence.deployed_app_bindings -isnot [int] -and
        $evidence.deployed_app_bindings -isnot [long]) -or
      ($evidence.scheduled_writer_bindings -isnot [int] -and
        $evidence.scheduled_writer_bindings -isnot [long]) -or
      $evidence.deployed_app_bindings -ne 0 -or $evidence.scheduled_writer_bindings -ne 0 -or
      [string]::IsNullOrWhiteSpace($evidence.change_reference) -or
      [string]::IsNullOrWhiteSpace($evidence.recorded_at_utc) -or
      [string]::IsNullOrWhiteSpace($evidence.freeze_until_utc) -or
      $evidence.recorded_at_utc -cnotmatch 'Z$' -or
      $evidence.freeze_until_utc -cnotmatch 'Z$') {
    throw 'Application-writer isolation attestation is incomplete or names another branch.'
  }
  $recorded = [datetimeoffset]::Parse($evidence.recorded_at_utc)
  $freezeUntil = [datetimeoffset]::Parse($evidence.freeze_until_utc)
  $remainingHours = if ($expectedHash -eq '') { 2 } else { 0.5 }
  if ($recorded -gt [datetimeoffset]::UtcNow -or
      (($expectedHash -eq '' -or $requireFresh) -and
        $recorded -lt [datetimeoffset]::UtcNow.AddHours(-2)) -or
      $freezeUntil -lt [datetimeoffset]::UtcNow.AddHours($remainingHours)) {
    throw 'Writer-isolation attestation is stale or its change freeze expires too soon.'
  }
  return $hash
}
function New-ExecutionWrapper([string]$sourcePath, [string]$sourceHash,
    [string]$label) {
  Assert-FileHash $sourcePath $sourceHash
  $prefix = @'
SET lock_timeout = '15s';
SET statement_timeout = '10min';
SET idle_in_transaction_session_timeout = '12min';
SELECT 'REL04_SETTINGS|' || jsonb_build_object(
  'database', current_database(), 'role', current_user,
  'lock_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'lock_timeout'),
  'statement_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout'),
  'idle_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
)::text AS rel04_session_settings;
SELECT 1 / CASE WHEN current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'lock_timeout') = 15000
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout') = 600000
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') = 720000
  THEN 1 ELSE 0 END AS rel04_settings_gate;
'@
  $content = $prefix + [Environment]::NewLine + [IO.File]::ReadAllText($sourcePath)
  $wrapperPath = Join-Path $EvidenceDir ("rel04-{0}-{1}.sql" -f $label,
    [guid]::NewGuid().ToString('N'))
  $stream = [IO.File]::Open($wrapperPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write($content) } finally { $writer.Dispose() }
  } finally { $stream.Dispose() }
  if ([IO.File]::ReadAllText($wrapperPath) -cne $content) {
    throw "Generated wrapper differs from reviewed content: $wrapperPath"
  }
  Assert-FileHash $sourcePath $sourceHash
  $wrapperHash = (Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash
  return [pscustomobject]@{ path=$wrapperPath; sha256=$wrapperHash }
}
function Invoke-LoggedWrapper([string]$id, $wrapper, [string]$log,
    [bool]$quiet, [string]$stage = '') {
  if ([string]::IsNullOrWhiteSpace($id) -or
      $id -in @($production,$rehearsal,$checkpoint)) {
    throw 'Missing or protected SQL branch ID.'
  }
  Assert-FileHash $wrapper.path $wrapper.sha256
  $args = @('neon@latest','psql',$id,'--project-id',$project,
    '--role-name','neondb_owner','--database-name','neondb','--ssl','verify-full','--',
    '-X')
  if ($quiet) { $args += '-qAt' } else { $args += '-At' }
  $args += @('-v','ON_ERROR_STOP=1')
  if ($stage -ne '') { $args += @('-v',"stage=$stage") }
  $args += @('-f',$wrapper.path)
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $streamItems = @(& npx.cmd @args 2>&1 | Tee-Object -FilePath $log)
    $processExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  $stdoutLines = @($streamItems | Where-Object {
    $_ -isnot [System.Management.Automation.ErrorRecord]
  } | ForEach-Object { [string]$_ })
  $stderrLines = @($streamItems | Where-Object {
    $_ -is [System.Management.Automation.ErrorRecord]
  } | ForEach-Object { $_.ToString() })
  [IO.File]::WriteAllLines("$log.stdout", [string[]]$stdoutLines)
  [IO.File]::WriteAllLines("$log.stderr", [string[]]$stderrLines)
  $knownWarning = 'psql binary not found on PATH; falling back to embedded TypeScript psql'
  $knownBanner = 'Connecting to the database; launching embedded psql (TypeScript)...'
  $nativeBanner = 'Connecting to the database; launching psql...'
  $seenSqlOutput = $false
  foreach ($item in $streamItems) {
    $message = $item.ToString().Trim() -creplace '^npx\.cmd\s*:\s*', ''
    if ($item -is [System.Management.Automation.ErrorRecord]) {
      if ($message -ceq $nativeBanner -and $seenSqlOutput) {
        throw "Native psql startup banner followed SQL output; inspect $log."
      }
    } elseif ($message -ne '' -and $message -cne $knownBanner -and
        $message -cne $nativeBanner -and $message -cne $knownWarning) {
      $seenSqlOutput = $true
    }
  }
  $warningCount = 0
  $bannerCount = 0
  foreach ($line in $stderrLines) {
    $message = $line.Trim() -creplace '^npx\.cmd\s*:\s*', ''
    if ($message -ceq $nativeBanner) {
      $bannerCount++
    } elseif ($message -ceq $knownWarning) {
      $warningCount++
    } else {
      throw "Unexpected psql stderr (exit $processExit); inspect $log and $log.stderr."
    }
  }
  $sqlLines = [System.Collections.Generic.List[string]]::new()
  $startedSql = $false
  foreach ($line in $stdoutLines) {
    $message = $line.Trim()
    if (-not $startedSql -and $message -eq '') { continue }
    if ($startedSql -and $message -ceq $nativeBanner) {
      throw "Native psql startup banner followed SQL output; inspect $log."
    }
    if (-not $startedSql -and
        ($message -ceq $knownBanner -or $message -ceq $nativeBanner)) {
      $bannerCount++
      continue
    }
    if (-not $startedSql -and $message -ceq $knownWarning) {
      $warningCount++
      continue
    }
    $startedSql = $true
    $sqlLines.Add($line)
  }
  if ($warningCount -gt 1 -or $bannerCount -gt 1) {
    throw "Duplicate psql startup messages; inspect $log."
  }
  Assert-FileHash $wrapper.path $wrapper.sha256
  return [pscustomobject]@{ exit=$processExit; sqlLines=@($sqlLines.ToArray());
    log=$log; stdoutLog="$log.stdout"; stderrLog="$log.stderr" }
}
function Assert-EmbeddedPsqlPreflight([string]$id) {
  $wrapper = New-ExecutionWrapper $gatePath `
    'CCFFDED439486F0146E3F5F9554FC6C81A9EE8CA17C1B88ED9E47D7C9D7D6488' 'preflight'
  $preflightLog = Join-Path $EvidenceDir ("rel04-preflight-wrapper-{0}.log" -f
    [guid]::NewGuid().ToString('N'))
  $preflightResult = Invoke-LoggedWrapper $id $wrapper $preflightLog $true '0010'
  $preflightExit = $preflightResult.exit
  Write-Output "Preflight wrapper SHA-256 $($wrapper.sha256); raw log $preflightLog; stdout $($preflightResult.stdoutLog); stderr $($preflightResult.stderrLog); psql exit $preflightExit."
  $settingLines = @($preflightResult.sqlLines)
  Write-Output "Preflight SQL output contains $($settingLines.Count) nonempty lines; inspect $preflightLog."
  if ($settingLines.Count -eq 0 -or
      -not $settingLines[0].StartsWith('REL04_SETTINGS|')) {
    throw "Embedded psql settings diagnostic is missing (exit $preflightExit); inspect $preflightLog."
  }
  try { $effective = $settingLines[0].Substring(15) | ConvertFrom-Json } catch {
    throw "Embedded psql settings row is not JSON; inspect $preflightLog."
  }
  if ($effective.database -cne 'neondb' -or $effective.role -cne 'neondb_owner' -or
      $effective.lock_timeout_ms -ne 15000 -or
      $effective.statement_timeout_ms -ne 600000 -or
      $effective.idle_timeout_ms -ne 720000) {
    throw "Embedded psql session settings, database, or role differ; inspect $preflightLog."
  }
  if ($preflightExit -ne 0) {
    throw "Embedded psql exited $preflightExit after the settings diagnostic; inspect SQL errors in $preflightLog."
  }
  if ($settingLines.Count -ne 3) {
    throw "Embedded psql -qAt/-f output format differs: expected 3 rows, got $($settingLines.Count); inspect $preflightLog."
  }
  if ($settingLines[1] -cne '1') {
    throw "Embedded psql settings assertion output differs; inspect $preflightLog."
  }
  if ($settingLines[2] -cne '1') {
    throw "Embedded psql stage=0010 binding or stage-gate output differs; inspect $preflightLog."
  }
  $runShapeLog = Join-Path $EvidenceDir ("rel04-preflight-run-shape-{0}.log" -f
    [guid]::NewGuid().ToString('N'))
  $runShapeResult = Invoke-LoggedWrapper $id $wrapper $runShapeLog $false '0010'
  $runShapeExit = $runShapeResult.exit
  Write-Output "Preflight Run-shape SQL log $runShapeLog; psql exit $runShapeExit."
  $runShapeLines = @($runShapeResult.sqlLines)
  $expectedRunShape = @('SET','SET','SET',$settingLines[0],'1','BEGIN','SET','1','ROLLBACK')
  if ($runShapeExit -ne 0 -or $runShapeLines.Count -ne $expectedRunShape.Count -or
      (@(for ($i=0; $i -lt [Math]::Min($runShapeLines.Count,$expectedRunShape.Count); $i++) {
        if ($runShapeLines[$i] -cne $expectedRunShape[$i]) { $i }
      })).Count -ne 0) {
    throw "Embedded psql Run-shape -At/-f output, settings, stage binding, or rollback tag differs (exit $runShapeExit); inspect $runShapeLog."
  }
  $previousPreference = $ErrorActionPreference
  $negativeLog = Join-Path $EvidenceDir ("rel04-preflight-negative-{0}.log" -f
    (Get-Date -Format 'yyyyMMdd-HHmmss'))
  try {
    $ErrorActionPreference = 'Continue'
    & npx.cmd neon@latest psql $id --project-id $project `
      --role-name neondb_owner --database-name neondb --ssl verify-full -- `
      -X -qAt -v ON_ERROR_STOP=1 -c 'SELECT 1 / 0;' 2>&1 |
      Tee-Object -FilePath $negativeLog | Out-Null
    $negativeExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $negativeOutput = Get-Content -LiteralPath $negativeLog -Raw
  if ($negativeExit -eq 0 -or
      ($negativeOutput | Out-String) -notmatch 'division by zero') {
    throw 'Embedded psql did not return the expected failing read-only SQL result.'
  }
}
function Wait-Ready([string]$id, [string]$name) {
  for ($attempt=0; $attempt -lt 12; $attempt++) {
    $branch = Get-Branch $id
    if ($branch.name -cne $name -or $branch.parent_id -cne $checkpoint -or
        $branch.default -ne $false) { throw 'Created child identity differs.' }
    if ($branch.current_state -ceq 'ready') { return $branch }
    Start-Sleep -Seconds 5
  }
  throw 'Child did not become ready; retain it for investigation.'
}

if (-not $OperatorApproved) { throw 'Operator approval for this phase is required.' }
if (-not [IO.Path]::IsPathRooted($EvidenceDir)) {
  throw 'Evidence directory must be an absolute path outside the repository.'
}
$evidenceFull = [IO.Path]::GetFullPath($EvidenceDir)
$repoBoundary = $repoRoot.TrimEnd([char]'\') + '\'
if ($evidenceFull.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $evidenceFull.StartsWith($repoBoundary, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Evidence directory must be outside the repository.'
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
Assert-ToolFiles
$manifest = @(Get-Manifest)
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$runLog = Join-Path $EvidenceDir ("rel04-{0}-{1}.log" -f $Phase.ToLowerInvariant(),
  (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $runLog
try {
  if ($Phase -eq 'Create') {
    if (-not $ExpiryVerifiedInConsole) { throw 'Verify checkpoint expiry in Neon console first.' }
    if (Test-Path -LiteralPath $reportPath) { throw 'Existing report; do not create a second child.' }
    Assert-Checkpoint
    Assert-Stage $checkpoint 10
    $baseline = Get-Snapshot $checkpoint
    Assert-Baseline $baseline
    $listedRaw = & npx.cmd neon@latest branches list --project-id $project --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list branch names.' }
    $listed = $listedRaw | Out-String | ConvertFrom-Json
    if (@($listed | Where-Object { $_.name -eq $childName }).Count -ne 0) {
      throw 'REL-04 child name already exists; stop.'
    }
    $createdRaw = & npx.cmd neon@latest branches create --project-id $project `
      --parent $checkpoint --name $childName --no-secrets --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Child creation failed.' }
    $created = ($createdRaw | Out-String | ConvertFrom-Json).branch
    if ($null -eq $created -or [string]::IsNullOrWhiteSpace($created.id) -or
        $created.project_id -cne $project -or $created.parent_id -cne $checkpoint -or
        $created.name -cne $childName -or $created.default -ne $false) {
      throw 'Created child metadata differs; retain branch for investigation.'
    }
    Save-Json (Join-Path $EvidenceDir 'rel04-created-branch.json') ([ordered]@{
      id=$created.id; project=$project; parent=$checkpoint; name=$childName;
      created_utc=[datetime]::UtcNow })
    $null = Wait-Ready $created.id $childName
    Assert-Stage $created.id 10
    $childBaseline = Get-Snapshot $created.id
    Assert-Baseline $childBaseline
    Assert-Preserved $baseline $childBaseline
    if ($baseline.catalog_hash -cne $childBaseline.catalog_hash) {
      throw '0010 checkpoint/child catalog differs; retain child.'
    }
    Save-Json $baselinePath $baseline
    $report = [ordered]@{ status='created'; project=$project; checkpoint=$checkpoint;
      child=$created.id; manifest_sha256=$manifestHash; created_utc=[datetime]::UtcNow;
      completed=@(); stage_logs=@(); baseline_catalog=$baseline.catalog_hash }
    Save-Json $reportPath $report
    Write-Output "REL-04 child created and exact 0010 baseline verified: $($created.id)"
  }
  elseif ($Phase -eq 'Preflight') {
    $report = Get-Report
    if ($report.status -cnotin @('created','preflight_passed') -or
        $report.child -cne $ChildBranchId -or
        $report.manifest_sha256 -cne $manifestHash) {
      throw 'Read-only preflight requires an unchanged, unused REL-04 child.'
    }
    $null = Assert-Child $ChildBranchId $childName
    $isolationHash = Assert-WriterIsolation $ChildBranchId
    $baseline = Get-Baseline
    Assert-EmbeddedPsqlPreflight $ChildBranchId
    Assert-Stage $ChildBranchId 10
    $snapshot = Get-Snapshot $ChildBranchId
    Assert-Baseline $snapshot
    Assert-Preserved $baseline $snapshot
    if ($snapshot.catalog_hash -cne $baseline.catalog_hash) {
      throw 'Preflight catalog changed from the 0010 checkpoint.'
    }
    $report.status = 'preflight_passed'
    $report | Add-Member -NotePropertyName preflight_utc -NotePropertyValue ([datetime]::UtcNow) -Force
    $report | Add-Member -NotePropertyName isolation_evidence_sha256 -NotePropertyValue $isolationHash -Force
    $attestation = Get-Content -LiteralPath $WriterIsolationEvidencePath -Raw | ConvertFrom-Json
    $report | Add-Member -NotePropertyName isolation_change_reference `
      -NotePropertyValue $attestation.change_reference -Force
    $report | Add-Member -NotePropertyName isolation_freeze_until_utc `
      -NotePropertyValue $attestation.freeze_until_utc -Force
    Save-Json $reportPath $report
    Write-Output "REL-04 read-only psql and writer-isolation preflight passed on $ChildBranchId."
  }
  elseif ($Phase -eq 'Run') {
    $report = Get-Report
    if ($report.status -cne 'preflight_passed' -or @($report.completed).Count -ne 0 -or
        $report.child -cne $ChildBranchId -or $report.manifest_sha256 -cne $manifestHash) {
      throw 'Run requires a passed read-only preflight and an unchanged, unused child.'
    }
    $null = Assert-Child $ChildBranchId $childName
    $recordedPreflight = $report.preflight_utc
    if ($recordedPreflight -is [datetime]) {
      if ($recordedPreflight.Kind -eq [DateTimeKind]::Unspecified) {
        throw 'Preflight timestamp has no UTC interpretation.'
      }
      $preflightUtc = [datetimeoffset]::new($recordedPreflight.ToUniversalTime(),
        [timespan]::Zero)
    } elseif ($recordedPreflight -is [string] -and
        $recordedPreflight -cmatch '^/Date\((-?\d+)\)/$') {
      $preflightUtc = [datetimeoffset]::FromUnixTimeMilliseconds(
        [long]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture))
    } elseif ($recordedPreflight -is [string] -and
        $recordedPreflight -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
      $preflightUtc = [datetimeoffset]::Parse($recordedPreflight,
        [Globalization.CultureInfo]::InvariantCulture)
    } else {
      throw 'Preflight timestamp is missing or has no UTC interpretation.'
    }
    if ($preflightUtc -lt [datetimeoffset]::UtcNow.AddHours(-2)) {
      throw 'Read-only preflight is stale; repeat Preflight before any migration write.'
    }
    $null = Assert-WriterIsolation $ChildBranchId $report.isolation_evidence_sha256 $true
    $baseline = Get-Baseline
    $start = Get-Snapshot $ChildBranchId
    Assert-Baseline $start
    Assert-Preserved $baseline $start
    if ($start.catalog_hash -cne $baseline.catalog_hash) {
      throw 'Child changed since creation; stop.'
    }
    $report.status = 'running'
    Save-Json $reportPath $report
    try {
      foreach ($item in $manifest) {
        $null = Assert-Child $ChildBranchId $childName
        $null = Assert-WriterIsolation $ChildBranchId $report.isolation_evidence_sha256
        $before = Get-Snapshot $ChildBranchId
        Assert-Markers $before ([int]$item.number - 1)
        Assert-Preserved $baseline $before
        $migrationPath = Join-Path $repoRoot (Join-Path 'db/migrations' $item.file)
        Assert-FileHash $migrationPath $item.sha256
        $wrapper = New-ExecutionWrapper $migrationPath $item.sha256 $item.number
        $fileLog = Join-Path $EvidenceDir ("rel04-{0}-{1}.log" -f $item.number,
          (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $report | Add-Member -NotePropertyName current_migration -NotePropertyValue $item.number -Force
        $report | Add-Member -NotePropertyName current_log -NotePropertyValue $fileLog -Force
        $report | Add-Member -NotePropertyName current_wrapper -NotePropertyValue $wrapper.path -Force
        $report | Add-Member -NotePropertyName current_wrapper_sha256 -NotePropertyValue $wrapper.sha256 -Force
        Save-Json $reportPath $report
        $migrationResult = Invoke-LoggedWrapper $ChildBranchId $wrapper $fileLog $false
        $migrationExit = $migrationResult.exit
        if ($migrationExit -ne 0) { throw "Migration $($item.number) failed; do not rerun." }
        $logLines = @($migrationResult.sqlLines)
        $settingRows = @($logLines | Where-Object { $_ -clike 'REL04_SETTINGS|*' })
        if ($settingRows.Count -ne 1 -or $logLines.Count -lt 7 -or
            $logLines[0] -cne 'SET' -or $logLines[1] -cne 'SET' -or
            $logLines[2] -cne 'SET' -or $logLines[3] -cne $settingRows[0] -or
            $logLines[4] -cne '1' -or $logLines[5] -cne 'BEGIN') {
          throw "Migration $($item.number) session-settings output prefix differs; do not rerun."
        }
        try { $effective = $settingRows[0].Substring(15) | ConvertFrom-Json } catch {
          throw "Migration $($item.number) session-settings row is invalid; do not rerun."
        }
        if ($effective.database -cne 'neondb' -or
            $effective.role -cne 'neondb_owner' -or
            $effective.lock_timeout_ms -ne 15000 -or
            $effective.statement_timeout_ms -ne 600000 -or
            $effective.idle_timeout_ms -ne 720000) {
          throw "Migration $($item.number) session-settings assertion differs; do not rerun."
        }
        $commitLines = @($logLines | Where-Object { $_ -ceq 'COMMIT' })
        $rawCommitLines = @(Get-Content -LiteralPath $fileLog | Where-Object { $_ -ceq 'COMMIT' })
        if ($commitLines.Count -ne 1 -or $rawCommitLines.Count -ne 1 -or
            $logLines[-1] -cne 'COMMIT') {
          throw "Migration $($item.number) log lacks exactly one standalone COMMIT; do not rerun."
        }
        Assert-FileHash $migrationPath $item.sha256
        Assert-Stage $ChildBranchId ([int]$item.number)
        $after = Get-Snapshot $ChildBranchId
        Assert-Markers $after ([int]$item.number)
        Assert-Preserved $baseline $after
        Save-Json (Join-Path $EvidenceDir ("rel04-stage-$($item.number).json")) $after
        $report.completed = @($report.completed) + $item.number
        $report.stage_logs = @($report.stage_logs) + $fileLog
        $report.current_migration = $null
        $report.current_log = $null
        $report.current_wrapper = $null
        $report.current_wrapper_sha256 = $null
        Save-Json $reportPath $report
        Write-Output "Committed stage $($item.number) verified on $ChildBranchId."
      }
      $report.status = 'migrated'
      $report | Add-Member -NotePropertyName migrated_utc -NotePropertyValue ([datetime]::UtcNow) -Force
      Save-Json $reportPath $report
    } catch {
      $report.status = 'failed'
      $report | Add-Member -NotePropertyName failure -NotePropertyValue $_.Exception.Message -Force
      $report | Add-Member -NotePropertyName failed_utc -NotePropertyValue ([datetime]::UtcNow) -Force
      Save-Json $reportPath $report
      throw
    }
  }
  elseif ($Phase -eq 'Verify') {
    $report = Get-Report
    if ($report.status -cne 'migrated' -or $report.child -cne $ChildBranchId -or
        @($report.completed).Count -ne 17 -or $report.manifest_sha256 -cne $manifestHash) {
      throw 'Verify requires exactly 17 completed, unchanged migration steps.'
    }
    $null = Assert-Child $ChildBranchId $childName
    $reference = Get-Branch $rehearsal
    if ($reference.name -cne 'release-rehearsal-0010-0027' -or
        $reference.parent_id -cne $production -or $reference.default -ne $false -or
        $reference.current_state -cne 'ready') { throw 'REL-03 reference branch differs.' }
    $baseline = Get-Baseline
    Assert-Stage $ChildBranchId 27
    Assert-Stage $rehearsal 27
    $childSnapshot = Get-Snapshot $ChildBranchId
    $referenceSnapshot = Get-Snapshot $rehearsal
    Assert-Markers $childSnapshot 27
    Assert-Markers $referenceSnapshot 27
    Assert-Preserved $baseline $childSnapshot
    Assert-Preserved $baseline $referenceSnapshot
    if ($childSnapshot.catalog_hash -cne $referenceSnapshot.catalog_hash -or
        ($childSnapshot.data | ConvertTo-Json -Depth 10 -Compress) -cne
          ($referenceSnapshot.data | ConvertTo-Json -Depth 10 -Compress)) {
      throw 'Final structure, privileges, or preserved rows differ from REL-03.'
    }
    $childFinal = Assert-FinalEvidence $ChildBranchId
    $referenceFinal = Assert-FinalEvidence $rehearsal
    if (($childFinal | ConvertTo-Json -Depth 10 -Compress) -cne
        ($referenceFinal | ConvertTo-Json -Depth 10 -Compress)) {
      throw 'Final audit/calendar/deletion/movement evidence differs from REL-03.'
    }
    Save-Json (Join-Path $EvidenceDir 'rel04-final-child.json') $childSnapshot
    Save-Json (Join-Path $EvidenceDir 'rel04-final-reference.json') $referenceSnapshot
    Save-Json (Join-Path $EvidenceDir 'rel04-final-ledgers.json') $childFinal
    $report.status = 'verified'
    $report | Add-Member -NotePropertyName verified_utc -NotePropertyValue ([datetime]::UtcNow) -Force
    $report | Add-Member -NotePropertyName final_catalog -NotePropertyValue $childSnapshot.catalog_hash -Force
    Save-Json $reportPath $report
    Write-Output "REL-04 final structure, data and audit comparison passed for $ChildBranchId."
  }
  elseif ($Phase -eq 'Restore') {
    if (-not $RestoreApproved -or -not $ExpiryVerifiedInConsole) {
      throw 'Separate restore-drill approval and expiry check are required.'
    }
    $report = Get-Report
    if ($report.status -cnotin @('verified','failed','running')) {
      throw 'Restore drill requires a verified, failed, or interrupted migration run.'
    }
    Assert-Checkpoint
    $baseline = Get-Baseline
    $listedRaw = & npx.cmd neon@latest branches list --project-id $project --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list branch names.' }
    $listed = $listedRaw | Out-String | ConvertFrom-Json
    if (@($listed | Where-Object { $_.name -eq $restoreName }).Count -ne 0) {
      throw 'Restore-drill child name already exists.'
    }
    $createdRaw = & npx.cmd neon@latest branches create --project-id $project `
      --parent $checkpoint --name $restoreName --no-secrets --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Restore-drill child creation failed.' }
    $created = ($createdRaw | Out-String | ConvertFrom-Json).branch
    if ($null -eq $created -or $created.project_id -cne $project -or
        $created.parent_id -cne $checkpoint -or $created.name -cne $restoreName -or
        $created.default -ne $false) { throw 'Restore child metadata differs; retain it.' }
    Save-Json (Join-Path $EvidenceDir 'rel04-restore-created.json') ([ordered]@{
      id=$created.id; project=$project; parent=$checkpoint; name=$restoreName;
      created_utc=[datetime]::UtcNow })
    $null = Wait-Ready $created.id $restoreName
    Assert-Stage $created.id 10
    $restored = Get-Snapshot $created.id
    Assert-Baseline $restored
    Assert-Preserved $baseline $restored
    if ($restored.catalog_hash -cne $baseline.catalog_hash) {
      throw 'Restored 0010 catalog differs; retain child for investigation.'
    }
    Save-Json (Join-Path $EvidenceDir 'rel04-restore-drill.json') $restored
    $report | Add-Member -NotePropertyName restore_branch -NotePropertyValue $created.id -Force
    $report | Add-Member -NotePropertyName restore_verified_utc -NotePropertyValue ([datetime]::UtcNow) -Force
    Save-Json $reportPath $report
    Write-Output "Independent 0010 restore-drill branch verified: $($created.id)"
  }
  else {
    if (-not $CleanupApproved -or [string]::IsNullOrWhiteSpace($CleanupBranchId)) {
      throw 'Separate cleanup approval and exact branch ID are required.'
    }
    $report = Get-Report
    $targetName = if ($CleanupBranchId -ceq $report.child -and
        $report.status -ceq 'verified' -and
        (Test-Path -LiteralPath (Join-Path $EvidenceDir 'rel04-final-child.json'))) {
        $childName
      } elseif ($CleanupBranchId -ceq $report.restore_branch -and
          $null -ne $report.restore_verified_utc -and
          (Test-Path -LiteralPath (Join-Path $EvidenceDir 'rel04-restore-drill.json'))) {
        $restoreName
      } else { throw 'Cleanup ID is not a verified REL-04 disposable child.' }
    $null = Assert-Child $CleanupBranchId $targetName
    $typed = Read-Host "Type DELETE $targetName $CleanupBranchId to delete only this child"
    if ($typed -cne "DELETE $targetName $CleanupBranchId") { throw 'Cleanup confirmation differs.' }
    $null = Assert-Child $CleanupBranchId $targetName
    & npx.cmd neon@latest branches delete $CleanupBranchId --project-id $project --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Child deletion failed; inspect provider state.' }
    Write-Output "Deleted only verified disposable child $CleanupBranchId."
  }
} finally {
  Stop-Transcript
}
