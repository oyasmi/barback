[CmdletBinding()]
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Push-Location (Join-Path $PSScriptRoot '..')
$oldChild=$env:BARBACK_TEST_CHILD_PATH; $oldHost=$env:BARBACK_CONSOLE_HOST_PATH; $oldHarness=$env:BARBACK_CRASH_HARNESS_PATH
try {
    $root=(Get-Location).Path
    & dotnet restore Barback.sln --locked-mode -p:Platform=$Architecture -p:NuGetAudit=false -m:1
    if ($LASTEXITCODE) { throw 'Locked dependency restore failed.' }
    foreach ($project in @('src/Barback.ConsoleHost','fixtures/Barback.TestChild','fixtures/Barback.CrashHarness')) {
        $name=Split-Path $project -Leaf
        & dotnet publish $project -c Release -r "win-$Architecture" --self-contained true --no-restore -p:Platform=$Architecture -m:1 -o "artifacts/fixtures/$Architecture/$name"
        if ($LASTEXITCODE) { throw "Fixture publish failed: $name" }
    }
    $env:BARBACK_TEST_CHILD_PATH=Join-Path $root "artifacts/fixtures/$Architecture/Barback.TestChild/Barback.TestChild.exe"
    $env:BARBACK_CONSOLE_HOST_PATH=Join-Path $root "artifacts/fixtures/$Architecture/Barback.ConsoleHost/Barback.ConsoleHost.exe"
    $env:BARBACK_CRASH_HARNESS_PATH=Join-Path $root "artifacts/fixtures/$Architecture/Barback.CrashHarness/Barback.CrashHarness.exe"
    foreach ($project in @('Core','Storage','Windows')) {
        & dotnet test "tests/Barback.$project.Tests" -c Release -r "win-$Architecture" --no-restore -p:Platform=$Architecture -m:1 --logger "trx;LogFileName=$project.trx" --results-directory "TestResults/$Architecture"
        if ($LASTEXITCODE) { throw "Tests failed: $project" }
    }
} finally {
    $env:BARBACK_TEST_CHILD_PATH=$oldChild; $env:BARBACK_CONSOLE_HOST_PATH=$oldHost; $env:BARBACK_CRASH_HARNESS_PATH=$oldHarness
    Pop-Location
}
