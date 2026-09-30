[CmdletBinding()]
param([ValidateSet('Debug','Release')][string]$Configuration='Release')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & dotnet build fixtures/Barback.UiHarness -c $Configuration -p:Platform=x64 -p:RestoreLockedMode=true
    if ($LASTEXITCODE) { throw 'WPF harness build failed.' }
    $output=Join-Path (Get-Location) ('artifacts/ui-check/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $binary="fixtures/Barback.UiHarness/bin/x64/$Configuration/net10.0-windows10.0.19041.0/win-x64/Barback.UiHarness.exe"
    $process=Start-Process -FilePath $binary -ArgumentList ('"' + $output + '"') -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(45000)) { $process.Kill(); throw 'Isolated WPF UI check timed out.' }
    $errorFile=Join-Path $output 'error.txt'
    if (Test-Path -LiteralPath $errorFile) { throw (Get-Content -LiteralPath $errorFile -Raw) }
    if ($process.ExitCode) { throw "WPF check failed: $($process.ExitCode)" }
    Get-Content -LiteralPath (Join-Path $output 'checks.txt')
    Write-Output "Native screenshots and isolated fixture data: $output"
} finally { Pop-Location }
