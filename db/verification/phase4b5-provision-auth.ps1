[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$NeonCli,
  [Parameter(Mandatory)]
  [string]$BranchId
)

$ErrorActionPreference = 'Stop'
$project = 'rapid-mud-63974868'
$development = 'br-delicate-glitter-b6mj0051'
if ($BranchId -cnotmatch '\Abr-[a-z0-9-]+\z' -or $BranchId -ceq $development) {
  throw 'Synthetic Auth provisioning requires a disposable Development child.'
}
$cli = (Resolve-Path -LiteralPath $NeonCli).ProviderPath
if ([IO.Path]::GetFileName($cli) -cnotin @('neon.cmd', 'neon.exe')) {
  throw 'Supply the reviewed Neon CLI executable.'
}

function Read-CreatedIdentity([string[]]$Response, [int]$ExitCode, [string]$Role, [string]$Email) {
  $statusPattern = '\AHTTP(?:/[0-9](?:\.[0-9])?)? (?<code>[1-5][0-9]{2})(?: [\x20-\x7E\t]*)?\z'
  if (!$Response.Count -or $Response[0] -cnotmatch $statusPattern) {
    throw "Missing or malformed HTTP status for the synthetic $Role (CLI exit $ExitCode)."
  }
  $status = $Matches.code
  $separator = 1
  while ($separator -lt $Response.Count -and $Response[$separator] -cne '') {
    if ($Response[$separator] -cnotmatch '\A[!#$%&''*+.^_`|~0-9A-Za-z-]+:[\x20-\x7E\t]*\z' -or
        $Response[$separator] -match '\AStatus:') {
      throw "Malformed or ambiguous HTTP headers for the synthetic $Role."
    }
    $separator++
  }
  if ($separator -eq $Response.Count) {
    throw "Missing HTTP header terminator for the synthetic $Role."
  }
  if ($status -cne '201' -or $ExitCode -ne 0) {
    throw "Synthetic ${Role} creation failed (HTTP $status, CLI exit $ExitCode)."
  }
  $body = ($Response | Select-Object -Skip ($separator + 1)) -join "`n"
  if (!$body.TrimStart().StartsWith('{') -or !$body.TrimEnd().EndsWith('}')) {
    throw "Expected one JSON object for the synthetic $Role."
  }
  try {
    $identity = ConvertFrom-Json -InputObject $body -ErrorAction Stop
  } catch {
    throw "Invalid JSON for the synthetic $Role."
  }
  if ($identity.PSObject.Properties['user']) {
    if ($identity.PSObject.Properties['id'] -or $identity.PSObject.Properties['email']) {
      throw "Ambiguous JSON identity for the synthetic $Role."
    }
    $identity = $identity.user
  }
  $id = [guid]::Empty
  if ($identity.id -isnot [string] -or ![guid]::TryParseExact($identity.id, 'D', [ref]$id) -or
      $id -eq [guid]::Empty) {
    throw "Invalid provider ID for the synthetic $Role."
  }
  # The documented create response only guarantees an ID. SQL verifies the exact email on the child.
  if ($identity.PSObject.Properties['email'] -and ($identity.email -isnot [string] -or $identity.email -cne $Email)) {
    throw "Unexpected response email for the synthetic $Role."
  }
  return $id.ToString('D')
}

$oldDebug = $env:DEBUG
try {
  $env:DEBUG = $null
  # Keep raw API responses and diagnostics out of the console.
  $ErrorActionPreference = 'Continue'
  $branchOutput = @(& $cli --no-analytics --output json branches get $BranchId --project-id $project 2>$null)
  $branchExit = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($branchExit -ne 0) { throw "Disposable child lookup failed (CLI exit $branchExit)." }
  try {
    $branch = ($branchOutput -join "`n") | ConvertFrom-Json -ErrorAction Stop
    if ($branch.branch) { $branch = $branch.branch }
    $expiresAt = ([DateTimeOffset]$branch.expires_at).UtcDateTime
  } catch {
    throw 'Invalid disposable child metadata.'
  }
  if ($branch.id -cne $BranchId -or $branch.project_id -cne $project -or $branch.parent_id -cne $development -or
      $branch.name -cnotmatch '\Aphase4b5-rehearsal-[a-z0-9-]+\z' -or
      $branch.default -isnot [bool] -or $branch.default -or $branch.primary -isnot [bool] -or $branch.primary -or
      $branch.current_state -cne 'ready' -or $expiresAt -le [DateTime]::UtcNow) {
    throw 'Neon branch metadata did not match a ready, expiring Development rehearsal child.'
  }

  $ids = @{}
  foreach ($role in @('admin', 'viewer')) {
    $email = "jlproject-phase4b5-$role-$BranchId@example.invalid"
    $ErrorActionPreference = 'Continue'
    $response = @(& $cli --no-analytics --output json api "/projects/$project/branches/$BranchId/auth/users" -X POST -f "email=$email" -i 2>$null)
    $status = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $ids[$role] = Read-CreatedIdentity $response $status $role $email
  }
  if ($ids.admin -ceq $ids.viewer) { throw 'Synthetic Auth identities must be distinct.' }

  $bindings = @("phase4b5_branch_id=$BranchId", "phase4b5_admin_user_id=$($ids.admin)", "phase4b5_viewer_user_id=$($ids.viewer)")
  & (Join-Path $PSScriptRoot 'phase4b5-run-fixture.ps1') -Fixture phase4b5-seed-auth-identities-owner.sql `
    -BranchId $BranchId -NeonCli $cli -Bindings $bindings | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Read-only synthetic Auth identity preflight failed (exit $LASTEXITCODE)." }

  [pscustomobject]@{ AdminUserId = $ids.admin; ViewerUserId = $ids.viewer }
} finally {
  $env:DEBUG = $oldDebug
}
