[CmdletBinding()]
param([ValidateSet('x64','arm64')][string]$Architecture='x64',[ValidateSet('Debug','Release')][string]$Configuration='Release')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & dotnet restore Barback.sln --locked-mode -p:Platform=$Architecture
    if ($LASTEXITCODE) { throw 'Locked dependency restore failed.' }
    & dotnet build Barback.sln -c $Configuration --no-restore -p:Platform=$Architecture
    if ($LASTEXITCODE) { throw 'Build failed.' }
} finally { Pop-Location }
