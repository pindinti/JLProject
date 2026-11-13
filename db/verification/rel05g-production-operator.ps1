param(
  [Parameter(Mandatory)][ValidateSet('Baseline','Preflight','Run','Verify')][string]$Phase,
  [Parameter(Mandatory)][string]$EvidenceDir,
  [string]$CheckpointBranchId,
  [string]$WriterFreezeEvidencePath,
  [switch]$OperatorApproved
)

$ErrorActionPreference = 'Stop'
$project = 'crimson-glade-72578238'
$production = 'br-orange-shadow-b6yu9uxu'
$endpoint = 'ep-tiny-union-b6r07ej7'
$checkpointBranchId = 'br-round-band-b6qslh9d'
$checkpointName = 'backup-pre-release-20261113'
$checkpointEndpointId = 'ep-bold-queen-b6a5ql7l'
$releaseCommit = 'c7303dd464efde744e6abc3847844c5f0972e9bf'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifestPath = Join-Path $PSScriptRoot 'rel04-migration-manifest.csv'
$snapshotPath = Join-Path $PSScriptRoot 'rel04-readonly-snapshot.sql'
$gatePath = Join-Path $PSScriptRoot 'rel04-stage-gate.sql'
$invariantsPath = Join-Path $PSScriptRoot 'rel05g-production-invariants.sql'
$finalPath = Join-Path $PSScriptRoot 'rel05g-production-final-gate.sql'
$reportPath = Join-Path $EvidenceDir 'rel05g-report.json'
$baselinePath = Join-Path $EvidenceDir 'rel05g-baseline.json'
$frozenBaselinePath = Join-Path $EvidenceDir 'rel05g-frozen-baseline.json'
$nativePsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$nativeCaBundle = 'C:\Program Files\Git\usr\ssl\cert.pem'

function Assert-NativePsql {
  if (-not (Test-Path -LiteralPath $nativePsqlPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $nativeCaBundle -PathType Leaf)) {
    throw 'Native PostgreSQL 18 psql or the TLS CA bundle is unavailable.'
  }
  $version = & $nativePsqlPath --version
  if ($LASTEXITCODE -ne 0 -or $version -cne 'psql (PostgreSQL) 18.7') {
    throw 'Native PostgreSQL psql version differs from the reviewed 18.7 client.'
  }
}

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
  Assert-FileHash $invariantsPath '29F8C6288FF421F501B5D29E040AE1474D726FE871A34510ED6E4560BDC3A9D5'
  Assert-FileHash $finalPath 'B5BFB55AA414FF75C4893E50722D60808EA270EAD48507F522135D1A889BE424'
}
function Get-Manifest {
  $items = @(Import-Csv -LiteralPath $manifestPath)
  if ($items.Count -ne 17) { throw 'Migration manifest must contain 17 files.' }
  for ($i=0; $i -lt 17; $i++) {
    $number = '{0:D4}' -f ($i + 11)
    $item = $items[$i]
    if ($item.number -cne $number -or $item.file -cnotmatch "^${number}_.+\.sql$" -or
        $item.sha256 -cnotmatch '^[0-9A-F]{64}$') {
      throw "Manifest order or format differs at $number."
    }
    $path = Join-Path $repoRoot (Join-Path 'db/migrations' $item.file)
    Assert-FileHash $path $item.sha256
    $source = [IO.File]::ReadAllText($path)
    if ([regex]::Matches($source,'(?m)^BEGIN;\s*$').Count -ne 1 -or
        [regex]::Matches($source,'(?m)^COMMIT;\s*$').Count -ne 1 -or
        -not $source.TrimEnd().EndsWith('COMMIT;') -or $source -match '(?m)^\\') {
      throw "Migration $number lacks the reviewed transaction shape."
    }
  }
  return $items
}
function Get-Branch([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id)) { throw 'Branch ID is missing.' }
  $raw = & npx.cmd neon@latest branches get $id --project-id $project --output json --no-analytics
  if ($LASTEXITCODE -ne 0) { throw "Branch metadata lookup failed: $id" }
  $branch = $raw | Out-String | ConvertFrom-Json
  if ($null -ne $branch.branch) { $branch = $branch.branch }
  if ($branch.id -cne $id -or $branch.project_id -cne $project) {
    throw 'Branch/project identity differs.'
  }
  return $branch
}
function Get-Endpoints {
  $raw = & npx.cmd neon@latest api "/projects/$project/endpoints" -X GET --output json --no-analytics
  if ($LASTEXITCODE -ne 0) { throw 'Endpoint metadata lookup failed.' }
  $result = $raw | Out-String | ConvertFrom-Json
  return @($result.endpoints)
}
function Assert-ProductionTarget {
  $branch = Get-Branch $production
  if ($branch.name -cne 'production' -or $branch.default -ne $true -or
      $branch.current_state -cne 'ready') { throw 'Production branch metadata differs.' }
  $matching = @(Get-Endpoints | Where-Object { $_.branch_id -ceq $production })
  if ($matching.Count -ne 1 -or $matching[0].id -cne $endpoint -or
      $matching[0].type -cne 'read_write') {
    throw 'Production endpoint is not attached to the pinned branch.'
  }
}
function Assert-Checkpoint([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id) -or $id -cne $checkpointBranchId -or $id -ceq $production) {
    throw 'Checkpoint ID is missing or differs from the approved existing backup.'
  }
  $branch = Get-Branch $id
  if ($branch.name -cne $checkpointName -or $branch.parent_id -cne $production -or
      $branch.default -ne $false -or $branch.current_state -cne 'ready' -or
      $null -ne $branch.expires_at) {
    throw 'Checkpoint identity, parent, readiness, or retention differs.'
  }
  $endpoints = @(Get-Endpoints | Where-Object { $_.branch_id -ceq $id })
  if ($endpoints.Count -ne 1 -or $endpoints[0].id -cne $checkpointEndpointId -or
      $endpoints[0].type -cne 'read_only') {
    throw 'Checkpoint must have exactly one read-only compute endpoint.'
  }
}
function Invoke-ReadSql([string]$id, [string]$path, [string]$stage = '') {
  if ($id -cne $production -and $id -cne $CheckpointBranchId) {
    throw 'SQL branch ID is not the pinned Production or verified checkpoint.'
  }
  $endpointType = if ($id -ceq $production) { 'read_write' } else { 'read_only' }
  $args = @('neon@latest','psql',$id,'--project-id',$project,
    '--role-name','neondb_owner','--database-name','neondb','--endpoint-type',$endpointType,
    '--ssl','verify-full','--',
    '-X','-qAt','-v','ON_ERROR_STOP=1')
  if ($stage -ne '') { $args += @('-v',"stage=$stage") }
  $args += @('-f',$path)
  $output = & npx.cmd @args
  if ($LASTEXITCODE -ne 0) { throw "Read-only SQL failed on ${id}: $path" }
  return @(($output | Out-String).Trim() -split "`r?`n" | Where-Object { $_ -ne '' })
}
function Get-Snapshot([string]$id, [bool]$requireNoWorkerSessions = $true) {
  $lines = @(Invoke-ReadSql $id $snapshotPath)
  if ($lines.Count -ne 1) { throw 'Snapshot did not return one JSON row.' }
  $snap = $lines[0] | ConvertFrom-Json
  if ($snap.database -cne 'neondb' -or $snap.role -cne 'neondb_owner' -or
      ($requireNoWorkerSessions -and $snap.worker_sessions -ne 0)) {
    throw 'Database, role, or required no-Worker-session gate failed.'
  }
  return $snap
}
function Assert-Stage([string]$id, [int]$stage) {
  $lines = @(Invoke-ReadSql $id $gatePath ('{0:D4}' -f $stage))
  if ($lines.Count -ne 1 -or $lines[0] -cne '1') {
    throw "Committed structural gate failed at $stage."
  }
}
function Assert-Invariants([string]$id) {
  $lines = @(Invoke-ReadSql $id $invariantsPath)
  if ($lines.Count -ne 1 -or $lines[0] -cne '1') {
    throw 'Original Production data and relationship invariant gate failed.'
  }
}
function Assert-Markers($snap, [int]$stage) {
  $thresholds = @{clone=11;calendar=13;planning=14;reschedule=17;reversal=18;
    calendar_history=19;deletion=20;product_history=22;color=23;
    root_pair=25;movement=26;movement_history=27}
  foreach ($key in $thresholds.Keys) {
    if ($snap.markers.$key -ne ($stage -ge $thresholds[$key])) {
      throw "Unexpected $key marker at stage $stage."
    }
  }
}
function Assert-Baseline($snap) {
  Assert-Markers $snap 10
  $expected = @{workspaces=1;workspace_memberships=4;products=6;
    product_disciplines=21;stage_definitions=11;discipline_stages=47;
    stage_activities=99;business_targets=19;import_batches=1;
    import_source_rows=51;initial_schedule_revisions=1}
  foreach ($key in $expected.Keys) {
    if ($snap.data.$key.count -ne $expected[$key]) {
      throw "Production 0010 count differs for $key."
    }
  }
  if ($snap.dates -cne '548d37609a8773701c88907741716336' -or
      $snap.r00 -cne '1f4e4ebde42f6a10db014f2dda707e6b') {
    throw 'Production activity dates or independent R00 fingerprint differ.'
  }
}
function Assert-Preserved($baseline, $current) {
  if (($baseline.data | ConvertTo-Json -Depth 10 -Compress) -cne
      ($current.data | ConvertTo-Json -Depth 10 -Compress) -or
      $baseline.dates -cne $current.dates -or $baseline.r00 -cne $current.r00) {
    throw 'Original public rows, protected audit rows, dates, or R00 changed.'
  }
}
function Save-Json([string]$path, $value) {
  [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
}
function Get-Report {
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'Report missing.' }
  return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}
function Get-Baseline {
  if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) { throw 'Baseline missing.' }
  return Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
}
function Get-FrozenBaseline {
  if (-not (Test-Path -LiteralPath $frozenBaselinePath -PathType Leaf)) {
    throw 'Post-freeze preservation baseline missing.'
  }
  return Get-Content -LiteralPath $frozenBaselinePath -Raw | ConvertFrom-Json
}
function Assert-WriterFreeze([string]$expectedHash = '', [bool]$fresh = $false) {
  if ([string]::IsNullOrWhiteSpace($WriterFreezeEvidencePath) -or
      -not (Test-Path -LiteralPath $WriterFreezeEvidencePath -PathType Leaf)) {
    throw 'Production application-writer freeze evidence is required.'
  }
  $path = (Resolve-Path -LiteralPath $WriterFreezeEvidencePath).Path
  $boundary = [IO.Path]::GetFullPath($EvidenceDir).TrimEnd([char]'\') + '\'
  if (-not $path.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Freeze evidence must be inside the external evidence directory.'
  }
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  if ($expectedHash -ne '' -and $hash -cne $expectedHash) {
    throw 'Writer-freeze evidence changed after preflight.'
  }
  $e = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ($e.project_id -cne $project -or $e.production_branch_id -cne $production -or
      $e.application_writes_blocked -ne $true -or
      $e.scheduled_writes_blocked -ne $true -or
      [string]::IsNullOrWhiteSpace($e.isolation_method) -or
      [string]::IsNullOrWhiteSpace($e.change_reference) -or
      $e.recorded_at_utc -cnotmatch 'Z$' -or
      $e.freeze_until_utc -cnotmatch 'Z$') {
    throw 'Production write-freeze attestation is incomplete.'
  }
  $recorded = [datetimeoffset]::Parse($e.recorded_at_utc)
  $until = [datetimeoffset]::Parse($e.freeze_until_utc)
  if ($recorded -gt [datetimeoffset]::UtcNow -or
      (($fresh -or $expectedHash -eq '') -and $recorded -lt [datetimeoffset]::UtcNow.AddHours(-2)) -or
      $until -lt [datetimeoffset]::UtcNow.AddMinutes(30)) {
    throw 'Production write freeze is stale or ends too soon.'
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
SELECT 'REL05G_SETTINGS|' || jsonb_build_object(
  'database', current_database(), 'role', current_user,
  'lock_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'lock_timeout'),
  'statement_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout'),
  'idle_timeout_ms', (SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
)::text AS rel05g_session_settings;
SELECT 1 / CASE WHEN current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'lock_timeout') = 15000
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'statement_timeout') = 600000
  AND (SELECT setting::bigint FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout') = 720000
  THEN 1 ELSE 0 END AS rel05g_settings_gate;
'@
  $content = $prefix + [Environment]::NewLine + [IO.File]::ReadAllText($sourcePath)
  $path = Join-Path $EvidenceDir ("rel05g-{0}-{1}.sql" -f $label,
    [guid]::NewGuid().ToString('N'))
  $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
    $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    try { $writer.Write($content) } finally { $writer.Dispose() }
  } finally { $stream.Dispose() }
  if ([IO.File]::ReadAllText($path) -cne $content) { throw 'Generated wrapper differs.' }
  Assert-FileHash $sourcePath $sourceHash
  return [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
function Invoke-LoggedWrapper([string]$id, $wrapper, [string]$log,
    [bool]$quiet, [string]$stage = '') {
  if ($id -cne $production) { throw 'Migration SQL may target only the pinned Production branch.' }
  Assert-NativePsql
  Assert-FileHash $wrapper.path $wrapper.sha256
  $args = @('neon@latest','psql',$production,'--project-id',$project,
    '--role-name','neondb_owner','--database-name','neondb','--endpoint-type','read_write',
    '--ssl','verify-full','--','-X')
  if ($quiet) { $args += '-qAt' } else { $args += '-At' }
  $args += @('-v','ON_ERROR_STOP=1')
  if ($stage -ne '') { $args += @('-v',"stage=$stage") }
  $args += @('-f',$wrapper.path)
  $previous = $ErrorActionPreference
  $hadDebug = Test-Path Env:DEBUG
  $previousDebug = $env:DEBUG
  $previousPath = $env:PATH
  $hadFallback = Test-Path Env:NEONCTL_PSQL_FALLBACK
  $previousFallback = $env:NEONCTL_PSQL_FALLBACK
  $hadCaBundle = Test-Path Env:PGSSLROOTCERT
  $previousCaBundle = $env:PGSSLROOTCERT
  $items = @()
  $exit = $null
  try {
    $ErrorActionPreference = 'Continue'
    # Neon CLI 9.4.0 gates non-error DEBUG stderr on process.env.DEBUG.
    # Clear it only for this child process; it has no effect on PostgreSQL SQL execution.
    Remove-Item Env:DEBUG -ErrorAction SilentlyContinue
    Remove-Item Env:NEONCTL_PSQL_FALLBACK -ErrorAction SilentlyContinue
    $env:PATH = (Split-Path -Parent $nativePsqlPath) + ';' + $previousPath
    $env:PGSSLROOTCERT = $nativeCaBundle
    $global:LASTEXITCODE = $null
    try {
      $items = @(& npx.cmd @args 2>&1)
      $exit = $global:LASTEXITCODE
    } catch { $items += $_ }
    if ($items.Count -gt 0) { $items | Tee-Object -FilePath $log | Out-Null }
    else { [IO.File]::WriteAllText($log,'',[Text.UTF8Encoding]::new($false)) }
  } finally {
    if ($hadDebug) { $env:DEBUG = $previousDebug }
    else { Remove-Item Env:DEBUG -ErrorAction SilentlyContinue }
    if ($hadFallback) { $env:NEONCTL_PSQL_FALLBACK = $previousFallback }
    else { Remove-Item Env:NEONCTL_PSQL_FALLBACK -ErrorAction SilentlyContinue }
    if ($hadCaBundle) { $env:PGSSLROOTCERT = $previousCaBundle }
    else { Remove-Item Env:PGSSLROOTCERT -ErrorAction SilentlyContinue }
    $env:PATH = $previousPath
    $ErrorActionPreference = $previous
  }
  $stdout = @($items | Where-Object {$_ -isnot [Management.Automation.ErrorRecord]} |
    ForEach-Object {[string]$_})
  $stderr = @($items | Where-Object {$_ -is [Management.Automation.ErrorRecord]} |
    ForEach-Object {$_.ToString()})
  [IO.File]::WriteAllLines("$log.stdout",[string[]]$stdout)
  [IO.File]::WriteAllLines("$log.stderr",[string[]]$stderr)
  $parsedExit = 0
  $hasExit = $null -ne $exit -and [int]::TryParse([string]$exit,[ref]$parsedExit)
  $exitText = if ($hasExit) { [string]$parsedExit } else { 'UNAVAILABLE' }
  [IO.File]::WriteAllText("$log.exit",$exitText + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
  if (-not $hasExit) { throw "Neon psql process exit code was unavailable; inspect $log and $log.exit" }
  if ($parsedExit -ne 0) { throw "Neon psql process exited with code $parsedExit; inspect $log and $log.exit" }
  $known = @('Connecting to the database; launching psql...')
  foreach ($line in $stderr) {
    $message = $line.Trim() -creplace '^npx\.cmd\s*:\s*',''
    if ($message -cnotin $known) { throw "Unexpected psql stderr; inspect $log.stderr" }
  }
  if (@($stderr).Count -gt 1) { throw "Duplicate psql startup messages; inspect $log.stderr" }
  $sql = [Collections.Generic.List[string]]::new()
  $started = $false
  $startup = [Collections.Generic.List[string]]::new()
  foreach ($line in $stdout) {
    $message = $line.Trim()
    if (-not $started -and $message -eq '') { continue }
    if (-not $started -and $message -cin $known) { $startup.Add($message); continue }
    $started = $true
    if ($message -cin $known) { throw "Late psql startup message; inspect $log" }
    $sql.Add($line)
  }
  if (($startup.Count + $stderr.Count) -ne 1 -or
      @($sql | Where-Object {$_ -match '(?i)\b(WARNING|ERROR|NOTICE):'}).Count -gt 0) {
    throw "Unexpected SQL output; inspect $log"
  }
  Assert-FileHash $wrapper.path $wrapper.sha256
  return [pscustomobject]@{exit=$exit;sqlLines=@($sql.ToArray());log=$log}
}
function Assert-SettingsRows([string[]]$lines) {
  if ($lines.Count -lt 3 -or -not $lines[0].StartsWith('REL05G_SETTINGS|')) {
    throw 'Session-settings diagnostic is missing.'
  }
  try { $settings = $lines[0].Substring(16) | ConvertFrom-Json } catch {
    throw 'Session-settings JSON is invalid.'
  }
  if ($settings.database -cne 'neondb' -or $settings.role -cne 'neondb_owner' -or
      $settings.lock_timeout_ms -ne 15000 -or
      $settings.statement_timeout_ms -ne 600000 -or
      $settings.idle_timeout_ms -ne 720000 -or $lines[1] -cne '1') {
    throw 'Session settings, database, role, or SQL assertion differ.'
  }
}
function Assert-MigrationOutput([string[]]$lines, [string]$log, [string]$number) {
  if ($lines.Count -lt 7 -or $lines[0] -cne 'SET' -or
      $lines[1] -cne 'SET' -or $lines[2] -cne 'SET' -or
      $lines[5] -cne 'BEGIN') {
    throw "Migration $number session/BEGIN output differs."
  }
  Assert-SettingsRows @($lines[3],$lines[4],$lines[5])
  $commits = @($lines | Where-Object {$_ -ceq 'COMMIT'})
  $rawCommits = @(Get-Content -LiteralPath $log | Where-Object {$_ -ceq 'COMMIT'})
  if ($commits.Count -ne 1 -or $rawCommits.Count -ne 1 -or
      $lines[-1] -cne 'COMMIT') {
    throw "Migration $number lacks exactly one final standalone COMMIT."
  }
}
function Assert-PsqlPreflight {
  $sourceHash = 'CCFFDED439486F0146E3F5F9554FC6C81A9EE8CA17C1B88ED9E47D7C9D7D6488'
  $wrapper = New-ExecutionWrapper $gatePath $sourceHash 'preflight'
  $log = Join-Path $EvidenceDir ("rel05g-preflight-{0}.log" -f [guid]::NewGuid().ToString('N'))
  $result = Invoke-LoggedWrapper $production $wrapper $log $true '0010'
  if ($result.exit -ne 0 -or $result.sqlLines.Count -ne 3) {
    throw "Quiet psql preflight failed; inspect $log"
  }
  Assert-SettingsRows $result.sqlLines
  if ($result.sqlLines[2] -cne '1') { throw 'Stage variable or quiet output differs.' }
  $log = Join-Path $EvidenceDir ("rel05g-run-shape-{0}.log" -f [guid]::NewGuid().ToString('N'))
  $runShape = Invoke-LoggedWrapper $production $wrapper $log $false '0010'
  $lines = @($runShape.sqlLines)
  if ($runShape.exit -ne 0 -or $lines.Count -ne 9 -or
      $lines[0] -cne 'SET' -or $lines[1] -cne 'SET' -or
      $lines[2] -cne 'SET' -or $lines[4] -cne '1' -or
      $lines[5] -cne 'BEGIN' -or $lines[6] -cne 'SET' -or
      $lines[7] -cne '1' -or $lines[8] -cne 'ROLLBACK') {
    throw "Run-shape psql preflight failed; inspect $log"
  }
  Assert-SettingsRows @($lines[3],$lines[4],$lines[7])
  $negativeLog = Join-Path $EvidenceDir ("rel05g-negative-{0}.log" -f [guid]::NewGuid().ToString('N'))
  $previous = $ErrorActionPreference
  $hadDebug = Test-Path Env:DEBUG
  $previousDebug = $env:DEBUG
  Assert-NativePsql
  $previousPath = $env:PATH
  $hadFallback = Test-Path Env:NEONCTL_PSQL_FALLBACK
  $previousFallback = $env:NEONCTL_PSQL_FALLBACK
  $hadCaBundle = Test-Path Env:PGSSLROOTCERT
  $previousCaBundle = $env:PGSSLROOTCERT
  $negativeOutput = @()
  $negativeExit = $null
  try {
    $ErrorActionPreference = 'Continue'
    Remove-Item Env:DEBUG -ErrorAction SilentlyContinue
    Remove-Item Env:NEONCTL_PSQL_FALLBACK -ErrorAction SilentlyContinue
    $env:PATH = (Split-Path -Parent $nativePsqlPath) + ';' + $previousPath
    $env:PGSSLROOTCERT = $nativeCaBundle
    $global:LASTEXITCODE = $null
    try {
      $negativeOutput = @(& npx.cmd neon@latest psql $production --project-id $project `
        --role-name neondb_owner --database-name neondb --ssl verify-full -- `
        -X -qAt -v ON_ERROR_STOP=1 -c 'SELECT 1 / 0;' 2>&1)
      $negativeExit = $global:LASTEXITCODE
    } catch { $negativeOutput += $_ }
    if ($negativeOutput.Count -gt 0) {
      $negativeOutput | Tee-Object -FilePath $negativeLog | Out-Null
    } else { [IO.File]::WriteAllText($negativeLog,'',[Text.UTF8Encoding]::new($false)) }
  } finally {
    if ($hadDebug) { $env:DEBUG = $previousDebug }
    else { Remove-Item Env:DEBUG -ErrorAction SilentlyContinue }
    if ($hadFallback) { $env:NEONCTL_PSQL_FALLBACK = $previousFallback }
    else { Remove-Item Env:NEONCTL_PSQL_FALLBACK -ErrorAction SilentlyContinue }
    if ($hadCaBundle) { $env:PGSSLROOTCERT = $previousCaBundle }
    else { Remove-Item Env:PGSSLROOTCERT -ErrorAction SilentlyContinue }
    $env:PATH = $previousPath
    $ErrorActionPreference = $previous
  }
  $parsedNegativeExit = 0
  $hasNegativeExit = $null -ne $negativeExit -and
    [int]::TryParse([string]$negativeExit,[ref]$parsedNegativeExit)
  $negativeExitText = if ($hasNegativeExit) { [string]$parsedNegativeExit } else { 'UNAVAILABLE' }
  [IO.File]::WriteAllText("$negativeLog.exit",$negativeExitText + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
  if (-not $hasNegativeExit -or $parsedNegativeExit -eq 0 -or
      (Get-Content -LiteralPath $negativeLog -Raw) -notmatch 'division by zero') {
    throw 'Read-only negative SQL error propagation failed.'
  }
}
function Get-PreflightUtc($value) {
  if ($value -is [datetime]) {
    if ($value.Kind -eq [DateTimeKind]::Unspecified) { throw 'Ambiguous preflight UTC time.' }
    return [datetimeoffset]::new($value.ToUniversalTime(),[timespan]::Zero)
  }
  if ($value -is [string] -and $value -cmatch '^/Date\((-?\d+)\)/$') {
    return [datetimeoffset]::FromUnixTimeMilliseconds([long]::Parse($Matches[1]))
  }
  if ($value -is [string] -and $value -cmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$') {
    return [datetimeoffset]::Parse($value,[Globalization.CultureInfo]::InvariantCulture)
  }
  throw 'Preflight UTC time is missing or invalid.'
}

if (-not $OperatorApproved) { throw 'Operator approval is required for this phase.' }
if (-not [IO.Path]::IsPathRooted($EvidenceDir)) { throw 'Evidence directory must be absolute.' }
$evidenceFull = [IO.Path]::GetFullPath($EvidenceDir)
$repoBoundary = $repoRoot.TrimEnd([char]'\') + '\'
if ($evidenceFull.Equals($repoRoot,[StringComparison]::OrdinalIgnoreCase) -or
    $evidenceFull.StartsWith($repoBoundary,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Evidence directory must be outside the repository.'
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
Assert-ToolFiles
$manifest = @(Get-Manifest)
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$head = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $releaseCommit) {
  throw 'Release HEAD differs from approved commit.'
}
$trackedDiff = & git diff --name-only HEAD --
if ($LASTEXITCODE -ne 0 -or @($trackedDiff).Count -ne 0) {
  throw 'Tracked release files differ from approved commit.'
}
Assert-ProductionTarget
$phaseLog = Join-Path $EvidenceDir ("rel05g-{0}-{1}.log" -f $Phase.ToLowerInvariant(),
  (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $phaseLog
try {
  if ($Phase -eq 'Baseline') {
    if (Test-Path -LiteralPath $reportPath) { throw 'Existing report; do not overwrite evidence.' }
    Assert-Stage $production 10
    Assert-Invariants $production
    $baseline = Get-Snapshot $production $false
    Assert-Baseline $baseline
    Save-Json $baselinePath $baseline
    Save-Json $reportPath ([ordered]@{
      status='baseline_collected';project=$project;production=$production;endpoint=$endpoint;
      commit=$releaseCommit;manifest_sha256=$manifestHash;
      preliminary_baseline_sha256=(Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash;
      baseline_utc=[datetimeoffset]::UtcNow.ToString('o');completed=@();stage_logs=@()
    })
    Write-Output 'Preliminary read-only Production 0010 baseline and protected public audit aggregates captured.'
  } elseif ($Phase -eq 'Preflight') {
    $report = Get-Report
    if ($report.status -cnotin @('baseline_collected','preflight_passed','preflight_running') -or
        @($report.completed).Count -ne 0 -or $report.production -cne $production -or
        $report.commit -cne $releaseCommit -or $report.manifest_sha256 -cne $manifestHash) {
      throw 'Preflight requires an unused, unchanged preliminary Production baseline.'
    }
    $report.status = 'preflight_running'
    Save-Json $reportPath $report
    Assert-FileHash $baselinePath $report.preliminary_baseline_sha256
    Assert-Checkpoint $CheckpointBranchId
    $freezeHash = Assert-WriterFreeze
    $freezeEvidence = Get-Content -LiteralPath $WriterFreezeEvidencePath -Raw | ConvertFrom-Json
    $baselineUtc = Get-PreflightUtc $report.baseline_utc
    $freezeRecordedUtc = Get-PreflightUtc $freezeEvidence.recorded_at_utc
    if ($freezeRecordedUtc -le $baselineUtc) {
      throw 'Writer-freeze attestation must be recorded after the preliminary baseline.'
    }
    Assert-Stage $production 10
    Assert-Invariants $production
    $preliminary = Get-Baseline
    $frozen = Get-Snapshot $production $true
    Assert-Baseline $frozen
    Assert-Preserved $preliminary $frozen
    if ($preliminary.catalog_hash -cne $frozen.catalog_hash) {
      throw 'Production catalog changed between the preliminary baseline and verified freeze.'
    }
    Assert-Stage $CheckpointBranchId 10
    Assert-Invariants $CheckpointBranchId
    $checkpoint = Get-Snapshot $CheckpointBranchId
    Assert-Preserved $frozen $checkpoint
    if ($frozen.catalog_hash -cne $checkpoint.catalog_hash) {
      throw 'Checkpoint catalog differs from the post-freeze Production baseline.'
    }
    Save-Json $frozenBaselinePath $frozen
    Save-Json (Join-Path $EvidenceDir 'rel05g-checkpoint-snapshot.json') $checkpoint
    Assert-PsqlPreflight
    $report.status = 'preflight_passed'
    $report | Add-Member -NotePropertyName baseline_sha256 `
      -NotePropertyValue ((Get-FileHash -LiteralPath $frozenBaselinePath -Algorithm SHA256).Hash) -Force
    $report | Add-Member -NotePropertyName frozen_baseline_utc `
      -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $report | Add-Member -NotePropertyName checkpoint -NotePropertyValue $CheckpointBranchId -Force
    $report | Add-Member -NotePropertyName checkpoint_snapshot_sha256 `
      -NotePropertyValue ((Get-FileHash -LiteralPath (Join-Path $EvidenceDir 'rel05g-checkpoint-snapshot.json') -Algorithm SHA256).Hash) -Force
    $report | Add-Member -NotePropertyName freeze_sha256 -NotePropertyValue $freezeHash -Force
    $report | Add-Member -NotePropertyName preflight_utc -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force
    Save-Json $reportPath $report
    Write-Output 'Production/retained-checkpoint read-only preflight passed.'
  } elseif ($Phase -eq 'Run') {
    $report = Get-Report
    if ($report.status -cne 'preflight_passed' -or @($report.completed).Count -ne 0 -or
        $report.production -cne $production -or $report.checkpoint -cne $CheckpointBranchId -or
        $report.manifest_sha256 -cne $manifestHash) {
      throw 'Run requires one unused, passed Production preflight.'
    }
    $preflightUtc = Get-PreflightUtc $report.preflight_utc
    if ($preflightUtc -gt [datetimeoffset]::UtcNow -or
        $preflightUtc -lt [datetimeoffset]::UtcNow.AddHours(-2)) {
      throw 'Preflight is stale or future-dated.'
    }
    Assert-FileHash $baselinePath $report.preliminary_baseline_sha256
    Assert-FileHash $frozenBaselinePath $report.baseline_sha256
    $checkpointSnapshotPath = Join-Path $EvidenceDir 'rel05g-checkpoint-snapshot.json'
    Assert-FileHash $checkpointSnapshotPath $report.checkpoint_snapshot_sha256
    Assert-Checkpoint $CheckpointBranchId
    $null = Assert-WriterFreeze $report.freeze_sha256 $true
    $baseline = Get-FrozenBaseline
    $start = Get-Snapshot $production
    Assert-Baseline $start
    Assert-Preserved $baseline $start
    Assert-Invariants $production
    if ($baseline.catalog_hash -cne $start.catalog_hash) { throw 'Starting catalog changed.' }
    $report.status = 'running'
    Save-Json $reportPath $report
    try {
      foreach ($item in $manifest) {
        Assert-ProductionTarget
        Assert-Checkpoint $CheckpointBranchId
        $null = Assert-WriterFreeze $report.freeze_sha256
        $before = Get-Snapshot $production
        Assert-Markers $before ([int]$item.number - 1)
        Assert-Preserved $baseline $before
        Assert-Invariants $production
        Assert-Stage $production ([int]$item.number - 1)
        $migrationPath = Join-Path $repoRoot (Join-Path 'db/migrations' $item.file)
        Assert-FileHash $migrationPath $item.sha256
        $wrapper = New-ExecutionWrapper $migrationPath $item.sha256 $item.number
        $log = Join-Path $EvidenceDir ("rel05g-{0}-{1}.log" -f $item.number,
          (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $report | Add-Member -NotePropertyName current_migration -NotePropertyValue $item.number -Force
        $report | Add-Member -NotePropertyName current_log -NotePropertyValue $log -Force
        $report | Add-Member -NotePropertyName current_wrapper -NotePropertyValue $wrapper.path -Force
        $report | Add-Member -NotePropertyName current_wrapper_sha256 -NotePropertyValue $wrapper.sha256 -Force
        Save-Json $reportPath $report
        $result = Invoke-LoggedWrapper $production $wrapper $log $false
        if ($result.exit -ne 0) { throw "Migration $($item.number) failed; never rerun blindly." }
        $lines = @($result.sqlLines)
        Assert-MigrationOutput $lines $log $item.number
        Assert-FileHash $migrationPath $item.sha256
        Assert-Stage $production ([int]$item.number)
        $after = Get-Snapshot $production
        Assert-Markers $after ([int]$item.number)
        Assert-Preserved $baseline $after
        Assert-Invariants $production
        Save-Json (Join-Path $EvidenceDir ("rel05g-stage-$($item.number).json")) $after
        $report.completed = @($report.completed) + $item.number
        $report.stage_logs = @($report.stage_logs) + $log
        $report.current_migration = $null
        $report.current_log = $null
        $report.current_wrapper = $null
        $report.current_wrapper_sha256 = $null
        Save-Json $reportPath $report
        Write-Output "Committed and verified $($item.number) on pinned Production."
      }
      $report.status = 'migrated'
      $report | Add-Member -NotePropertyName migrated_utc -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force
      Save-Json $reportPath $report
    } catch {
      $report.status = 'failed'
      $report | Add-Member -NotePropertyName failure -NotePropertyValue $_.Exception.Message -Force
      $report | Add-Member -NotePropertyName failed_utc -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force
      Save-Json $reportPath $report
      throw
    }
  } else {
    $report = Get-Report
    if ($report.status -cne 'migrated' -or @($report.completed).Count -ne 17 -or
        $report.production -cne $production -or $report.checkpoint -cne $CheckpointBranchId -or
        $report.manifest_sha256 -cne $manifestHash) {
      throw 'Verify requires all 17 recorded committed migration stages.'
    }
    Assert-Checkpoint $CheckpointBranchId
    $null = Assert-WriterFreeze $report.freeze_sha256
    Assert-FileHash $baselinePath $report.preliminary_baseline_sha256
    Assert-FileHash $frozenBaselinePath $report.baseline_sha256
    $baseline = Get-FrozenBaseline
    Assert-Stage $production 27
    $final = Get-Snapshot $production
    Assert-Markers $final 27
    Assert-Preserved $baseline $final
    Assert-Invariants $production
    $lines = @(Invoke-ReadSql $production $finalPath)
    if ($lines.Count -ne 2 -or $lines[0] -cne '1') {
      throw 'Production final integrity and privilege gate failed.'
    }
    $ledger = $lines[1] | ConvertFrom-Json
    if ($ledger.database -cne 'neondb' -or $ledger.role -cne 'neondb_owner' -or
        $ledger.activity_audits -ne $baseline.data.activity_date_changes.count -or
        $ledger.r00 -ne $baseline.data.initial_schedule_revisions.count -or
        $ledger.calendar_versions -ne 0 -or $ledger.calendar_exceptions -ne 0 -or
        $ledger.calendar_events -ne 0 -or $ledger.reschedule_changes -ne 0 -or
        $ledger.reschedule_reversals -ne 0 -or $ledger.deletion_events -ne 0 -or
        $ledger.movement_events -ne 0) {
      throw 'Final audit or calendar ledger counts differ from pre-upgrade baseline.'
    }
    Save-Json (Join-Path $EvidenceDir 'rel05g-final-snapshot.json') $final
    Save-Json (Join-Path $EvidenceDir 'rel05g-final-ledgers.json') $ledger
    $report.status = 'verified'
    $report | Add-Member -NotePropertyName verified_utc -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $report | Add-Member -NotePropertyName final_catalog -NotePropertyValue $final.catalog_hash -Force
    Save-Json $reportPath $report
    Write-Output 'Production migration structure, original data, and ledgers verified.'
  }
} finally {
  Stop-Transcript
}
