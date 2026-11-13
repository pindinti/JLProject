$ErrorActionPreference = 'Stop'

$runnerPath = Join-Path $PSScriptRoot 'rel05g-production-operator.ps1'
$tokens = $null
$parseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $runnerPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'REL-05G runner has PowerShell parse errors.' }

$requiredFunctions = @('Assert-FileHash','Assert-NativePsql','Invoke-LoggedWrapper',
  'Assert-SettingsRows','Assert-MigrationOutput')
$functionAsts = $runnerAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $requiredFunctions -contains $node.Name
},$true)
foreach ($name in $requiredFunctions) {
  $functionAst = $functionAsts | Where-Object { $_.Name -ceq $name } |
    Select-Object -First 1
  if ($null -eq $functionAst) { throw "Runner function missing: $name" }
  Invoke-Expression $functionAst.Extent.Text
}

$production = 'br-orange-shadow-b6yu9uxu'
$project = 'crimson-glade-72578238'
$nativePsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$nativeCaBundle = 'C:\Program Files\Git\usr\ssl\cert.pem'
$tempRoot = Join-Path $env:TEMP ('rel05k-diagnostics-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$hadDebug = Test-Path Env:DEBUG
$oldDebug = $env:DEBUG
$oldMode = $env:REL05K_MODE
$hadMode = Test-Path Env:REL05K_MODE
$hadFallback = Test-Path Env:NEONCTL_PSQL_FALLBACK
$oldFallback = $env:NEONCTL_PSQL_FALLBACK
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
  $fakeNpx = @'
@echo off
if /I "%REL05K_MODE%"=="sql-failure" goto sqlfailure
if /I "%REL05K_MODE%"=="nonzero" goto nonzero
if /I "%REL05K_MODE%"=="unknown-stderr" goto unknownstderr
if /I "%REL05K_MODE%"=="embedded" goto embedded
if defined DEBUG echo DEBUG: synthetic CLI debug line 1>&2
if defined NEONCTL_PSQL_FALLBACK echo ERROR: forced fallback 1>&2
if not defined PGSSLROOTCERT echo ERROR: missing CA bundle 1>&2
echo Connecting to the database; launching psql... 1>&2
if /I "%REL05K_MODE%"=="run" echo SET
if /I "%REL05K_MODE%"=="run" echo SET
if /I "%REL05K_MODE%"=="run" echo SET
echo REL05G_SETTINGS^|{"role":"neondb_owner","database":"neondb","idle_timeout_ms":720000,"lock_timeout_ms":15000,"statement_timeout_ms":600000}
echo 1
if /I "%REL05K_MODE%"=="run" echo BEGIN
echo 1
if /I "%REL05K_MODE%"=="run" echo COMMIT
exit /b 0
:sqlfailure
echo ERROR: division by zero 1>&2
exit /b 1
:nonzero
echo REL05G_SETTINGS^|synthetic
echo 1
echo 1
exit /b 17
:unknownstderr
echo unrecognized diagnostic 1>&2
echo REL05G_SETTINGS^|synthetic
echo 1
echo 1
exit /b 0
:embedded
echo psql binary not found on PATH; falling back to embedded TypeScript psql 1>&2
echo Connecting to the database; launching embedded psql (TypeScript)... 1>&2
echo 1
exit /b 0
'@
  $fakeNpxPath = Join-Path $tempRoot 'npx.cmd'
  $wrapperPath = Join-Path $tempRoot 'wrapper.sql'
  Set-Content -LiteralPath $fakeNpxPath -Value $fakeNpx -Encoding Ascii
  Set-Content -LiteralPath $wrapperPath -Value 'SELECT 1;' -Encoding Ascii
  $wrapper = [pscustomobject]@{
    path = $wrapperPath
    sha256 = (Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash
  }
  $env:PATH = $tempRoot + ';' + $oldPath
  $env:DEBUG = 'REL05K_TEST_DEBUG'
  $env:NEONCTL_PSQL_FALLBACK = '1'

  $env:REL05K_MODE = 'success'
  $successLog = Join-Path $tempRoot 'success.log'
  $success = Invoke-LoggedWrapper $production $wrapper $successLog $true '0010'
  if ($success.exit -ne 0 -or $success.sqlLines.Count -ne 3 -or
      -not $success.sqlLines[0].StartsWith('REL05G_SETTINGS|') -or
      $success.sqlLines[1] -cne '1' -or $success.sqlLines[2] -cne '1' -or
      (Get-Content -LiteralPath "$successLog.exit" -Raw).Trim() -cne '0' -or
      (Get-Content -LiteralPath "$successLog.stderr" -Raw) -match 'DEBUG:' -or
      $env:DEBUG -cne 'REL05K_TEST_DEBUG' -or
      $env:NEONCTL_PSQL_FALLBACK -cne '1') {
    throw 'Success/harmless-startup-diagnostic test failed.'
  }

  $env:REL05K_MODE = 'run'
  $runLog = Join-Path $tempRoot 'run.log'
  $run = Invoke-LoggedWrapper $production $wrapper $runLog $false
  if ($run.exit -ne 0 -or $run.sqlLines.Count -ne 8 -or
      $run.sqlLines[-1] -cne 'COMMIT') { throw 'Native Run output shape differs.' }
  Assert-MigrationOutput $run.sqlLines $runLog '0011'
  $invalid = @(
    [pscustomobject]@{lines=@($run.sqlLines | Where-Object { $_ -cne 'COMMIT' })},
    [pscustomobject]@{lines=@($run.sqlLines) + @('COMMIT')},
    [pscustomobject]@{lines=@('SET','SET','SET','REL05G_SETTINGS|{}','1','BEGIN','1','COMMIT')}
  )
  foreach ($bad in $invalid) {
    $rejected = $false
    try { Assert-MigrationOutput $bad.lines $runLog '0011' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid COMMIT/session output was accepted.' }
  }

  $env:REL05K_MODE = 'embedded'
  $embeddedRejected = $false
  try { $null = Invoke-LoggedWrapper $production $wrapper (Join-Path $tempRoot 'embedded.log') $false }
  catch { $embeddedRejected = $true }
  if (-not $embeddedRejected) { throw 'Embedded fallback was accepted.' }

  $env:REL05K_MODE = 'sql-failure'
  $sqlFailureLog = Join-Path $tempRoot 'sql-failure.log'
  $sqlFailureThrown = $false
  try { $null = Invoke-LoggedWrapper $production $wrapper $sqlFailureLog $true '0010' }
  catch { $sqlFailureThrown = $_.Exception.Message -match 'exited with code 1' }
  if (-not $sqlFailureThrown -or
      (Get-Content -LiteralPath "$sqlFailureLog.exit" -Raw).Trim() -cne '1' -or
      (Get-Content -LiteralPath "$sqlFailureLog.stderr" -Raw) -notmatch 'division by zero') {
    throw 'SQL-error/nonzero-exit test failed.'
  }

  $env:REL05K_MODE = 'nonzero'
  $nonzeroLog = Join-Path $tempRoot 'nonzero.log'
  $nonzeroThrown = $false
  try { $null = Invoke-LoggedWrapper $production $wrapper $nonzeroLog $true '0010' }
  catch { $nonzeroThrown = $_.Exception.Message -match 'exited with code 17' }
  if (-not $nonzeroThrown -or
      (Get-Content -LiteralPath "$nonzeroLog.exit" -Raw).Trim() -cne '17') {
    throw 'Nonzero process-exit test failed.'
  }

  $env:REL05K_MODE = 'unknown-stderr'
  $unknownLog = Join-Path $tempRoot 'unknown-stderr.log'
  $unknownThrown = $false
  try { $null = Invoke-LoggedWrapper $production $wrapper $unknownLog $true '0010' }
  catch { $unknownThrown = $_.Exception.Message -match 'Unexpected psql stderr' }
  if (-not $unknownThrown -or
      (Get-Content -LiteralPath "$unknownLog.exit" -Raw).Trim() -cne '0') {
    throw 'Unexpected-stderr rejection test failed.'
  }

  Write-Output 'PASS: native startup, DEBUG/fallback isolation, exact COMMIT gate, SQL failure, nonzero exit, and unexpected stderr.'
} finally {
  $env:PATH = $oldPath
  if ($hadDebug) { $env:DEBUG = $oldDebug }
  else { Remove-Item Env:DEBUG -ErrorAction SilentlyContinue }
  if ($hadMode) { $env:REL05K_MODE = $oldMode }
  else { Remove-Item Env:REL05K_MODE -ErrorAction SilentlyContinue }
  if ($hadFallback) { $env:NEONCTL_PSQL_FALLBACK = $oldFallback }
  else { Remove-Item Env:NEONCTL_PSQL_FALLBACK -ErrorAction SilentlyContinue }
  $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([char]'\') + '\'
  $tempFull = [IO.Path]::GetFullPath($tempRoot)
  if (-not $tempFull.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $tempFull) -notmatch '^rel05k-diagnostics-[0-9a-f]{32}$') {
    throw 'Refusing to remove an unverified diagnostic test directory.'
  }
  Remove-Item -LiteralPath $tempFull -Recurse -Force
}
