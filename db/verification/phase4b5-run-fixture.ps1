[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(Mandatory)]
  [string]$Fixture,
  [Parameter(Mandatory, ParameterSetName = 'Run')]
  [string]$NeonCli,
  [Parameter(Mandatory, ParameterSetName = 'Run')]
  [string]$BranchId,
  [Parameter(Mandatory, ParameterSetName = 'Run')]
  [AllowEmptyCollection()]
  [string[]]$Bindings,
  [Parameter(Mandatory, ParameterSetName = 'ReadSeed')]
  [string[]]$SeedOutput
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phase4b5-handoff-manifest.json') -Raw | ConvertFrom-Json
$contract = $manifest.fixtures.PSObject.Properties | Where-Object Name -CEQ $Fixture
if (!$contract) { throw 'Unknown Phase 4B.5 fixture.' }
$contract = $contract.Value
$uuid = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

function Convert-Handoff([string[]]$Pairs, [string[]]$Expected) {
  $values = @{}
  foreach ($pair in $Pairs) {
    $parts = $pair.Split('=', 2)
    $key = $parts[0]
    if ($parts.Count -ne 2 -or $key -cnotmatch '\A[a-z][a-z0-9_]*\z') { throw 'Malformed fixture assignment.' }
    if ($key -cnotin $Expected) { throw "Unexpected fixture variable: $key" }
    if ($values.ContainsKey($key)) { throw "Duplicate fixture variable: $key" }
    $value = $parts[1]
    $pattern = $uuid
    foreach ($type in $manifest.types.PSObject.Properties) {
      if ($key -cin $type.Value) {
        $pattern = switch ($type.Name) {
          verified { 'true' }
          branch { 'br-[a-z0-9-]+' }
          uint { '0|[1-9][0-9]{0,18}' }
          fingerprint { '[0-9a-f]{32}' }
          name { [regex]::Escape('Synthetic Phase 4B.3c.4 incomplete remap target') }
          boolean { 'true|false' }
          workspaceOrNone { "$uuid|none" }
          default { throw 'Unknown fixture manifest type.' }
        }
      }
    }
    if ($value -cnotmatch ('\A(?:' + $pattern + ')\z')) { throw "Malformed fixture value for: $key" }
    if ($key -cin $manifest.types.uint) {
      $number = 0L
      if (![long]::TryParse($value, [ref]$number)) { throw "Fixture integer is out of range: $key" }
    }
    $values[$key] = $value
  }
  $missing = @($Expected | Where-Object { !$values.ContainsKey($_) })
  if ($missing.Count) { throw "Missing fixture variables: $($missing -join ', ')" }
  return $values
}

if ($PSCmdlet.ParameterSetName -eq 'ReadSeed') {
  if (!$contract.exports) { throw 'This fixture has no assignment output in the manifest.' }
  $pairs = @()
  $names = @()
  foreach ($line in $contract.exports) {
    $matchesFromSeed = @($SeedOutput | Where-Object { $_.StartsWith($line.prefix, [StringComparison]::Ordinal) })
    if ($matchesFromSeed.Count -ne 1) { throw "Expected one seed output line beginning with '$($line.prefix)'." }
    $text = $matchesFromSeed[0]
    if (!$line.prefixIsAssignment) { $text = $text.Substring($line.prefix.Length) }
    $names += $line.names
    $pairs += $text.Trim() -split '\s+'
  }
  Convert-Handoff $pairs $names
  return
}

$values = Convert-Handoff $Bindings $contract.inputs
if ($BranchId -cnotmatch '\Abr-[a-z0-9-]+\z') { throw 'Invalid Neon branch ID.' }
if ($BranchId -eq 'br-delicate-glitter-b6mj0051' -and !$contract.readOnly) {
  throw 'Writing fixture requires a disposable Development child.'
}
if ($values.ContainsKey('phase4b5_branch_id') -and $values.phase4b5_branch_id -cne $BranchId) {
  throw 'Fixture branch variable differs from the connection target.'
}
if ($values.ContainsKey('phase4b5_admin_user_id') -and
    [guid]$values.phase4b5_admin_user_id -eq [guid]$values.phase4b5_viewer_user_id) {
  throw 'Fixture admin and viewer identities must be distinct.'
}

$psqlDirectory = 'C:\Program Files\PostgreSQL\18\bin'
$psql = Join-Path $psqlDirectory 'psql.exe'
if (!(Test-Path -LiteralPath $psql -PathType Leaf) -or (& $psql --version) -cne 'psql (PostgreSQL) 18.7') {
  throw 'The reviewed native psql 18.7 executable is required.'
}
$cli = (Resolve-Path -LiteralPath $NeonCli).ProviderPath
if ([IO.Path]::GetFileName($cli) -cnotin @('neon.cmd', 'neon.exe')) { throw 'Supply the reviewed Neon CLI executable.' }
$argv = @('--no-analytics', 'psql', $BranchId, '--project-id', 'rapid-mud-63974868',
  '--role-name', $contract.role, '--database-name', 'neondb', '--ssl', 'verify-full',
  '--', '-X', '-w', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose')
foreach ($key in $contract.inputs) { $argv += @('-v', "$key=$($values[$key])") }
$argv += @('-f', "db/verification/$Fixture")

$oldPath = $env:PATH
$oldFallback = $env:NEONCTL_PSQL_FALLBACK
$oldOptions = $env:PGOPTIONS
$oldDebug = $env:DEBUG
Push-Location (Join-Path $PSScriptRoot '../..')
try {
  $env:PATH = "$psqlDirectory;$oldPath"
  $env:NEONCTL_PSQL_FALLBACK = '0'
  # Disable Neon credential diagnostics at the source and preserve psql evidence lines.
  $env:DEBUG = $null
  if ($contract.readOnly) { $env:PGOPTIONS = '-c default_transaction_read_only=on' }
  $ErrorActionPreference = 'Continue'
  $output = @(& $cli @argv 2>&1 | ForEach-Object { $_.ToString() })
  $status = $LASTEXITCODE
  $output | ForEach-Object { $_ -replace '(?i)(postgres(?:ql)?://)[^@\s]+@', '$1[redacted]@' } | Write-Output
  if ($status -eq 0 -and !($output -match 'launching psql')) { throw 'Native psql launch was not confirmed.' }
  exit $status
} finally {
  $env:PATH = $oldPath
  $env:NEONCTL_PSQL_FALLBACK = $oldFallback
  $env:PGOPTIONS = $oldOptions
  $env:DEBUG = $oldDebug
  Pop-Location
}
