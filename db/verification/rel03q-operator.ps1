param(
  [Parameter(Mandatory)][ValidateSet('Create', 'Run', 'Cleanup')][string]$Phase,
  [string]$ChildBranchId,
  [string]$EvidencePath,
  [string]$VerificationLog,
  [switch]$CleanupApproved
)

$ErrorActionPreference = 'Stop'
$projectId = 'crimson-glade-72578238'
$sourceId = 'br-snowy-wave-b6vn905p'
$productionId = 'br-orange-shadow-b6yu9uxu'
$childName = 'rel03-audit-proof-0026'
$sqlFiles = @{
  baseline = @{ path = 'rel03q-child-baseline.sql'; hash = 'A7D78BF4A9BD94BF2595D6EDB889B699A7D00E9EF9148F6FDB1A24F039AC8501' }
  worker = @{ path = 'rel03q-child-worker-movements.sql'; hash = '714F1A2434CECBDC09F767223669F63F54179C2769D24CE40497FCA88053E6CE' }
  owner = @{ path = 'rel03q-child-owner-audit.sql'; hash = 'E90A47B061A3F9ECFDEF5469CF7A041CE1CBC470819B4EA63D398ADFFD6372C2' }
  immutability = @{ path = 'rel03q-child-immutability-optional.sql'; hash = '47BFC31F658A0E19D7D200AB49D13DFBFF72179DF27656D58BD8BEEA229381C1' }
}

function Get-VerifiedBranch([string]$id) {
  $raw = & npx.cmd neon@latest branches get $id --project-id $projectId --output json --no-analytics
  if ($LASTEXITCODE -ne 0) { throw "Branch lookup failed for $id." }
  $branch = ($raw | Out-String | ConvertFrom-Json)
  if ($null -ne $branch.branch) { $branch = $branch.branch }
  if ($branch.id -ne $id -or $branch.project_id -ne $projectId) {
    throw 'Branch or project identity differs.'
  }
  return $branch
}

function Assert-Child([string]$id, [bool]$requireReady = $true) {
  if ([string]::IsNullOrWhiteSpace($id) -or $id -eq $sourceId -or $id -eq $productionId -or
      $id -eq 'br-empty-brook-b6aynihp') { throw 'Unsafe or missing child branch ID.' }
  $branch = Get-VerifiedBranch $id
  if ($branch.name -ne $childName -or $branch.parent_id -ne $sourceId -or
      $branch.default -ne $false -or
      ($requireReady -and $branch.current_state -ne 'ready')) {
    throw 'Child name, parent, default status, or state differs.'
  }
  return $branch
}

function Assert-SqlHashes {
  foreach ($item in $sqlFiles.Values) {
    $path = Join-Path $PSScriptRoot $item.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item.hash) {
      throw "SQL checksum mismatch: $($item.path)"
    }
  }
}

$log = Join-Path $env:TEMP ("rel03q-{0}-{1}.log" -f $Phase.ToLowerInvariant(),
  (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $log
try {
  if ($Phase -eq 'Create') {
    $source = Get-VerifiedBranch $sourceId
    if ($source.name -ne 'release-rehearsal-0010-0027' -or
        $source.parent_id -ne $productionId -or $source.default -ne $false -or
        $source.current_state -ne 'ready') {
      throw 'Rehearsal source identity, parent, or state differs.'
    }
    $listedRaw = & npx.cmd neon@latest branches list --project-id $projectId --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list branches before creation.' }
    $listed = ($listedRaw | Out-String | ConvertFrom-Json)
    if (@($listed | Where-Object { $_.name -eq $childName }).Count -ne 0) {
      throw 'Temporary child name already exists; stop.'
    }
    $createdRaw = & npx.cmd neon@latest branches create --project-id $projectId `
      --parent $sourceId --name $childName --no-secrets --output json --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Child creation failed.' }
    $created = ($createdRaw | Out-String | ConvertFrom-Json).branch
    if ($null -eq $created -or $created.project_id -ne $projectId -or
        $created.parent_id -ne $sourceId -or $created.name -ne $childName -or
        $created.default -ne $false -or [string]::IsNullOrWhiteSpace($created.id)) {
      throw 'Created child identity differs; retain branch for investigation.'
    }
    $null = Assert-Child $created.id $false
    Write-Output "Verified child ID $($created.id), project $projectId, parent $sourceId, non-default."
  }
  elseif ($Phase -eq 'Run') {
    $null = Assert-Child $ChildBranchId
    Assert-SqlHashes
    $baselinePath = Join-Path $PSScriptRoot $sqlFiles.baseline.path
    $workerPath = Join-Path $PSScriptRoot $sqlFiles.worker.path
    $ownerPath = Join-Path $PSScriptRoot $sqlFiles.owner.path
    $immutabilityPath = Join-Path $PSScriptRoot $sqlFiles.immutability.path
    $baselineRaw = & npx.cmd neon@latest psql $ChildBranchId --project-id $projectId `
      --role-name neondb_owner --database-name neondb --ssl verify-full -- `
      -X -qAt -v ON_ERROR_STOP=1 -f $baselinePath
    if ($LASTEXITCODE -ne 0) { throw 'Read-only child baseline failed.' }
    $baseline = ($baselineRaw | Out-String).Trim() | ConvertFrom-Json
    if ($baseline.database -ne 'neondb' -or $baseline.role -ne 'neondb_owner' -or
        $baseline.products -ne 5 -or $baseline.disciplines -ne 19 -or
        $baseline.stages -ne 40 -or $baseline.activities -ne 73 -or
        $baseline.date_audits -ne 3 -or $baseline.r00 -ne 1 -or
        $baseline.movement_events -ne 0 -or
        $baseline.movement_fingerprint -ne 'd41d8cd98f00b204e9800998ecf8427e' -or
        $baseline.date_fingerprint -ne '41276cac3ad96dcf6377af00f5b7e733' -or
        $baseline.fixture_rows -ne 0 -or
        $baseline.unreviewed_write_triggers -ne 0 -or
        $baseline.owner_can_select_ledger -ne $true -or
        $baseline.movement_function_installed -ne $true) {
      throw 'Child baseline differs; no synthetic writes were attempted.'
    }
    $baseline | Add-Member -NotePropertyName child_branch_id -NotePropertyValue $ChildBranchId
    $evidence = Join-Path $env:TEMP ("rel03q-baseline-{0}.json" -f $ChildBranchId)
    [System.IO.File]::WriteAllText($evidence,
      ($baseline | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    Write-Output "Sanitized child baseline saved: $evidence"
    & npx.cmd neon@latest psql $ChildBranchId --project-id $projectId `
      --role-name jlproject_worker --database-name neondb --ssl verify-full -- `
      -X -v ON_ERROR_STOP=1 -f $workerPath
    if ($LASTEXITCODE -ne 0) { throw 'Worker fixture failed; inspect child before any retry.' }
    $null = Assert-Child $ChildBranchId
    & npx.cmd neon@latest psql $ChildBranchId --project-id $projectId `
      --role-name neondb_owner --database-name neondb --ssl verify-full -- `
      -X -v ON_ERROR_STOP=1 `
      -v "expected_dates=$($baseline.date_fingerprint)" `
      -v "expected_hierarchy=$($baseline.hierarchy_fingerprint)" `
      -v "expected_r00=$($baseline.r00_fingerprint)" `
      -v "expected_targets=$($baseline.target_fingerprint)" `
      -v "expected_source_rows=$($baseline.source_rows)" -f $ownerPath
    if ($LASTEXITCODE -ne 0) {
      throw 'Owner audit verification failed; retain child and evidence for investigation.'
    }
    if ($baseline.owner_can_update_ledger -eq $true) {
      & npx.cmd neon@latest psql $ChildBranchId --project-id $projectId `
        --role-name neondb_owner --database-name neondb --ssl verify-full -- `
        -X -v ON_ERROR_STOP=1 -f $immutabilityPath
      if ($LASTEXITCODE -ne 0) {
        throw 'Ledger immutability test failed; retain child for investigation.'
      }
    }
    else {
      Write-Output 'Owner has no documented UPDATE path; trigger execution remains untested.'
    }
    Write-Output "REL-03Q owner audit passed on child $ChildBranchId. Preserve this log: $log"
  }
  else {
    if (-not $CleanupApproved -or [string]::IsNullOrWhiteSpace($EvidencePath) -or
        -not (Test-Path -LiteralPath $EvidencePath -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace($VerificationLog) -or
        -not (Test-Path -LiteralPath $VerificationLog -PathType Leaf)) {
      throw 'Cleanup requires separate approval, saved baseline, and verification log.'
    }
    $null = Assert-Child $ChildBranchId
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    if ($evidence.child_branch_id -ne $ChildBranchId -or
        $evidence.movement_events -ne 0 -or
        $evidence.movement_fingerprint -ne 'd41d8cd98f00b204e9800998ecf8427e') {
      throw 'Saved baseline evidence differs.'
    }
    if (-not (Select-String -LiteralPath $VerificationLog -SimpleMatch "REL-03Q owner audit passed on child $ChildBranchId" -Quiet)) {
      throw 'Saved log lacks successful owner audit evidence.'
    }
    $typed = Read-Host "Type DELETE $childName to delete only child $ChildBranchId"
    if ($typed -cne "DELETE $childName") { throw 'Cleanup confirmation differs.' }
    $null = Assert-Child $ChildBranchId
    & npx.cmd neon@latest branches delete $ChildBranchId --project-id $projectId --no-analytics
    if ($LASTEXITCODE -ne 0) { throw 'Child deletion failed; inspect state.' }
    Write-Output "Deleted only verified child $ChildBranchId."
  }
}
finally {
  Stop-Transcript
}
